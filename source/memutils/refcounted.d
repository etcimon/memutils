module memutils.refcounted;

import memutils.allocators;
import memutils.helpers;
import memutils.utils;

struct RefCounted(T, ALLOC = ThreadMem)
{
	
nothrow:
@trusted:
	mixin Embed!(m_object, false);
	enum NOGC = true;
	enum isRefCounted = true;
	alias ThisType = RefCounted!(T, ALLOC);
	enum ElemSize = AllocSize!T;
	alias TR = RefTypeOf!T;	
	private TR m_object;
	private ulong* m_refCount;
	private void function(void*) m_free;
	pragma(inline)
	static RefCounted opCall(ARGS...)(auto ref ARGS args) nothrow
	{
		//logTrace("RefCounted opCall");
		//try { 
			RefCounted!(T, ALLOC) ret;
			if (!ret.m_object)
				ret.m_object = ObjectAllocator!(T, ALLOC).alloc(args);
			ret.m_refCount = ObjectAllocator!(ulong, ALLOC).alloc();
			(*ret.m_refCount) = 1;
			return ret;
		//} catch (Throwable e) { assert(false, "RefCounted.opCall(args) Throw: " ~ e.toString()); }
		assert(false, "Count not return from opCall");
	}
	
	~this()
	{
		dtor((cast(RefCounted*)&this)); 
	}
	
	static void dtor(U)(U* ctxt) {
		//logTrace("Call dtor ", U.stringof, " for ", typeof(this).stringof);
		static if (!is (U == typeof(this))) {
			ThisType* this_ = cast(ThisType*)ctxt;
			this_.m_object = cast(TR) ctxt.m_object;
			this_.m_refCount = cast(ulong*) ctxt.m_refCount;
			this_._deinit();
		}
		else {
			ctxt._clear();
		}
	}
	
	this(this)
	{
		//logTrace("this(this)");
		(cast(RefCounted*)&this).copyctor();
	}
	
	//@inline
	void copyctor() {
		
		if (!m_object) {
			defaultInit(); 
			//checkInvariants();
		}

		if (m_object) {
			//logTrace("copyctr ++", *m_refCount);
			(*m_refCount)++;
		} 	
	}
	
	void opAssign(U : RefCounted)(in U other) const nothrow
	{
		if (other.m_object is this.m_object) return;
			static if (is(U == RefCounted))
				(cast(RefCounted*)&this).opAssignImpl(other);
	}
	
	ref typeof(this) opAssign(U : RefCounted)(in U other) const nothrow
	{
		if (other.m_object is this.m_object) return;
		static if (is(U == RefCounted))
			(cast(RefCounted*)&this).opAssignImpl(other);
		return this;
	}
	
	private void opAssignImpl(U)(U other) {
		_clear();
		m_object = other.m_object;
		m_refCount = other.m_refCount;
		static if (!is (U == typeof(this))) {
			static void destr(void* ptr) {
				U.dtor(cast(ThisType*)ptr);
			}
			m_free = &destr;
		} else
			m_free = other.m_free;
		if( m_object ) {
			(*m_refCount)++;
			//logTrace("Incr: ", U.stringof, " = ", *m_refCount);
		}
	}
	
	private void _clear()
	{
		
		//logTrace("Clear: ", T.stringof, " = ", m_object ? *m_refCount : 9);
		//checkInvariants();
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
	}

	bool opCast(U : bool)() const nothrow
	{
		//try logTrace("RefCounted opcast: bool ", T.stringof); catch {}
		return !(!m_object || !m_refCount);
	}

	U opCast(U)() const nothrow
		if (__traits(hasMember, U, "isRefCounted"))
	{
		//static assert(U.sizeof == typeof(this).sizeof, "Error, U:  != this: ");
	
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
		//logTrace("OpCast++ ", *ret.m_refCount);
		(*ret.m_refCount) += 1;
		return ret;
	}

	U opCast(U : Object)() const nothrow
		if (!__traits(hasMember, U, "isRefCounted"))
	{
		// todo: check this
		return cast(U) m_object;
	}

	U opCast(U : TR)() nothrow
		if (!__traits(hasMember, U, "isRefCounted"))
	{
		// todo: check this
		return m_object;
	}
	//@inline
	private @property ulong refCount() const {
		if (!m_refCount) return 0;
		return *m_refCount;
	}

	private void _deinit() {
		//logTrace("_deinit");
		TR obj_ptr = m_object;
		//static if (!isPointer!T) // call destructors but not for indirections...
		//	.destroy(m_object);
		
		if (obj_ptr !is null)
			ObjectAllocator!(T, ALLOC).free(obj_ptr);
		
		ObjectAllocator!(ulong, ALLOC).free(m_refCount);
		m_refCount = null;
		m_object = null;
	}

	pragma(inline)
	private void defaultInit(ARGS...)(ARGS args) const {
		
		if (!m_object) {
			//logTrace("DefaultInit1");
			auto newObj = this.opCall(args);
			(cast(RefCounted*)&this).m_object = newObj.m_object;
			(cast(RefCounted*)&this).m_refCount = newObj.m_refCount;
			newObj.m_object = null;
			newObj.m_refCount = null;
		}
	}
	
	pragma(inline)
	private void defaultInit() const {
		
		if (!m_object) {
			//logTrace("DefaultInit2");
			auto newObj = this.opCall();
			(cast(RefCounted*)&this).m_object = newObj.m_object;
			(cast(RefCounted*)&this).m_refCount = newObj.m_refCount;
			newObj.m_object = null;
			newObj.m_refCount = null;
		}
	}

	pragma(inline)
	private void checkInvariants()
	const {
		//logTrace("Check invariants, m_object ", m_object ? '1' : '0', " refcount ", refCount);
		assert(!m_object || refCount > 0);
	}
}
