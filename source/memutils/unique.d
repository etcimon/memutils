/**
  	Taken from Phobos, tweaked for convenience

	Copyright: Copyright the respective authors, 2008-
	License:   $(WEB boost.org/LICENSE_1_0.txt, Boost License 1.0).
		Authors:   $(WEB erdani.org, Andrei Alexandrescu),
		$(WEB bartoszmilewski.wordpress.com, Bartosz Milewski),
		Don Clugston,
		Shin Fujishiro,
		Kenji Hara
*/

module memutils.unique;

import memutils.allocators;
import memutils.constants;
import memutils.utils;

// TODO: Move release() into Embed!, and add a releaseCheck() for refCounted (cannot release > 1 reference) 
struct Unique(T, ALLOC = void)
{
	/** Represents a reference to $(D T). Resolves to $(D T*) if $(D T) is a value type. */
	alias TR = RefTypeOf!T;
	
public:
	/**
    Constructor that takes an rvalue.
    It will ensure uniqueness, as long as the rvalue
    isn't just a view on an lvalue (e.g., a cast).
    Typical usage:
    ----
    Unique!Foo f = new Foo;
    ----
    */
	this(inout TR p)
	{
		debug(Unique) logTrace("Unique constructor with rvalue");
		_p = cast(TR)p;
	}
	/**
    Constructor that takes an lvalue. It nulls its source.
    The nulling will ensure uniqueness as long as there
    are no previous aliases to the source.
    */
	this(ref TR p)
	{
		_p = p;
		debug(Unique) logTrace("Unique constructor nulling source");
		p = null;
		assert(p is null);
	}
	
	/**
    Constructor that takes a $(D Unique) of a type that is convertible to our type.

    Typically used to transfer a $(D Unique) rvalue of derived type to
    a $(D Unique) of base type.
    Example:
    ---
    class C : Object {}

    Unique!C uc = new C;
    Unique!Object uo = uc.release;
    ---
    */
	this(U)(Unique!U u)
		if (is(u.TR:TR))
	{
		debug(Unique) logTrace("Unique constructor converting from ", U.stringof);
		_p = u._p;
		u._p = null;
	}
	
	void free()
	{
		TR p = null;
		opAssign(p);
	}
	
	void opAssign()(auto ref TR p)
	{
		if (_p) destroy(this);
		_p = p;
		p = null;
		assert(p is null);
	}
	/*
    void opAssign(U)(in Unique!U p)
    {
        debug(Unique) logTrace("Unique opAssign converting from ", U.stringof);
        // first delete any resource we own
        destroy(this);
        _p = cast(TR)u._p;
        cast(TR)u._p = null;
    }*/
	
	/// Transfer ownership from a $(D Unique) of a type that is convertible to our type.
	void opAssign(U)(Unique!U u)
		if (is(u.TR:TR))
	{
		debug(Unique) logTrace("Unique opAssign converting from ", U.stringof);
		// first delete any resource we own
		if (_p) destroy(this);
		_p = u._p;
		u._p = null;
	}
	
	~this()
	{
		//logTrace("Unique destructor of ", T.stringof, " : ", cast(void*)_p);
		static if (ALLOC.stringof != "void") {
			if (_p !is null)
				ObjectAllocator!(T, ALLOC).free(_p);
		}
		else {
			if (_p !is null)
				delete _p;
		}
		_p = null;
	}
	/** Returns whether the resource exists. */
	@property bool isEmpty() const
	{
		return _p is null;
	}
	
	/** Transfer ownership to a $(D Unique) rvalue. Nullifies the current contents. */
	Unique release()
	{
		debug(Unique) logTrace("Release");
		auto u = Unique(_p);
		assert(_p is null);
		debug(Unique) logTrace("return from Release");
		return u;
	}
	
	void drop()
	{
		_p = null;
	}
	
	/** Forwards member access to contents. */
	TR opDot() { return _p; }
	const(TR) opDot() const { return _p; }
	
	TR opUnary(string op)() if (op == "*") { return _p; }
	const(TR) opUnary(string op)() const if (op == "*") { return _p; }
	
	TR get() { return _p; }
	
	bool opCast(T : bool)() const {
		return !isEmpty;
	}
	
	
	/**
    Postblit operator is undefined to prevent the cloning of $(D Unique) objects.
    */
	@disable this(this);
	
private:
	TR _p;
}
