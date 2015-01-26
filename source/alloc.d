module memutils.alloc;

import core.thread : Fiber;	
import std.traits : isPointer, hasIndirections, hasElaborateDestructor;
import core.memory : GC;
import std.conv : emplace;
import memutils.allocators;
public import memutils.constants;

Allocator getFiberPool(Fiber f) {
	if (!f)
		return getAllocator!NativeGC();
	if (auto ptr = (&f in g_fiberAlloc)) {
		return *ptr;
	}
	else {
		auto ret = new FiberPool();
		g_fiberAlloc[&f] = ret;
		return ret;
	}
}

void destroyFiberPool(Fiber f) {
	if (auto ptr = (&f in g_fiberAlloc)) {
		g_fiberAlloc.remove(&f);
		ptr.freeAll();
		delete *ptr;
	}
}


package:

template FreeListObjectAlloc(T, int ALLOC)
{
	enum ElemSize = AllocSize!T;
	
	static if (__traits(hasMember, T, "NOGC")) enum NOGC = T.NOGC;
	else enum NOGC = false;

	alias TR = RefTypeOf!T;
	
	TR alloc(ARGS...)(ARGS args)
	{
		//logInfo("alloc %s/%d", T.stringof, ElemSize);
		auto mem = getAllocator!ALLOC().alloc(ElemSize);
		static if( hasIndirections!T && !NOGC ) GC.addRange(mem.ptr, ElemSize);
		return emplace!T(mem, args);
	}
	
	void free(TR obj)
	{
		auto objc = obj;
		static if (is(TR == T*)) .destroy(*objc);
		else .destroy(objc);

		static if( hasIndirections!T && !NOGC ) GC.removeRange(cast(void*)obj);
		getAllocator!ALLOC().free((cast(void*)obj)[0 .. ElemSize]);
	}
}


auto allocObject(T, int ALLOC = LocklessAllocator, bool MANAGED = true, ARGS...)(ARGS args)
{
	mixin(translateAllocator());
	auto allocator = thisAllocator();
	auto mem = allocator.alloc(AllocSize!T);
	static if( MANAGED ){
		static if( hasIndirections!T )
			GC.addRange(mem.ptr, mem.length);
		return emplace!T(mem, args);
	}
	else static if( is(T == class) ) return cast(T)mem.ptr;
	else return cast(T*)mem.ptr;
}

T[] allocArray(T, int ALLOC = LocklessAllocator, bool MANAGED = true)(size_t n)
{
	mixin(translateAllocator());
	auto allocator = thisAllocator();
	auto mem = allocator.alloc(T.sizeof * n);
	auto ret = cast(T[])mem;
	static if ( MANAGED )
	{
		static if (__traits(hasMember, T, "NOGC")) enum NOGC = T.NOGC;
		else enum NOGC = false;
		
		static if( hasIndirections!T && !NOGC )
			GC.addRange(mem.ptr, mem.length);
		// TODO: use memset for class, pointers and scalars
		foreach (ref el; ret) { // calls constructors
			emplace!T(cast(void[])((&el)[0 .. 1]));
		}
	}
	return ret;
}

void freeArray(T, int ALLOC = LocklessAllocator, bool MANAGED = true, bool DESTROY = true)(ref T[] array, size_t max_destroy = size_t.max)
{
	mixin(translateAllocator());
	auto allocator = thisAllocator();
	
	static if (__traits(hasMember, T, "NOGC")) enum NOGC = T.NOGC;
	else enum NOGC = false;
	
	static if (MANAGED && hasIndirections!T && !NOGC) {
		GC.removeRange(array.ptr);
	}
	static if (DESTROY && hasElaborateDestructor!T) { // calls destructors
		size_t i;
		foreach (ref e; array) {
			static if (is(T == struct) && isPointer!T) .destroy(*e);
			else .destroy(e);
			if (++i == max_destroy) break;
		}
	}
	allocator.free(cast(void[])array);
	array = null;
}