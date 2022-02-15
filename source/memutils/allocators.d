/**
    Utility functions for memory management

    Copyright: © 2012-2013 RejectedSoftware e.K.
    		   © 2014-2015 Etienne Cimon
    License: Subject to the terms of the MIT license.
    Authors: Sönke Ludwig, Etienne Cimon
*/
module memutils.allocators;

public import memutils.constants;
import memutils.hashmap : HashMap;
import memutils.pool;
import memutils.memory;
import memutils.freelist;
import memutils.utils : Malloc;
import std.algorithm : swap;


alias LocklessAllocator = AutoFreeListAllocator!MallocAllocator;


struct Allocator {
	static enum size_t alignment = 0x10;

	static enum size_t alignmentMask = alignment-1;
}

package:
@trusted:


pragma(inline, true) nothrow
public auto getAllocator(int ALLOC)(bool is_freeing = false) {
	static if (ALLOC == LocklessFreeList) alias R = LocklessAllocator;
	else static if (ALLOC == Mallocator) alias R = MallocAllocator;
	else static assert(false, "Invalid allocator specified");
	return getAllocator!R(is_freeing);
}

nothrow R* getAllocator(R)(bool is_freeing = false, bool kill_it = false) {
	__gshared static R* alloc;
	__gshared static R alloc_;
	static bool deinit;
	if (kill_it) {
		import memutils.helpers : destructRecurse;
		destructRecurse(*alloc); 
		deinit = true;
		alloc = null;
		return null; 
	}
	if (!alloc && !is_freeing) {
		alloc_ = R();
		alloc = &alloc_;
	}
	return alloc;
}

nothrow:

//static ~this() {
//	getAllocator!LocklessAllocator(false, true);
//}

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

void* adjustPointerAlignment(void* base, ubyte* misalign_ = null)
{
	ubyte misalign = Allocator.alignment - (cast(size_t)base & Allocator.alignmentMask);
	base += misalign;
	if (misalign_) *misalign_ = misalign;
	else *(cast(ubyte*)base-1) = misalign;
	return base;
}

template AllocSize(T)
{
	static if (is(T == class)) {
		// workaround for a strange bug where AllocSize!SSLStream == 0: TODO: dustmite!
		//enum dummy = T.stringof ~ __traits(classInstanceSize, T).stringof;
		static enum AllocSize = __traits(classInstanceSize, T);
	} else {
		static enum AllocSize = T.sizeof;
	}
}

template RefTypeOf(T) {
	static if( is(T == class) || __traits(isAbstractClass, T) || is(T == interface) ){
		alias RefTypeOf = T;
	} else {
		alias RefTypeOf = T*;
	}
}

version(none):
unittest {
	void testAlign(void* p, size_t adjustment) {
		void* pa = adjustPointerAlignment(p);
		assert((cast(size_t)pa & Allocator.alignmentMask) == 0, "Non-aligned pointer.");
		//assert(*(cast(const(ubyte)*)pa-1) == adjustment, "Invalid adjustment "~to!string(p)~": "~to!string(*(cast(const(ubyte)*)pa-1)));
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
	foreach( i; 0 .. 20 ){
		auto ia = alignedSize(i);
		assert(ia >= i);
		assert((ia & Allocator.alignmentMask) == 0);
		assert(ia < i+Allocator.alignment);
	}
}
