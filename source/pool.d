/**
	Memory pool with destructors, useful for scoped allocators.

    Copyright: © 2012-2013 RejectedSoftware e.K.
    		   © 2014-2015 Etienne Cimon
    License: Subject to the terms of the MIT license.
    Authors: Sönke Ludwig, Etienne Cimon
*/
module memutils.pool;

import memutils.allocators;

final class PoolAllocator(Base : Allocator) : Allocator {
	static struct Pool { Pool* next; void[] data; void[] remaining; }
	static struct Destructor { Destructor* next; void function(void*) destructor; void* object; }
	private {
		Allocator m_baseAllocator;
		Pool* m_freePools;
		Pool* m_fullPools;
		Destructor* m_destructors;
		size_t m_poolSize;
	}
	
	this(size_t pool_size, Allocator base)
	{
		m_poolSize = pool_size;
		m_baseAllocator = base;
	}
	
	@property size_t totalSize()
	{
		size_t amt = 0;
		for (auto p = m_fullPools; p; p = p.next)
			amt += p.data.length;
		for (auto p = m_freePools; p; p = p.next)
			amt += p.data.length;
		return amt;
	}
	
	@property size_t allocatedSize()
	{
		size_t amt = 0;
		for (auto p = m_fullPools; p; p = p.next)
			amt += p.data.length;
		for (auto p = m_freePools; p; p = p.next)
			amt += p.data.length - p.remaining.length;
		return amt;
	}
	
	void[] alloc(size_t sz)
	{
		auto aligned_sz = alignedSize(sz);
		
		Pool* pprev = null;
		Pool* p = cast(Pool*)m_freePools;
		while( p && p.remaining.length < aligned_sz ){
			pprev = p;
			p = p.next;
		}
		
		if( !p ){
			auto pmem = m_baseAllocator.alloc(AllocSize!Pool);
			
			p = emplace!Pool(pmem);
			p.data = m_baseAllocator.alloc(max(aligned_sz, m_poolSize));
			p.remaining = p.data;
			p.next = cast(Pool*)m_freePools;
			m_freePools = p;
			pprev = null;
		}
		
		auto ret = p.remaining[0 .. aligned_sz];
		p.remaining = p.remaining[aligned_sz .. $];
		if( !p.remaining.length ){
			if( pprev ){
				pprev.next = p.next;
			} else {
				m_freePools = p.next;
			}
			p.next = cast(Pool*)m_fullPools;
			m_fullPools = p;
		}
		
		return ret[0 .. sz];
	}
	
	void[] realloc(void[] arr, size_t newsize)
	{
		auto aligned_sz = alignedSize(arr.length);
		auto aligned_newsz = alignedSize(newsize);
		
		if( aligned_newsz <= aligned_sz ) return arr[0 .. newsize]; // TODO: back up remaining
		
		auto pool = m_freePools;
		bool last_in_pool = pool && arr.ptr+aligned_sz == pool.remaining.ptr;
		if( last_in_pool && pool.remaining.length+aligned_sz >= aligned_newsz ){
			pool.remaining = pool.remaining[aligned_newsz-aligned_sz .. $];
			arr = arr.ptr[0 .. aligned_newsz];
			assert(arr.ptr+arr.length == pool.remaining.ptr, "Last block does not align with the remaining space!?");
			return arr[0 .. newsize];
		} else {
			auto ret = alloc(newsize);
			assert(ret.ptr >= arr.ptr+aligned_sz || ret.ptr+ret.length <= arr.ptr, "New block overlaps old one!?");
			ret[0 .. min(arr.length, newsize)] = arr[0 .. min(arr.length, newsize)];
			return ret;
		}
	}
	
	void free(void[] mem)
	{
	}
	
	void freeAll()
	{
		// destroy all initialized objects
		for (auto d = m_destructors; d; d = d.next)
			d.destructor(cast(void*)d.object);
		m_destructors = null;
		
		// put all full Pools into the free pools list
		for (Pool* p = cast(Pool*)m_fullPools, pnext; p; p = pnext) {
			pnext = p.next;
			p.next = cast(Pool*)m_freePools;
			m_freePools = cast(Pool*)p;
		}
		
		// free up all pools
		for (Pool* p = cast(Pool*)m_freePools; p; p = p.next)
			p.remaining = p.data;
	}
	
	void reset()
	{
		freeAll();
		Pool* pnext;
		for (auto p = cast(Pool*)m_freePools; p; p = pnext) {
			pnext = p.next;
			m_baseAllocator.free(p.data);
			m_baseAllocator.free((cast(void*)p)[0 .. AllocSize!Pool]);
		}
		m_freePools = null;
		
	}
	
	private static destroy(T)(void* ptr)
	{
		static if( is(T == class) ) .destroy(cast(T)ptr);
		else .destroy(*cast(T*)ptr);
	}
}
