/// Compatible destroy internals
module memutils._destroy;

private {
	extern (C) Object _d_newclass(const TypeInfo_Class ci);
	extern (C) void rt_finalize(void *data, bool det=true);
}
void _destroy(T)(T obj) if (is(T == class))
{
	rt_finalize(cast(void*)obj);
}

void _destroy(T)(T obj) if (is(T == interface))
{
	_destroy(cast(Object)obj);
}


void _destroy(T)(ref T obj) if (is(T == struct))
{
	_destructRecurse(obj);
	() @trusted {
		auto buf = (cast(ubyte*) &obj)[0 .. T.sizeof];
		auto init = cast(ubyte[])typeid(T).init();
		if (init.ptr is null) // null ptr means initialize to 0s
			buf[] = 0;
		else
			buf[] = init[];
	} ();
}

void _destroy(T : U[n], U, size_t n)(ref T obj) if (!is(T == struct))
{
	obj[] = U.init;
}

void _destroy(T)(ref T obj)
	if (!is(T == struct) && !is(T == interface) && !is(T == class) && !_isStaticArray!T)
{
	obj = T.init;
}

template _isStaticArray(T : U[N], U, size_t N)
{
	enum bool _isStaticArray = true;
}

template _isStaticArray(T)
{
	enum bool _isStaticArray = false;
}


private void _destructRecurse(S)(ref S s)
	if (is(S == struct))
{
	import core.internal.traits : hasElaborateDestructor;
	
	static if (__traits(hasMember, S, "__dtor"))
		s.__dtor();
	
	foreach_reverse (ref field; s.tupleof)
	{
		static if (hasElaborateDestructor!(typeof(field)))
			_destructRecurse(field);
	}
}

private void _destructRecurse(E, size_t n)(ref E[n] arr)
{
	import core.internal.traits : hasElaborateDestructor;
	
	static if (hasElaborateDestructor!E)
	{
		foreach_reverse (ref elem; arr)
			_destructRecurse(elem);
	}
}
