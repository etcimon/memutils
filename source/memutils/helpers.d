module memutils.helpers;
public:

template UnConst(T) {
	static if (is(T U == const(U))) {
		alias UnConst = U;
	} else static if (is(T V == immutable(V))) {
		alias UnConst = V;
	} else alias UnConst = T;
}

/// TODO: Imitate Unique! for all objects (assume dtor) with release()
/// TODO: implement @override on underlying type T, and check for shadowed members.
mixin template Embed(alias OBJ, alias OWNED)
{
	import std.traits : hasMember;
	alias TR = typeof(OBJ);
	static if (is(typeof(*OBJ) == struct))
			alias T = typeof(*OBJ);
	else
		alias T = TR;

	import std.traits : isSomeFunction;
	static if (!isSomeFunction!OBJ)
	@property ref const(T) fallthrough() const return
	{
		static if (__traits(hasMember, typeof(this), "defaultInit")) {
			(cast(typeof(this)*)&this).defaultInit();
			checkInvariants();
		}
		static if (is(TR == T*)) return *OBJ;
		else return OBJ;
	}

	@property ref T fallthrough() return
	{
		static if (__traits(hasMember, typeof(this), "defaultInit")) {
			defaultInit();
			checkInvariants();
		}
		static if (is(TR == T*)) return *OBJ;
		else return OBJ;
	}
	
	@property ref const(T) opUnary(string op)() const if (op == "*")
	{
		return (cast(typeof(this)*)&this).fallthrough;
	}
	
	
	alias fallthrough this;
	
	static if (!isSomeFunction!OBJ)
	@property TR release() {
		static if (__traits(hasMember, typeof(this), "defaultInit")) {
			defaultInit();
			checkInvariants();
		}
		TR ret = OBJ;
		OBJ = null;
		return ret;
	}

	auto opBinaryRight(string op, Key)(Key key)
	inout if (op == "in" && __traits(hasMember, typeof(OBJ), "opBinaryRight")) {
		defaultInit();
		return fallthrough().opBinaryRight!("in")(key);
	}

	bool opEquals(U)(auto ref U other) const
	{
		defaultInit();
		return fallthrough().opEquals(other);
	}
	
	int opCmp(U)(auto ref U other) const
	{
		defaultInit();
		return fallthrough().opCmp(other);
	}
	
	int opApply(U...)(U args)
		if (__traits(hasMember, typeof(OBJ), "opApply"))
	{
		defaultInit();
		return fallthrough().opApply(args);
	}
	
	int opApply(U...)(U args) const
		if (__traits(hasMember, typeof(OBJ), "opApply"))
	{
		defaultInit();
		return fallthrough().opApply(args);
	}
	
	void opSliceAssign(U...)(U args)
		if (__traits(hasMember, typeof(OBJ), "opSliceAssign"))
	{
		defaultInit();
		fallthrough().opSliceAssign(args);
	}

	
	auto opSlice(U...)(U args) const
		if (__traits(hasMember, typeof(OBJ), "opSlice"))
	{
		defaultInit();
		return (cast()fallthrough()).opSlice(args);
		
	}

	static if (__traits(hasMember, typeof(OBJ), "opDollar"))
	size_t opDollar() const
	{
		return fallthrough().opDollar();
	}
	
	void opOpAssign(string op, U...)(auto ref U args)
		if (__traits(compiles, fallthrough().opOpAssign!op(args)))
	{
		defaultInit();
		fallthrough().opOpAssign!op(args);
	}
	
	auto opBinary(string op, U...)(auto ref U args)
		if (__traits(compiles, fallthrough().opBinary!op(args)))
	{
		defaultInit();
		return fallthrough().opBinary!op(args);
	}
	
	void opIndexAssign(U, V)(auto const ref U arg1, auto const ref V arg2)
		if (__traits(hasMember, typeof(fallthrough()), "opIndexAssign"))
	{		
		defaultInit();
		fallthrough().opIndexAssign(arg1, arg2);
	}
	
	auto ref opIndex(U...)(U args) inout
		if (__traits(hasMember, typeof(fallthrough()), "opIndex"))
	{
		return fallthrough().opIndex(args);
	}
	
	static if (__traits(compiles, fallthrough().opBinaryRight!("in")(ReturnType!(fallthrough().front).init)))
		bool opBinaryRight(string op, U)(auto ref U e) const if (op == "in") 
	{
		defaultInit();
		return fallthrough().opBinaryRight!("in")(e);
	}
}