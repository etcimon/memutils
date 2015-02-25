module memutils.utils;

import core.thread : Fiber;	
import std.traits : isPointer, hasIndirections, hasElaborateDestructor;
import std.conv : emplace;
import std.c.string : memset, memcpy;
import memutils.allocators;
import std.algorithm : startsWith;
import memutils.constants;
import memutils.vector : Array;
import std.traits : isArray;

struct AppMem {
	mixin ConvenienceAllocators!(NativeGC, typeof(this));
}

struct ThreadMem {
	mixin ConvenienceAllocators!(LocklessFreeList, typeof(this));
}

struct SecureMem {
	mixin ConvenienceAllocators!(CryptoSafe, typeof(this));
}

package struct Malloc {
	enum ident = Mallocator;
}

package:

template ObjectAllocator(T, ALLOC)
{
	import std.traits : ReturnType;
	import core.memory : GC;
	enum ElemSize = AllocSize!T;

	static if (ALLOC.stringof == "PoolStack") {
		ReturnType!(ALLOC.front) function() m_getAlloc = &ALLOC.front;
	}
	static if (__traits(hasMember, T, "NOGC")) enum NOGC = T.NOGC;
	else enum NOGC = false;

	alias TR = RefTypeOf!T;


	TR alloc(ARGS...)(auto ref ARGS args)
	{
		static if (ALLOC.stringof != "PoolStack")
			auto mem = getAllocator!(ALLOC.ident)().alloc(ElemSize);
		else
			auto mem = m_getAlloc().alloc(ElemSize);
		static if ( ALLOC.stringof != "AppMem" && hasIndirections!T && !NOGC) GC.addRange(mem.ptr, ElemSize, typeid(T));
		return emplace!T(mem, args);

	}

	void free(TR obj)
	{
		auto objc = obj;
		static if (is(TR == T*)) .destroy(*objc);
		else .destroy(objc);

		static if( ALLOC.stringof != "AppMem" && hasIndirections!T && !NOGC) GC.removeRange(cast(void*)obj);

		static if (ALLOC.stringof != "PoolStack")
			getAllocator!(ALLOC.ident)().free((cast(void*)obj)[0 .. ElemSize]);
		else
			m_getAlloc().free((cast(void*)obj)[0 .. ElemSize]);

	}
}

/// Allocates an array without touching the memory.
T[] allocArray(T, ALLOC = ThreadMem)(size_t n)
{
	import core.memory : GC;
	mixin(translateAllocator());
	auto allocator = thisAllocator();

	auto mem = allocator.alloc(T.sizeof * n);
	// logTrace("alloc ", T.stringof, ": ", mem.ptr);
	auto ret = cast(T[])mem;
	// logTrace("alloc ", ALLOC.stringof, ": ", mem.ptr, ":", mem.length);
	static if (__traits(hasMember, T, "NOGC")) enum NOGC = T.NOGC;
	else enum NOGC = false;
	
	static if( ALLOC.stringof != "AppMem" && hasIndirections!T && !NOGC) {
		// TODO: Do I need to add range for GC.malloc too?
		GC.addRange(mem.ptr, mem.length, typeid(T));
	}

	// don't touch the memory - all practical uses of this function will handle initialization.
	return ret;
}

T[] reallocArray(T, ALLOC = ThreadMem)(T[] array, size_t n) {
	import core.memory : GC;
	assert(n > array.length, "Cannot reallocate to smaller sizes");
	mixin(translateAllocator());
	auto allocator = thisAllocator();
	// logTrace("realloc before ", ALLOC.stringof, ": ", cast(void*)array.ptr, ":", array.length);

	//logTrace("realloc fre ", T.stringof, ": ", array.ptr);
	auto mem = allocator.realloc(cast(void[]) array, T.sizeof * n);
	//logTrace("realloc ret ", T.stringof, ": ", mem.ptr);
	auto ret = cast(T[])mem;
	// logTrace("realloc after ", ALLOC.stringof, ": ", mem.ptr, ":", mem.length);
	
	static if (__traits(hasMember, T, "NOGC")) enum NOGC = T.NOGC;
	else enum NOGC = false;
	
	static if (hasIndirections!T && !NOGC) {
		GC.removeRange(array.ptr);
		GC.addRange(mem.ptr, mem.length, typeid(T));
		// Zero out unused capacity to prevent gc from seeing false pointers
		memset(mem.ptr + (array.length * T.sizeof), 0, (n - array.length) * T.sizeof);
	}
	
	return ret;
}

void freeArray(T, ALLOC = ThreadMem)(auto ref T[] array, size_t max_destroy = size_t.max)
{
	import core.memory : GC;
	mixin(translateAllocator());
	auto allocator = thisAllocator();

	// logTrace("free ", ALLOC.stringof, ": ", cast(void*)array.ptr, ":", array.length);
	static if (__traits(hasMember, T, "NOGC")) enum NOGC = T.NOGC;
	else enum NOGC = false;
	
	static if (ALLOC.stringof != "AppMem" && hasIndirections!T && !NOGC) {
		GC.removeRange(array.ptr);
	}

	static if (hasElaborateDestructor!T) { // calls destructors, but not for indirections...
		size_t i;
		foreach (ref e; array) {
			if (i == max_destroy) break;
			static if (is(T == struct) && !isPointer!T) .destroy(e);
			i++;
		}
	}
	allocator.free(cast(void[])array);
	array = null;
}

mixin template ConvenienceAllocators(alias ALLOC, alias THIS) {
	package enum ident = ALLOC;
static:
	// objects
	auto alloc(T, ARGS...)(auto ref ARGS args) 
		if (!isArray!T)
	{
		return ObjectAllocator!(T, THIS).alloc(args);
	}
	
	void free(T)(ref T* obj)
		if (!isArray!T && !is(T : Object))
	{
		scope(exit) obj = null;
		ObjectAllocator!(T, THIS).free(obj);
	}
	
	void free(T)(ref T obj)
		if (!isArray!T && is(T  : Object))
	{
		scope(exit) obj = null;
		ObjectAllocator!(T, THIS).free(obj);
	}

	/// arrays
	auto alloc(T)(size_t n)
		if (isArray!T)
	{
		import std.range : ElementType;
		return allocArray!(ElementType!T, THIS)(n);
	}
	
	auto realloc(T)(ref T arr, size_t n)
		if (isArray!T)
	{
		import std.range : ElementType;
		scope(exit) arr = null;
		return reallocArray!(ElementType!T, THIS)(arr, n);
	}
	
	void free(T)(ref T arr)
		if (isArray!T)
	{
		import std.range : ElementType;
		scope(exit) arr = null;
		freeArray!(ElementType!T, THIS)(arr);
	}

}

string translateAllocator() { /// requires (ALLOC) template parameter
	return `
	static assert(ALLOC.ident, "The 'ALLOC' template parameter is not in scope.");
	static if (ALLOC.stringof != "PoolStack") {
		ReturnType!(getAllocator!(ALLOC.ident)) thisAllocator() {
			return getAllocator!(ALLOC.ident)();
		}
	}
	else {
		ReturnType!(ALLOC.front) function() thisAllocator = &ALLOC.front;
	}
	`;
}