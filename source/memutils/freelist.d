/**
	FreeList allocator proxy templates used to prevent memory segmentation
	on base allocator.

    Copyright: © 2012-2013 RejectedSoftware e.K.
    		   © 2014-2015 Etienne Cimon
    License: Subject to the terms of the MIT license.
    Authors: Sönke Ludwig, Etienne Cimon
*/
module memutils.freelist;

import memutils.allocators;
import std.algorithm : min;

final class AutoFreeListAllocator(Base : Allocator) : Allocator {
	import std.typetuple;
	
	private {
		enum minExponent = 3;
		enum freeListCount = 12;
		FreeListAlloc!Base[freeListCount] m_freeLists;
		Base m_baseAlloc;
	}
	
	this()
	{
		m_baseAlloc = getAllocator!Base();
		foreach (i; iotaTuple!freeListCount)
			m_freeLists[i] = new FreeListAlloc!Base(nthFreeListSize!(i));
	}

	~this() {
		foreach(fl; m_freeLists)
			destroy(fl);
	}
	
	void[] alloc(size_t sz)
	{
		logTrace("AFL alloc ", sz);
		if (sz > nthFreeListSize!(freeListCount-1)) return m_baseAlloc.alloc(sz);
		foreach (i; iotaTuple!freeListCount)
			if (sz <= nthFreeListSize!(i))
				return m_freeLists[i].alloc().ptr[0 .. sz];
		assert(false);
	}

	void[] realloc(void[] data, size_t sz)
	{
		foreach (fl; m_freeLists) {
			if (data.length <= fl.elementSize) {
				// just grow the slice if it still fits into the free list slot
				if (sz <= fl.elementSize)
					return data.ptr[0 .. sz];
				
				// otherwise re-allocate
				auto newd = alloc(sz);
				assert(newd.ptr+sz <= data.ptr || newd.ptr >= data.ptr+data.length, "New block overlaps old one!?");
				auto len = min(data.length, sz);
				newd[0 .. len] = data[0 .. len];
				free(data);
				return newd;
			}
		}
		// forward large blocks to the base allocator
		return m_baseAlloc.realloc(data, sz);
	}

	void free(void[] data)
	{
		logTrace("AFL free ", data.length);
		if (data.length > nthFreeListSize!(freeListCount-1)) {
			m_baseAlloc.free(data);
			return;
		}
		foreach(i; iotaTuple!freeListCount) {
			if (data.length <= nthFreeListSize!i) {
				m_freeLists[i].free(data.ptr[0 .. nthFreeListSize!i]);
				return;
			}
		}
		assert(false);
	}
	
	private static pure size_t nthFreeListSize(size_t i)() { return 1 << (i + minExponent); }
	private template iotaTuple(size_t i) {
		static if (i > 1) alias iotaTuple = TypeTuple!(iotaTuple!(i-1), i-1);
		else alias iotaTuple = TypeTuple!(0);
	}
}

final class FreeListAlloc(Base : Allocator) : Allocator
{
	import memutils.vector : Vector;
	import memutils.utils : Malloc;
	private static struct FreeListSlot { FreeListSlot* next; }
	private {
		immutable size_t m_elemSize;
		Base m_baseAlloc;
		FreeListSlot* m_firstFree = null;
		size_t[] m_owned;
		size_t m_nalloc = 0;
		size_t m_nfree = 0;
	}

	~this() {
		import core.thread : thread_isMainThread;
		if (!thread_isMainThread)
			foreach(size_t slot; m_owned) {
				m_baseAlloc.free( (cast(void*)slot)[0 .. m_elemSize]);
			}
	}
	
	this(size_t elem_size)
	{
		assert(elem_size >= size_t.sizeof);
		m_elemSize = elem_size;
		m_baseAlloc = getAllocator!Base();
		//logTrace("Create FreeListAlloc %d", m_elemSize);
	}
	
	@property size_t elementSize() const { return m_elemSize; }
	
	void[] alloc(size_t sz)
	{
		assert(sz == m_elemSize, "Invalid allocation size.");
		return alloc();
	}
	
	void[] alloc()
	{
		void[] mem;
		if( m_firstFree ){
			auto slot = m_firstFree;
			m_firstFree = slot.next;
			slot.next = null;
			mem = (cast(void*)slot)[0 .. m_elemSize];
			m_nfree--;
		} else {
			mem = m_baseAlloc.alloc(m_elemSize);
			if (!thread_isMainThread)
				m_owned ~= cast(size_t)mem.ptr;
			//logInfo("Alloc %d bytes: alloc: %d, free: %d", SZ, s_nalloc, s_nfree);
		}
		m_nalloc++;
		//logInfo("Alloc %d bytes: alloc: %d, free: %d", SZ, s_nalloc, s_nfree);
		return mem;
	}

	void[] realloc(void[] mem, size_t sz)
	{
		assert(mem.length == m_elemSize);
		assert(sz == m_elemSize);
		return mem;
	}

	void free(void[] mem)
	{
		assert(mem.length == m_elemSize, "Memory block passed to free has wrong size.");
		auto s = cast(FreeListSlot*)mem.ptr;
		s.next = m_firstFree;
		m_firstFree = s;
		m_nalloc--;
		m_nfree++;
	}
}
