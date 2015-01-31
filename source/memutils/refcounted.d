module memutils.refcounted;

import memutils.allocators;
import memutils.helpers;
import std.conv : to, emplace;
import std.traits : hasIndirections, Unqual, isImplicitlyConvertible;
import memutils.utils;
import std.algorithm : countUntil;

struct RefCounted(T, ALLOC = ThisThread)
{
	import core.memory : GC;
	mixin Embed!m_object;

	enum isRefCounted = true;

	enum ElemSize = AllocSize!T;
	alias TR = RefTypeOf!T;	
	private TR m_object;
	private ulong* m_refCount;
	private void function(void*) m_free;
	private size_t m_magic = 0x1EE75817; // workaround for compiler bug
	
	static RefCounted opCall(ARGS...)(auto ref ARGS args)
	{
		RefCounted ret;
		ret.m_object = ObjectAllocator!(T, ALLOC).alloc(args);
		ret.m_refCount = ObjectAllocator!(ulong, ALLOC).alloc();
		(*ret.m_refCount) = 1;
		logTrace("Allocating: ", cast(void*)ret.m_object, " of ", T.stringof, " sz: ", ElemSize, " allocator: ", ALLOC.stringof);
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
			import backtrace.backtrace;
			import std.stdio : stdout;
			static if (T.stringof.countUntil("OIDImpl") == -1 &&
				T.stringof.countUntil("HashMap!(string,") == -1)
				printPrettyTrace(stdout, PrintOptions.init, 3); 
			defaultInit();
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
				logTrace("Clearing Object: ", cast(void*)m_object);
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

	bool opCast(U : bool)() const nothrow
	{
		return !(m_object is null && !m_refCount && !m_free);
	}

	U opCast(U)() const nothrow
		if (__traits(hasMember, U, "isRefCounted") && (isImplicitlyConvertible!(U.T, T) || isImplicitlyConvertible!(T, U.T)))
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

	private void _deinit() {
		//logDebug("Freeing: ", T.stringof, " ptr ", cast(void*) m_object, " sz: ", ElemSize, " allocator: ", ALLOC.stringof);
		ObjectAllocator!(T, ALLOC).free(m_object);
		//logDebug("Freeing refCount: ", cast(void*)m_refCount);
		ObjectAllocator!(ulong, ALLOC).free(m_refCount);
	}


	private @property ulong refCount() const {
		return *m_refCount;
	}


	private void defaultInit() inout {
		static if (is(TR == T*)) {
			if (!m_object) {
				auto newObj = this.opCall();
				(cast(RefCounted*)&this).m_object = newObj.m_object;
				(cast(RefCounted*)&this).m_refCount = newObj.m_refCount;
				//(cast(RefCounted*)&this).m_magic = 0x1EE75817;
				newObj.m_object = null;
			}
		}
		
	}
	
	private void checkInvariants()
	const {
		assert(m_magic == 0x1EE75817, "Magic number of " ~ T.stringof ~ " expected 0x1EE75817, set to: " ~ (cast(void*)m_magic).to!string);
		assert(!m_object || refCount > 0, (!m_object) ? "No m_object" : "Zero Refcount: " ~ refCount.to!string);
	}
}
