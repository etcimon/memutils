/*
* Derived from Botan's Mlock Allocator
* 
* This is a more advanced base allocator.
* 
* (C) 2012,2014 Jack Lloyd
* (C) 2014,2015 Etienne Cimon
*
* Distributed under the terms of the Simplified BSD License (see Botan's license.txt)
*/
module memutils.cryptosafe;

static if (Have_Botan_d || Cryptosafe):

import memutils.allocators;
import memutils.constants;

final class CryptoSafeAllocator(Base : Allocator) : Allocator
{
private:	
	Base m_secondary;

	static if (Have_Botan_d || SecurePool) {

		__gshared SecurePool ms_zeroise;	
		shared static this() { 
			logTrace("Loading SecurePool ...");
			if (!ms_zeroise) ms_zeroise = new SecurePool;
		}
	}
public:
	
	this() {
		m_secondary = getAllocator!Base();
	}
	
	void[] alloc(size_t n)
	{
		static if (Have_Botan_d || SecurePool) {
			if (void[] p = ms_zeroise.alloc(n)) {
				return p;
			}
		}
		void[] p = m_secondary.alloc(n);
		return p;
	}
	
	void free(void[] mem)
	{
		import std.c.string : memset;
		memset(mem.ptr, 0, mem.length);
		static if (Have_Botan_d || SecurePool)
			if (ms_zeroise.free(mem))
				return;
		m_secondary.free(mem);
	}
	
}