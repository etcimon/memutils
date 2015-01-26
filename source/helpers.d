module memutils.helpers;

package:

template UnConst(T) {
	static if (is(T U == const(U))) {
		alias UnConst = U;
	} else static if (is(T V == immutable(V))) {
		alias UnConst = V;
	} else alias UnConst = T;
}

mixin template Embed(alias OBJ)
{
	alias TR = typeof(OBJ);
	static if (is(typeof(*OBJ) == struct))
			alias T = typeof(*OBJ);
	else
		alias T = TR;

	@property ref const(T) opStar() const
	{
		(cast(RefCounted*)&this).defaultInit();
		checkInvariants();
		static if (is(TR == T*)) return *OBJ;
		else return OBJ;
	}
	
	@property ref T opStar() {
		defaultInit();
		checkInvariants();
		static if (is(TR == T*)) return *OBJ;
		else return OBJ;
	}
	
	alias opStar this;
	
	auto opBinaryRight(string op, Key)(Key key)
	inout if (op == "in" && __traits(hasMember, typeof(OBJ), "opBinaryRight")) {
		defaultInit();
		return opStar().opBinaryRight!("in")(key);
	}
	
	bool opCast(U : bool)() const {
		return OBJ !is null;
	}
	
	bool opEquals(U)(auto ref U other) const
	{
		defaultInit();
		static if (__traits(compiles, (cast(TR)OBJ).opEquals(cast(T) other.OBJ)))
			return opStar().opEquals(cast(T) other.OBJ);
		else
			return opStar().opEquals(other);
	}
	
	int opCmp(U)(auto ref U other) const
	{
		defaultInit();
		return opStar().opCmp(other);
	}
	
	int opApply(U...)(U args)
		if (__traits(hasMember, typeof(OBJ), "opApply"))
	{
		defaultInit();
		return opStar().opApply(args);
	}
	
	int opApply(U...)(U args) const
		if (__traits(hasMember, typeof(OBJ), "opApply"))
	{
		defaultInit();
		return opStar().opApply(args);
	}
	
	void opSliceAssign(U...)(U args)
		if (__traits(hasMember, typeof(OBJ), "opSliceAssign"))
	{
		defaultInit();
		opStar().opSliceAssign(args);
	}

	
	auto opSlice(U...)(U args) const
		if (__traits(hasMember, typeof(OBJ), "opSlice"))
	{
		defaultInit();
		static if (is(U == void))
			return opStar().opSlice();
		else
			return opStar().opSlice(args);
		
	}

	static if (__traits(hasMember, typeof(OBJ), "opDollar"))
	size_t opDollar() const
	{
		return opStar().opDollar();
	}
	
	void opOpAssign(string op, U...)(auto ref U args)
		if (__traits(compiles, opStar().opOpAssign!op(args)))
	{
		defaultInit();
		opStar().opOpAssign!op(args);
	}
	
	auto opBinary(string op, U...)(auto ref U args)
		if (__traits(compiles, opStar().opBinary!op(args)))
	{
		defaultInit();
		return opStar().opBinary!op(args);
	}
	
	void opIndexAssign(U, V)(auto const ref U arg1, auto const ref V arg2)
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
		bool opBinaryRight(string op, U)(auto ref U e) const if (op == "in") 
	{
		defaultInit();
		return opStar().opBinaryRight!("in")(e);
	}
}