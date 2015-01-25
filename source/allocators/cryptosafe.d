module allocators.cryptosafe;

import memutils.allocators.allocators;

final class CryptoSafeAllocator(Base : Allocator) : Allocator
{
private:	
	__gshared SecurePool ms_zeroise;	
	Base m_secondary;
	
	shared static this() { 
		logTrace("Loading SecurePool ...");
		if (!ms_zeroise) ms_zeroise = new SecurePool;
	}
public:
	
	this() {
		m_secondary = getAllocator!VulnerableAllocatorImpl();
	}
	
	void[] alloc(size_t n)
	{
		if (void[] p = ms_zeroise.alloc(n)) {
			return p;
		}
		void[] p = m_secondary.alloc(n);
		return p;
	}
	
	void free(void[] mem)
	{
		import std.c.string : memset;
		memset(mem.ptr, 0, mem.length);
		if (ms_zeroise.free(mem))
			return;
		m_secondary.free(mem);
	}
	
}