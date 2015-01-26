/**
    Utility functions for memory management

    Copyright: © 2012-2013 RejectedSoftware e.K.
    		   © 2014-2015 Etienne Cimon
    License: Subject to the terms of the MIT license.
    Authors: Sönke Ludwig, Etienne Cimon
*/
module memutils.allocators;

public import memutils.constants;
import core.exception : OutOfMemoryError;
import core.stdc.stdlib;
import core.memory;
import std.conv;
import std.exception : enforceEx;
import std.traits;
import std.algorithm;
import std.traits : ReturnType;
import memutils.hashmap : HashMap;
import memutils.pool;
import memutils.memory;
import memutils.cryptosafe;
import memutils.freelist;

static if (HasDebugAllocations) {
	alias LocklessAllocator = DebugAllocator!(AutoFreeListAllocator!(MallocAllocator));
	static if (HasCryptoSafe)
		alias CryptoSafeAllocator = DebugAllocator!(SecureAllocator!(AutoFreeListAllocator!(MallocAllocator)));
	alias FiberPool = PoolAllocator!LocklessAllocator;
	alias ProxyGCAllocator = DebugAllocator!GCAllocator;
}
else {
	alias LocklessAllocator = AutoFreeListAllocator!(MallocAllocator);
	static if (HasCryptoSafe)
		alias CryptoSafeAllocator = SecureAllocator!LocklessAllocator;
	alias FiberPool = PoolAllocator!LocklessAllocator;
	alias ProxyGCAllocator = GCAllocator;

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

/**
* Another proxy allocator used to aggregate statistics and to enforce correct usage.
*/
final class DebugAllocator(Base) : Allocator {
	private {
		Base m_baseAlloc;
		HashMap!(void*, size_t, Mallocator) m_blocks;
		size_t m_bytes;
		size_t m_maxBytes;
	}
	
	this()
	{
		m_baseAlloc = getAllocator!Base();
		m_blocks = HashMap!(void*, size_t, Mallocator)();
	}
	
	@property size_t allocatedBlockCount() const { return m_blocks.length; }
	@property size_t bytesAllocated() const { return m_bytes; }
	@property size_t maxBytesAllocated() const { return m_maxBytes; }
	
	void[] alloc(size_t sz)
	{
		auto ret = m_baseAlloc.alloc(sz);
		synchronized(this) {
			assert(ret.length == sz, "base.alloc() returned block with wrong size.");
			assert(m_blocks.get(cast(const)ret.ptr, size_t.max) == size_t.max, "base.alloc() returned block that is already allocated.");
			m_blocks[ret.ptr] = sz;
			m_bytes += sz;
			if( m_bytes > m_maxBytes ){
				m_maxBytes = m_bytes;
				//logDebug("New allocation maximum: %d (%d blocks)", m_maxBytes, m_blocks.length);
			}
		}
		return ret;
	}

	void[] realloc(void[] mem, size_t new_size)
	{
		void[] ret;
		size_t sz;
		synchronized(this) {
			sz = m_blocks.get(mem.ptr, size_t.max);
			assert(sz != size_t.max, "realloc() called with non-allocated pointer.");
			assert(sz == mem.length, "realloc() called with block of wrong size.");
		}
		ret = m_baseAlloc.realloc(mem, new_size);
		synchronized(this) {
			assert(ret.length == new_size, "base.realloc() returned block with wrong size.");
			assert(ret.ptr is mem.ptr || m_blocks.get(ret.ptr, size_t.max) == size_t.max, "base.realloc() returned block that is already allocated.");
			m_bytes -= sz;
			m_blocks.remove(mem.ptr);
			m_blocks[ret.ptr] = new_size;
			m_bytes += new_size;
		}
		return ret;
	}

	void free(void[] mem)
	{
		size_t sz;
		synchronized(this) {
			sz = m_blocks.get(cast(const)mem.ptr, size_t.max);
			assert(sz != size_t.max, "free() called with non-allocated object.");
			assert(sz == mem.length, "free() called with block of wrong size.");
		}

		m_baseAlloc.free(mem);

		synchronized(this) {
			m_bytes -= sz;
			m_blocks.remove(mem.ptr);
		}
	}
}

package:

static HashMap!(void*, FiberPool, Mallocator) g_fiberAlloc;

auto getAllocator(int ALLOC)() {
	static if (ALLOC == LocklessFreeList) alias R = LocklessAllocator;
	else static if (ALLOC == NativeGC) alias R = ProxyGCAllocator;
	else static if (HasCryptoSafe && ALLOC == CryptoSafe) alias R = CryptoSafeAllocator;
	else static if (ALLOC == ScopedFiberPool) alias R = FiberPool;
	else static if (ALLOC == Mallocator) alias R = MallocAllocator;
	else static assert(false, "Invalid allocator specified");

	return getAllocator!R();
}

R getAllocator(R)() {
	static if (R.stringof == "ProxyGCAllocator") {	
		static __gshared R alloc;
		
		if (!alloc)
			alloc = new R;
		
		return alloc;
	}
	else static if (R.stringof == "FiberPool") {
		import core.thread : Fiber;
		
		auto f = Fiber.getThis();
		if (!f)
			return getAllocator!GCAllocator();
		if (auto ptr = (&f in g_fiberAlloc)) {
			return *ptr;
		}
		
		auto ret = new FiberPool();
		g_fiberAlloc[&f] = ret;
		return ret;
	}
	else {
		static R alloc;
		
		if (!alloc)
			alloc = new R;
		return alloc;
	}
}

string translateAllocator() { /// requires (int ALLOC) template parameter
	return `
	static assert(ALLOC, "The 'int ALLOC' template parameter is not in scope.");
	ReturnType!(getAllocator!ALLOC) thisAllocator() {
		return getAllocator!ALLOC();
	}`;
}

size_t alignedSize(size_t sz)
{
	return ((sz + Allocator.alignment - 1) / Allocator.alignment) * Allocator.alignment;
}

void ensureValidMemory(void[] mem)
{
	auto bytes = cast(ubyte[])mem;
	swap(bytes[0], bytes[$-1]);
	swap(bytes[0], bytes[$-1]);
}

void* extractUnalignedPointer(void* base)
{
	ubyte misalign = *(cast(const(ubyte)*)base-1);
	assert(misalign <= Allocator.alignment);
	return base - misalign;
}

void* adjustPointerAlignment(void* base)
{
	ubyte misalign = Allocator.alignment - (cast(size_t)base & Allocator.alignmentMask);
	base += misalign;
	*(cast(ubyte*)base-1) = misalign;
	return base;
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

unittest {
	logTrace("Testing memory.d ...");
	foreach( i; 0 .. 20 ){
		auto ia = alignedSize(i);
		assert(ia >= i);
		assert((ia & Allocator.alignmentMask) == 0);
		assert(ia < i+Allocator.alignment);
	}
}