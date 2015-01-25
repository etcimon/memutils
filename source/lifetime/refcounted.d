module memutils.lifetime.refcounted;

import memutils.allocators.allocators;
import memutils.helpers;

struct RefCounted(T, int ALLOC = VulnerableAllocator)
{
	enum isRefCounted = true;
	static if (__traits(hasMember, T, "NOGC")) enum NOGC = T.NOGC;
	else enum NOGC = false;
	enum ElemSize = AllocSize!T;
	
	static if( is(T == class) ){
		alias TR = T;
	} else static if (__traits(isAbstractClass, T)) {
		alias TR = T;
	} else static if (is(T == interface)) {
		alias TR = T;
	} else {
		alias TR = T*;
	}
	
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
				T.stringof.countUntil("HashMapImpl!(string,") == -1)
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
	
	@property ref const(T) opStar() const
	{
		(cast(RefCounted*)&this).defaultInit();
		checkInvariants();
		static if (is(TR == T*)) return *m_object;
		else return m_object;
	}
	
	@property ref T opStar() {
		defaultInit();
		checkInvariants();
		static if (is(TR == T*)) return *m_object;
		else return m_object;
	}
	
	alias opStar this;
	
	auto opBinaryRight(string op, Key)(Key key)
	inout if (op == "in" && __traits(hasMember, typeof(m_object), "opBinaryRight")) {
		defaultInit();
		return opStar().opBinaryRight!("in")(key);
	}
	
	bool opCast(U : bool)() const {
		return m_object !is null;
	}
	
	bool opEquals(U)(U other) const
	{
		defaultInit();
		static if (__traits(compiles, (cast(TR)m_object).opEquals(cast(T) other.m_object)))
			return opStar().opEquals(cast(T) other.m_object);
		else
			return opStar().opEquals(other);
	}
	
	int opCmp(U)(U other) const
	{
		defaultInit();
		return opStar().opCmp(other);
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
	
	int opApply(U...)(U args)
		if (__traits(hasMember, typeof(m_object), "opApply"))
	{
		defaultInit();
		return opStar().opApply(args);
	}
	
	int opApply(U...)(U args) const
		if (__traits(hasMember, typeof(m_object), "opApply"))
	{
		defaultInit();
		return opStar().opApply(args);
	}
	
	void opSliceAssign(U...)(U args)
		if (__traits(hasMember, typeof(m_object), "opSliceAssign"))
	{
		defaultInit();
		opStar().opSliceAssign(args);
	}
	
	void defaultInit() inout {
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
	
	auto opSlice(U...)(U args) const
		if (__traits(hasMember, typeof(m_object), "opSlice"))
	{
		defaultInit();
		static if (is(U == void))
			return opStar().opSlice();
		else
			return opStar().opSlice(args);
		
	}
	
	size_t opDollar() const
	{
		static if (__traits(hasMember, typeof(m_object), "opDollar"))
			return opStar().opDollar();
		else assert(false, "Cannot call opDollar on object: " ~ T.stringof);
	}
	
	void opOpAssign(string op, U...)(U args)
		if (__traits(compiles, opStar().opOpAssign!op(args)))
	{
		defaultInit();
		opStar().opOpAssign!op(args);
	}
	
	//pragma(msg, T.stringof);
	static if (T.stringof == `Vector!(ubyte, 2)`) {
		void opOpAssign(string op, U)(U input)
			if (op == "^")
		{
			if (opStar().length < input.length)
				opStar().resize(input.length);
			
			xorBuf(opStar().ptr, input.ptr, input.length);
		}
	}
	auto opBinary(string op, U...)(U args)
		if (__traits(compiles, opStar().opBinary!op(args)))
	{
		defaultInit();
		return opStar().opBinary!op(args);
	}
	
	void opIndexAssign(U, V)(in U arg1, in V arg2)
		if (__traits(hasMember, typeof(opStar()), "opIndexAssign"))
	{
		
		defaultInit();
		opStar().opIndexAssign(arg1, arg2);
	}
	
	auto ref opIndex(U...)(U args) inout
		if (__traits(hasMember, typeof(opStar()), "opIndex"))
	{
		return opStar().opIndex(args);
	}
	
	static if (__traits(compiles, opStar().opBinaryRight!("in")(ReturnType!(opStar().front).init)))
		bool opBinaryRight(string op, U)(U e) const if (op == "in") 
	{
		defaultInit();
		return opStar().opBinaryRight!("in")(e);
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
