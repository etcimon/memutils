module memutils.debugger;
import memutils.allocators;
import memutils.hashmap;

/**
* Another proxy allocator used to aggregate statistics and to enforce correct usage.
*/
final class DebugAllocator(Base : Allocator) : Allocator {
	private {
		HashMap!(size_t, size_t, Malloc) m_blocks;
		size_t m_bytes;
		size_t m_maxBytes;
	}
	package Base m_baseAlloc;
	
	this()
	{
		m_baseAlloc = getAllocator!Base();
	}

	~this() { m_blocks.clear(); }
	public {
		@property size_t allocatedBlockCount() const { return m_blocks.length; }
		@property size_t bytesAllocated() const { return m_bytes; }
		@property size_t maxBytesAllocated() const { return m_maxBytes; }
		void printMap() {
			foreach(const ref size_t ptr, const ref size_t sz; m_blocks) {
				logDebug(cast(void*)ptr, " sz ", sz);
			}
		}
	}
	void[] alloc(size_t sz)
	{

		assert(sz > 0, "Cannot serve a zero-length allocation");

		//logTrace("Bytes allocated in ", Base.stringof, ": ", bytesAllocated());
		auto ret = m_baseAlloc.alloc(sz);
		synchronized(this) {
			assert(ret.length == sz, "base.alloc() returned block with wrong size.");

			/*try {
				assert(m_blocks.get(cast(const size_t)ret.ptr, size_t.max) == size_t.max, "base.alloc() returned block that is already allocated: " ~ ret.ptr.to!string ~ " sz: " ~ ret.length.to!string ~ " was: " ~ m_blocks.get(cast(const size_t)ret.ptr, size_t.max).to!string);
			} catch (Throwable e) { import std.stdio : writeln; writeln(e.toString()); }
*/
			m_blocks[cast(size_t)ret.ptr] = sz;
			m_bytes += sz;
			if( m_bytes > m_maxBytes ){
				m_maxBytes = m_bytes;
				//logTrace("New allocation maximum: %d (%d blocks)", m_maxBytes, m_blocks.length);
			}
		}


		//logDebug("Alloc ptr: ", ret.ptr, " sz: ", ret.length);
		
		return ret;
	}
	
	void[] realloc(void[] mem, size_t new_size)
	{
		assert(new_size > 0 && mem.length > 0, "Cannot serve a zero-length reallocation");
		void[] ret;
		size_t sz;
		synchronized(this) {
			sz = m_blocks.get(cast(size_t)mem.ptr, size_t.max);
			assert(sz != size_t.max, "realloc() called with non-allocated pointer.");
			assert(sz == mem.length, "realloc() called with block of wrong size.");
		}
		ret = m_baseAlloc.realloc(mem, new_size);
		synchronized(this) {
			assert(ret.length == new_size, "base.realloc() returned block with wrong size.");
			//assert(ret.ptr is mem.ptr || m_blocks.get(ret.ptr, size_t.max) == size_t.max, "base.realloc() returned block that is already allocated.");
			m_bytes -= sz;
			m_blocks.remove(cast(size_t)mem.ptr);
			m_blocks[cast(size_t)ret.ptr] = new_size;
			m_bytes += new_size;
		}
		return ret;
	}
	
	void free(void[] mem)
	{
		assert(mem.length > 0, "Cannot serve a zero-length deallocation");

		size_t sz;
		synchronized(this) {
			sz = m_blocks.get(cast(const size_t)mem.ptr, size_t.max);

			assert(sz != size_t.max, "free() called with non-allocated object. "~ mem.ptr.to!string ~ " (" ~ mem.length.to!string ~" B) m_blocks len: "~ m_blocks.length.to!string);
			assert(sz == mem.length, "free() called with block of wrong size: got " ~ mem.length.to!string ~ "B but should be " ~ sz.to!string ~ "B");

		}

		//logDebug("free ptr: ", mem.ptr, " sz: ", mem.length);
		m_baseAlloc.free(mem);
		
		synchronized(this) {
			m_bytes -= sz;
			m_blocks.remove(cast(size_t)mem.ptr);
		}
	}

	package void ignore(void* ptr) {
		synchronized(this) {
			size_t sz = m_blocks.get(cast(const size_t) ptr, size_t.max);
			m_bytes -= sz;
			m_blocks.remove(cast(size_t)ptr);
		}
	}
}