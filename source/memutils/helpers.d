module memutils.helpers;
public:
	import std.traits : isSomeFunction;
	import std.range : ElementType;
nothrow:
@trusted:
template UnConst(T) {
	static if (is(T U == const(U))) {
		alias UnConst = U;
	} else static if (is(T V == immutable(V))) {
		alias UnConst = V;
	} else alias UnConst = T;
}


// compiler frontend lowers dynamic array deconstruction to this
void __ArrayDtor(T)(scope T[] a)
{
    foreach_reverse (ref T e; a)
        e.__xdtor();
}

void destructRecurse(E, size_t n)(ref E[n] arr)
{
    static if (hasElaborateDestructor!E)
    {
        foreach_reverse (ref elem; arr)
            destructRecurse(elem);
    }
}

void destructRecurse(S)(ref S s)
    if (is(S == struct))
{
    static if (__traits(hasMember, S, "__xdtor") &&
            // Bugzilla 14746: Check that it's the exact member of S.
            __traits(isSame, S, __traits(parent, s.__xdtor)))
        s.__xdtor();
}

/// TODO: Imitate Unique! for all objects (assume dtor) with release()
/// TODO: implement @override on underlying type T, and check for shadowed members.
mixin template Embed(alias OBJ, alias OWNED)
{
	nothrow:
	alias TR = typeof(OBJ);
	static if (is(typeof(*OBJ) == struct))
			alias T = typeof(*OBJ);
	else
		alias T = TR;

	static if (!isSomeFunction!OBJ)
	@property ref const(T) fallthrough() const
	{
		/*static if (__traits(hasMember, typeof(this), "defaultInit")) {
			(cast(typeof(this)*)&this).defaultInit();
			checkInvariants();
		}*/
		static if (is(TR == T*)) return *OBJ;
		else return OBJ;
	}

	@property ref T fallthrough()
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
		return this.fallthrough;
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

/// ditto
T min(T, U)(T a, U b)
if (is(T == U) && is(typeof(a < b)))
{
   /* Handle the common case without all the template expansions
    * of the general case
    */
    return b < a ? b : a;
}

/// ditto
T max(T, U)(T a, U b)
if (is(T == U) && is(typeof(a < b)))
{
   /* Handle the common case without all the template expansions
    * of the general case
    */
    return a < b ? b : a;
}

T* addressOf(T)(ref T val) { return &val; }

void fill(Range, Value)(auto ref Range range, auto ref Value value)
{
    alias T = ElementType!Range;

    static if (is(typeof(range[] = value)))
    {
        range[] = value;
    }
    else static if (is(typeof(range[] = T(value))))
    {
        range[] = T(value);
    }
    else
    {
        for ( ; !range.empty; range.popFront() )
        {
            range.front = value;
        }
    }
}

void initializeAll(Range)(Range range)
if (!is(Range == char[]) && !is(Range == wchar[]))
{
    import std.traits : hasElaborateAssign, isDynamicArray;

    alias T = ElementType!Range;
    static if (hasElaborateAssign!T)
    {
        //Elaborate opAssign. Must go the memcpy road.
        //We avoid calling emplace here, because our goal is to initialize to
        //the static state of T.init,
        //So we want to avoid any un-necassarilly CC'ing of T.init
        static if (!__traits(isZeroInit, T))
        {
            auto p = T();
            for ( ; !range.empty ; range.popFront() )
            {
                static if (__traits(isStaticArray, T))
                {
                    // static array initializer only contains initialization
                    // for one element of the static array.
                    auto elemp = cast(void *) addressOf(range.front);
                    auto endp = elemp + T.sizeof;
                    while (elemp < endp)
                    {
                        memcpy(elemp, &p, T.sizeof);
                        elemp += T.sizeof;
                    }
                }
                else
                {
                    memcpy(addressOf(range.front), &p, T.sizeof);
                }
            }
        }
        else
            static if (isDynamicArray!Range)
                memset(range.ptr, 0, range.length * T.sizeof);
            else
                for ( ; !range.empty ; range.popFront() )
                    memset(addressOf(range.front), 0, T.sizeof);
    }
    else
        fill(range, T.init);
}
/// ditto
void initializeAll(Range)(Range range)
if (is(Range == char[]) || is(Range == wchar[]))
{
	import std.range : ElementEncodingType;
    alias T = ElementEncodingType!Range;
    range[] = T.init;
}
extern(C):
void*   malloc(size_t size);
///
void*   calloc(size_t nmemb, size_t size);
///
void*   realloc2(void* ptr, size_t oldsize, size_t size);
///
void    free2(void* ptr, size_t size);
///
int   memcmp(scope const void* s1, scope const void* s2, size_t n) pure;
///
void* memcpy(return void* s1, scope const void* s2, size_t n) pure;
version (Windows)
{
    ///
    int memicmp(scope const char* s1, scope const char* s2, size_t n);
}
///
void* memmove(return void* s1, scope const void* s2, size_t n) pure;
///
void* memset(return void* s, int c, size_t n) pure;
