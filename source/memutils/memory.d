/**
	Memory provider allocators to be used in templated composition 
	within other, designated allocators.

    Copyright: © 2012-2013 RejectedSoftware e.K.
    		   © 2014-2015 Etienne Cimon
    License: Subject to the terms of the MIT license.
    Authors: Sönke Ludwig, Etienne Cimon
*/
module memutils.memory;

import memutils.allocators;
import memutils.helpers;
import memutils.constants;

struct MallocAllocator {
nothrow:
@trusted:
	void[] alloc(size_t sz, bool must_zeroise = true)
	{
		logInfo("Mallocating sz ", sz);
		auto ptr = wasm_malloc(sz + Allocator.alignment);
		if (ptr is null) return null;
		
		auto mem = adjustPointerAlignment(ptr)[0 .. sz];
		memset(mem.ptr, 0, mem.length);
		return mem;
	}

	void[] realloc(void[] mem, size_t new_size, bool must_zeroise = true)
	{
		size_t csz = min(mem.length, new_size);
		auto p = extractUnalignedPointer(mem.ptr);
		size_t oldmisalign = mem.ptr - p;
		ubyte misalign;
		auto pn = cast(ubyte*)wasm_realloc(p, mem.length, new_size+Allocator.alignment);
		if (must_zeroise) memset(pn + mem.length, 0, new_size - mem.length);
		if (p == pn) return pn[oldmisalign .. new_size+oldmisalign];
		
		auto pna = cast(ubyte*)adjustPointerAlignment(pn, &misalign);
		scope(exit) 
			*(cast(ubyte*)pna-1) = misalign;
		auto newmisalign = pna - pn;
		
		// account for changed alignment after realloc (move memory back to aligned position)
		if (oldmisalign != newmisalign) {
			if (newmisalign > oldmisalign) {
				foreach_reverse (i; 0 .. csz)
					pn[i + newmisalign] = pn[i + oldmisalign];
			} else {
				foreach (i; 0 .. csz)
					pn[i + newmisalign] = pn[i + oldmisalign];
			}
		}
		
		auto mem2 = pna[0 .. new_size];
		return mem2;
	}
	
	void free(void[] mem, bool must_zeroise = true)
	{
		if (must_zeroise) memset(mem.ptr, 0, mem.length);
		wasm_free(extractUnalignedPointer(mem.ptr), mem.length);
	}
}