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
import memutils.rbtree;

	import memutils.helpers;
import std.conv : to;

static if (__VERSION__ >= 2071) {
	extern (C) bool gc_inFinalizer();
	enum HasGCCheck = true;
}
else version(GCCheck) {
	extern(C) bool gc_inFinalizer();
	enum HasGCCheck = true;
} else enum HasGCCheck = false;
enum DebugUnique = true;

// TODO: Move release() into Embed!, and add a releaseCheck() for refCounted (cannot release > 1 reference) 
struct Unique(T, ALLOC = void)
{
	alias TR = RefTypeOf!T;
	private TR m_object;
	
	mixin Embed!(m_object, false);
	static if (!is(ALLOC == AppMem)) enum NOGC = true;
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
		if (m_object) destroy(this);
		if (!p) return;
		//logTrace("Unique ctor of ", T.stringof, " : ", ptr.to!string);
		static if (HasDebugAllocations && DebugUnique) {
			mtx.lock(); scope(exit) mtx.unlock();
			ptree._defaultInitialize();
			if(cast(void*)p in ptree)
			{
                assert(false, "Already owned pointer: " ~ (cast(void*)p).to!string ~ " of type " ~ T.stringof);
			}
			ptree.insert(cast(void*)p);
		}
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
		import core.stdc.string : memset;


		static if (ALLOC.stringof != "void") {
			if (m_object) {
				//logTrace("ptr in ptree: ", ptr in ptree);

				static if (HasDebugAllocations && DebugUnique) {
					mtx.lock(); scope(exit) mtx.unlock();
					ptree._defaultInitialize();
					assert(ptr in ptree);
					ptree.remove(ptr);
				}

				ObjectAllocator!(T, ALLOC).free(m_object);

				//static if (HasDebugAllocations && DebugUnique)
				//	debug memset(ptr, 0, AllocSize!T);
			}
		}
		else {
			static if (HasGCCheck) if (!gc_inFinalizer()) {
				if (m_object) {
					//logTrace("ptr in ptree: ", ptr in ptree);

					static if (HasDebugAllocations && DebugUnique) {
						mtx.lock(); scope(exit) mtx.unlock();
						ptree._defaultInitialize();
						if (ptr !in ptree){ 
							logDebug("Unknown pointer: " ~ ptr.to!string ~ " of type " ~ T.stringof);
							assert(false);
						}
						ptree.remove(ptr);
					}

					static if (is(TR == T*)) .destroy(*m_object);
					else .destroy(m_object);
				}
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
		static if (HasDebugAllocations && DebugUnique) {
			mtx.lock(); scope(exit) mtx.unlock();
			ptree._defaultInitialize();
			assert(ptr in ptree);
			ptree.remove(ptr);
		}
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

	static if (HasDebugAllocations && DebugUnique) {
		import memutils.rbtree;
		__gshared RBTree!(void*, "a < b", true, Malloc) ptree;
		__gshared Mutex mtx;
		shared static this() { mtx = new Mutex; }
	}
}

auto unique(T)(T obj) {
	return Unique!T(obj);
}