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

import memutils.helpers;


// TODO: Move release() into Embed!, and add a releaseCheck() for refCounted (cannot release > 1 reference) 
struct Unique(T, ALLOC = ThreadMem)
{
nothrow:
@trusted:
	alias TR = RefTypeOf!T;
	private TR m_object;
	
	mixin Embed!(m_object, false);
	enum NOGC = true;
	enum isRefCounted = false;
	enum isUnique = true;

	enum ElemSize = AllocSize!T;
	
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
		opAssign(cast(TR)p);
	}
	/**
    Constructor that takes an lvalue. It nulls its source.
    The nulling will ensure uniqueness as long as there
    are no previous aliases to the source.
    */
	this(ref TR p)
	{
		opAssign(p);
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
		// logTrace("Unique constructor converting from ", U.stringof);
		opAssign(u.m_object);
		u.m_object = null;
	}
	
	void free()
	{
		TR p = null;
		opAssign(p);
	}
	
	void opAssign()(auto ref TR p)
	{
		if (m_object) destructRecurse(this);
		if (!p) return;
		//logTrace("Unique ctor of ", T.stringof, " : ", ptr.to!string);
		m_object = p;
		p = null;
	}
	/*
    void opAssign(U)(in Unique!U p)
    {
        debug(Unique) logTrace("Unique opAssign converting from ", U.stringof);
        // first delete any resource we own
        destroy(this);
        m_object = cast(TR)u.m_object;
        cast(TR)u.m_object = null;
    }*/
	
	/// Transfer ownership from a $(D Unique) of a type that is convertible to our type.
	void opAssign(U)(Unique!U u)
		if (is(u.TR:TR))
	{
		opAssign(u.m_object);
		u.m_object = null;
	}
	
	~this()
	{
		//logDebug("Unique destructor of ", T.stringof, " : ", ptr);


		static if (ALLOC.stringof != "void") {
			if (m_object) {
				//logTrace("ptr in ptree: ", ptr in ptree);


				ObjectAllocator!(T, ALLOC).free(m_object);

				//static if (HasDebugAllocations && DebugUnique)
				//	debug memset(ptr, 0, AllocSize!T);
			}
		}
	}
	/** Returns whether the resource exists. */
	@property bool isEmpty() const
	{
		return m_object is null;
	}
	
	/** Transfer ownership to a $(D Unique) rvalue. Nullifies the current contents. */
	TR release()
	{
		//logTrace("Release");
		if (!m_object) return null;
		auto ret = m_object;
        drop();
		return ret;
	}
	
	void drop()
	{
		//logTrace("Drop");
		if (!m_object) return;
		m_object = null;
	}

	TR opUnary(string op)() if (op == "*") { return m_object; }
	const(TR) opUnary(string op)() const if (op == "*") { return m_object; }
	
	TR get() { return m_object; }
	
	bool opCast(U : bool)() const {
		return !isEmpty;
	}
	
	U opCast(U)() const nothrow
		if (__traits(hasMember, U, "isUnique"))
	{
		if (!m_object) return Unique!(T, ALLOC)();
		return Unique!(U, ALLOC)(cast(U)this.m_object.release());
	}
	
	U opCast(U)() const nothrow
		if (!__traits(hasMember, U, "isUnique"))
	{
		if (!m_object) return cast(U)typeof(m_object).init;
		return cast(U)this.m_object;
	}

	/**
    Postblit operator is undefined to prevent the cloning of $(D Unique) objects.
    */
	@disable this(this);
	
private:

	@property void* ptr() const {
		return cast(void*)m_object;
	}

}

auto unique(T)(T obj) {
	return Unique!T(obj);
}