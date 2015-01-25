/**
    Utility functions for memory management

    Note that this module currently is a big sand box for testing allocation related stuff.
    Nothing here, including the interfaces, is final but rather a lot of experimentation.

    Copyright: © 2012-2013 RejectedSoftware e.K.
    		   © 2014-2015 Etienne Cimon
    License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
    Authors: Sönke Ludwig, Etienne Cimon
*/
module memutils.allocators.allocators;

import core.exception : OutOfMemoryError;
import core.stdc.stdlib;
import core.memory;
import std.conv;
import std.exception : enforceEx;
import std.traits;
import std.algorithm;
import botan.utils.containers.hashmap : HashMapImpl;
import std.traits : ReturnType;

enum { // overhead allocator definitions, lazily loaded
	NativeGC = 0x00, // instances are freed automatically when no references exist in the program's threads
	LocklessFreeList = 0x01, // instances are owned by the creating thread thus must be freed by it
	CryptoSafeAllocator = 0x02, // Same as above, but zeroise is called upon freeing
	ScopedFiberPool = 0x03 // One per fiber, calls object destructors when reset. Uses GC if no fiber is set
}

alias LocklessAllocator = AutoFreeListAllocator!(MallocAllocator);
alias CryptoSafe = ZeroiseAllocator!LocklessAllocator;

R getAllocator(R)() {
	static __gshared R alloc;
	if (!alloc)
		alloc = new R;
	return alloc;
}

string translateAllocator() { /// requires (int ALLOC) template parameter
	return `
	static assert(ALLOC, "The 'int ALLOC' template parameter is not in scope.");
	ReturnType!(getAllocator!ALLOC()) getAllocator() {
		return getAllocator!ALLOC();
	}`;
}

auto allocObject(T, int ALLOC = LocklessAllocator, bool MANAGED = true, ARGS...)(ARGS args)
{
	mixin(translateAllocator());
	auto allocator = getAllocator();
	auto mem = allocator.alloc(AllocSize!T);
	static if( MANAGED ){
		static if( hasIndirections!T )
			GC.addRange(mem.ptr, mem.length);
		return emplace!T(mem, args);
	}
	else static if( is(T == class) ) return cast(T)mem.ptr;
	else return cast(T*)mem.ptr;
}

T[] allocArray(T, int ALLOC = LocklessAllocator, bool MANAGED = true)(size_t n)
{
	mixin(translateAllocator());
	auto allocator = getAllocator();
	auto mem = allocator.alloc(T.sizeof * n);
	auto ret = cast(T[])mem;
	static if ( MANAGED )
	{
		static if (__traits(hasMember, T, "NOGC")) enum NOGC = T.NOGC;
		else enum NOGC = false;
		
		static if( hasIndirections!T && !NOGC )
			GC.addRange(mem.ptr, mem.length);
		// TODO: use memset for class, pointers and scalars
		foreach (ref el; ret) { // calls constructors
			emplace!T(cast(void[])((&el)[0 .. 1]));
		}
	}
	return ret;
}

void freeArray(T, int ALLOC = LocklessAllocator, bool MANAGED = true, bool DESTROY = true)(ref T[] array, size_t max_destroy = size_t.max)
{
	mixin(translateAllocator());
	auto allocator = getAllocator();

	static if (__traits(hasMember, T, "NOGC")) enum NOGC = T.NOGC;
	else enum NOGC = false;
	
	static if (MANAGED && hasIndirections!T && !NOGC) {
		GC.removeRange(array.ptr);
	}
	static if (DESTROY && hasElaborateDestructor!T) { // calls destructors
		size_t i;
		foreach (ref e; array) {
			static if (is(T == struct) && isPointer!T) .destroy(*e);
			else .destroy(e);
			if (++i == max_destroy) break;
		}
	}
	allocator.free(cast(void[])array);
	array = null;
}

interface Allocator {
	enum size_t alignment = 0x10;
	enum size_t alignmentMask = alignment-1;
	
	void[] alloc(size_t sz)
	out { assert((cast(size_t)__result.ptr & alignmentMask) == 0, "alloc() returned misaligned data."); }
	
	void free(void[] mem)
	in {
		assert(mem.ptr !is null, "free() called with null array.");
		assert((cast(size_t)mem.ptr & alignmentMask) == 0, "misaligned pointer passed to free().");
	}
}

final class GCAllocator : Allocator {
	void[] alloc(size_t sz)
	{
		auto mem = GC.malloc(sz+Allocator.alignment);
		auto alignedmem = adjustPointerAlignment(mem);
		assert(alignedmem - mem <= Allocator.alignment);
		auto ret = alignedmem[0 .. sz];
		ensureValidMemory(ret);
		return ret;
	}

	void[] realloc(void[] mem, size_t new_size)
	{
		size_t csz = min(mem.length, new_size);
		
		auto p = extractUnalignedPointer(mem.ptr);
		size_t misalign = mem.ptr - p;
		assert(misalign <= Allocator.alignment);
		
		void[] ret;
		auto extended = GC.extend(p, new_size - mem.length, new_size - mem.length);
		if (extended) {
			assert(extended >= new_size+Allocator.alignment);
			ret = p[misalign .. new_size+misalign];
		} else {
			ret = alloc(new_size);
			ret[0 .. csz] = mem[0 .. csz];
		}
		ensureValidMemory(ret);
		return ret;
	}

	void free(void[] mem)
	{
		GC.free(extractUnalignedPointer(mem.ptr));
	}
}


/**
    Simple proxy allocator protecting its base allocator with a mutex.
*/
final class LockAllocator(Base) : Allocator {
	private {
		Base m_base;
	}
	this() { m_base = getAllocator!Base(); }
	void[] alloc(size_t sz) { synchronized(this) return m_base.alloc(sz); }
	void free(void[] mem)
	in {
		assert(mem.ptr !is null, "free() called with null array.");
		assert((cast(size_t)mem.ptr & alignmentMask) == 0, "misaligned pointer passed to free().");
	}
	body { synchronized(this) m_base.free(mem); }
}

final class DebugAllocator(Base) : Allocator {
	private {
		Base m_baseAlloc;
		HashMapImpl!(void*, size_t, Mallocator) m_blocks;
		size_t m_bytes;
		size_t m_maxBytes;
	}

	this()
	{
		m_baseAlloc = getAllocator!Base();
		m_blocks = HashMapImpl!(void*, size_t, Mallocator)();
	}
	
	@property size_t allocatedBlockCount() const { return m_blocks.length; }
	@property size_t bytesAllocated() const { return m_bytes; }
	@property size_t maxBytesAllocated() const { return m_maxBytes; }
	
	void[] alloc(size_t sz)
	{
		auto ret = m_baseAlloc.alloc(sz);
		assert(ret.length == sz, "base.alloc() returned block with wrong size.");
		assert(m_blocks.get(cast(const)ret.ptr, size_t.max) == size_t.max, "base.alloc() returned block that is already allocated.");
		m_blocks[ret.ptr] = sz;
		m_bytes += sz;
		if( m_bytes > m_maxBytes ){
			m_maxBytes = m_bytes;
			//logDebug("New allocation maximum: %d (%d blocks)", m_maxBytes, m_blocks.length);
		}
		return ret;
	}
	
	void free(void[] mem)
	{
		auto sz = m_blocks.get(cast(const)mem.ptr, size_t.max);
		assert(sz != size_t.max, "free() called with non-allocated object.");
		assert(sz == mem.length, "free() called with block of wrong size.");
		m_baseAlloc.free(mem);
		m_bytes -= sz;
		m_blocks.remove(mem.ptr);
	}
}

final class MallocAllocator : Allocator {
	void[] alloc(size_t sz)
	{
		static err = new immutable OutOfMemoryError;
		auto ptr = .malloc(sz + Allocator.alignment);
		if (ptr is null) throw err;
		return adjustPointerAlignment(ptr)[0 .. sz];
	}
	
	void free(void[] mem)
	{
		.free(extractUnalignedPointer(mem.ptr));
	}
}



template FreeListObjectAlloc(T, bool USE_GC = true, bool INIT = true)
{
	enum ElemSize = AllocSize!T;
	
	static if (__traits(hasMember, T, "NOGC")) enum NOGC = T.NOGC;
	else enum NOGC = false;
	
	alias TR = RefTypeOf!T;
	
	TR alloc(ARGS...)(ARGS args)
	{
		//logInfo("alloc %s/%d", T.stringof, ElemSize);
		auto mem = getAllocator!LocklessAllocatorImpl().alloc(ElemSize);
		static if( hasIndirections!T && !NOGC ) GC.addRange(mem.ptr, ElemSize);
		static if( INIT ) return emplace!T(mem, args);
		else return cast(TR)mem.ptr;
	}
	
	void free(TR obj)
	{
		static if( INIT ){
			auto objc = obj;
			static if (is(TR == T*)) .destroy(*objc);
			else .destroy(objc);
		}
		static if( hasIndirections!T && !NOGC ) GC.removeRange(cast(void*)obj);
		getAllocator!LocklessAllocatorImpl().free((cast(void*)obj)[0 .. ElemSize]);
	}
}

unittest {
	logTrace("Testing memory/memory.d ...");
	void testAlign(void* p, size_t adjustment) {
		void* pa = adjustPointerAlignment(p);
		assert((cast(size_t)pa & Allocator.alignmentMask) == 0, "Non-aligned pointer.");
		assert(*(cast(const(ubyte)*)pa-1) == adjustment, "Invalid adjustment "~to!string(p)~": "~to!string(*(cast(const(ubyte)*)pa-1)));
		void* pr = extractUnalignedPointer(pa);
		assert(pr == p, "Recovered base != original");
	}
	void* ptr = .malloc(0x40);
	ptr += Allocator.alignment - (cast(size_t)ptr & Allocator.alignmentMask);
	testAlign(ptr++, 0x10);
	testAlign(ptr++, 0x0F);
	testAlign(ptr++, 0x0E);
	testAlign(ptr++, 0x0D);
	testAlign(ptr++, 0x0C);
	testAlign(ptr++, 0x0B);
	testAlign(ptr++, 0x0A);
	testAlign(ptr++, 0x09);
	testAlign(ptr++, 0x08);
	testAlign(ptr++, 0x07);
	testAlign(ptr++, 0x06);
	testAlign(ptr++, 0x05);
	testAlign(ptr++, 0x04);
	testAlign(ptr++, 0x03);
	testAlign(ptr++, 0x02);
	testAlign(ptr++, 0x01);
	testAlign(ptr++, 0x10);
}

private size_t alignedSize(size_t sz)
{
	return ((sz + Allocator.alignment - 1) / Allocator.alignment) * Allocator.alignment;
}

unittest {
	logTrace("Testing memory.d ...");
	foreach( i; 0 .. 20 ){
		auto ia = alignedSize(i);
		assert(ia >= i);
		assert((ia & Allocator.alignmentMask) == 0);
		assert(ia < i+Allocator.alignment);
	}
}

private void ensureValidMemory(void[] mem)
{
	auto bytes = cast(ubyte[])mem;
	swap(bytes[0], bytes[$-1]);
	swap(bytes[0], bytes[$-1]);
}

template AllocSize(T)
{
	static if (is(T == class)) {
		// workaround for a strange bug where AllocSize!SSLStream == 0: TODO: dustmite!
		enum dummy = T.stringof ~ __traits(classInstanceSize, T).stringof;
		enum AllocSize = __traits(classInstanceSize, T);
	} else {
		enum AllocSize = T.sizeof;
	}
}

template RefTypeOf(T) {
	static if( is(T == class) || __traits(isAbstractClass, T) || is(T == interface) ){
		alias RefTypeOf = T;
	} else {
		alias RefTypeOf = T*;
	}
}