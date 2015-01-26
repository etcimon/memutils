module memutils.refcounted;

import memutils.allocators;
import memutils.helpers;

struct RefCounted(T, int ALLOC = VulnerableAllocator)
{
	enum isRefCounted = true;

	static if (__traits(hasMember, T, "NOGC")) enum NOGC = T.NOGC;
	else enum NOGC = false;

	enum ElemSize = AllocSize!T;	
	alias TR = RefTypeOf!T;	
	private TR m_object;
	private ulong* m_refCount;
	private void function(void*) m_free;
	private size_t m_magic = 0x1EE75817; // workaround for compiler bug
	
	static RefCounted opCall(ARGS...)(auto ref ARGS args)
	{
		RefCounted ret;
		auto mem = getAllocator!VulnerableAllocatorImpl().alloc(ElemSize);
		ret.m_refCount = cast(ulong*)getAllocator!VulnerableAllocatorImpl().alloc(ulong.sizeof).ptr;
		(*ret.m_refCount) = 1;
		static if( hasIndirections!T && !NOGC) GC.addRange(mem.ptr, ElemSize);
		ret.m_object = cast(TR)emplace!(Unqual!T)(mem, args);
		return ret;
	}
	
	const ~this()
	{
		dtor((cast(RefCounted*)&this));
		(cast(RefCounted*)&this).m_magic = 0;
	}
	
	static void dtor(U)(U* ctxt) {
		static if (!is (U == typeof(this))) {
			typeof(this)* this_ = cast(typeof(this)*)ctxt;
			this_.m_object = cast(typeof(this.m_object)) ctxt.m_object;
			this_._deinit();
		}
		else {
			ctxt._clear();
		}
	}
	
	const this(this)
	{
		(cast(RefCounted*)&this).copyctor();
	}
	
	void copyctor() {
		
		if (!m_object) {
			defaultInit();
			import backtrace.backtrace;
			import std.stdio : stdout;
			static if (T.stringof.countUntil("OIDImpl") == -1 &&
				T.stringof.countUntil("HashMap!(string,") == -1)
				printPrettyTrace(stdout, PrintOptions.init, 3); 
		}
		checkInvariants();
		if (m_object) (*m_refCount)++; 
		
	}
	
	void opAssign(U : RefCounted)(in U other) const
	{
		if (other.m_object is this.m_object) return;
		static if (is(U == RefCounted))
			(cast(RefCounted*)&this).opAssignImpl(*cast(U*)&other);
	}
	
	ref typeof(this) opAssign(U : RefCounted)(in U other) const
	{
		if (other.m_object is this.m_object) return;
		static if (is(U == RefCounted))
			(cast(RefCounted*)&this).opAssignImpl(*cast(U*)&other);
		return this;
	}
	
	private void opAssignImpl(U)(U other) {
		_clear();
		m_object = cast(typeof(this.m_object))other.m_object;
		m_refCount = other.m_refCount;
		static if (!is (U == typeof(this))) {
			static void destr(void* ptr) {
				U.dtor(cast(typeof(&this))ptr);
			}
			m_free = &destr;
		} else
			m_free = other.m_free;
		if( m_object )
			(*m_refCount)++;
	}
	
	private void _clear()
	{
		checkInvariants();
		if( m_object ){
			if( --(*m_refCount) == 0 ){
				if (m_free)
					m_free(cast(void*)&this);
				else {
					_deinit();
				}
			}
		}
		
		m_object = null;
		m_refCount = null;
		m_free = null;
		m_magic = 0x1EE75817;
	}
	
	private void _deinit() {
		auto objc = m_object;
		static if (is(TR == T*)) .destroy(*objc);
		else .destroy(objc);
		static if( hasIndirections!T && !NOGC ) GC.removeRange(cast(void*)m_object);
		getAllocator!VulnerableAllocatorImpl().free((cast(void*)m_object)[0 .. ElemSize]);
		getAllocator!VulnerableAllocatorImpl().free((cast(void*)m_refCount)[0 .. ulong.sizeof]);
	}

	U opCast(U)() const nothrow
		if (!is ( U == bool ))
	{
		assert(U.sizeof == typeof(this).sizeof, "Error, U: "~ U.sizeof.to!string~ " != this: " ~ typeof(this).sizeof.to!string);
		try { 
			U ret = U.init;
			ret.m_object = cast(U.TR)this.m_object;
			
			static if (!is (U == typeof(this))) {
				if (!m_free) {
					static void destr(void* ptr) {
						dtor(cast(U*)ptr);
					}
					ret.m_free = &destr;
				}
				else
					ret.m_free = m_free;
			}
			else ret.m_free = m_free;
			
			ret.m_refCount = cast(ulong*)this.m_refCount;
			(*ret.m_refCount) += 1;
			return ret;
		} catch(Throwable e) { try logError("Error in catch: ", e.toString()); catch {} }
		return U.init;
	}
		
	private @property ulong refCount() const {
		return *m_refCount;
	}
	
	private void checkInvariants()
	const {
		assert(m_magic == 0x1EE75817, "Magic number of " ~ T.stringof ~ " expected 0x1EE75817, set to: " ~ m_magic.to!string);
		assert(!m_object || refCount > 0, (!m_object) ? "No m_object" : "Zero Refcount: " ~ refCount.to!string);
	}
}
