module memutils.utils;

import memutils.allocators;
import memutils.constants;
import memutils.vector : Array;
import memutils.helpers : UnConst, memset, memcpy;

import std.traits : hasMember, isPointer, hasIndirections, hasElaborateDestructor, isArray, ReturnType;

struct ThreadMem {
	nothrow:
	@trusted:
	mixin ConvenienceAllocators!(LocklessFreeList, ThreadMem);
}

// Reserved for containers
struct Malloc {
	enum ident = Mallocator;
}

// overloaded for AppMem, otherwise uses ThreadMem
@trusted extern(C) nothrow {
    void[] FL_allocate(size_t n);
	void[] FL_reallocate(void[] mem, size_t n);
	void FL_deallocate(void[] mem);
}
/*
template PoolAllocator(T)
{
nothrow:
	enum ElemSize = AllocSize!T;
	Pool m_allocator;

	this(Pool allocator) {
		m_allocator = allocator;
	}


	alias TR = RefTypeOf!T;

	TR alloc(ARGS...)(auto ref ARGS args)
	{
		auto mem = m_allocator.alloc(ElemSize);
		TR omem = cast(TR)mem;
		
		logTrace("PoolObjectAllocator.alloc initialize");
		*omem = T(args);
		return omem;

	}

	void free(TR obj)
	{

		TR objc = obj;
		import memutils.helpers : destructRecurse;
		static if (is(TR == T*) && hasElaborateDestructor!T) {
			logTrace("ObjectAllocator.free Pointer destr ", T.stringof);
			destructRecurse(*objc);
		} 
		else static if (hasElaborateDestructor!TR) {
			logTrace("ObjectAllocator.free other destr ", T.stringof);
			destructRecurse(objc);
		} 

		m_allocator.free((cast(void*)obj)[0 .. ElemSize]);

	}
}
*/

nothrow:


struct ObjectAllocator(T, ALLOC = ThreadMem)
{
nothrow:
	enum ElemSize = AllocSize!T;

	static if (ALLOC.stringof == "PoolStack") {
		ReturnType!(ALLOC.top) function() m_getAlloc = &ALLOC.top;
	} else static if (!hasMember!(ALLOC, "ident") && ALLOC.stringof != "void") {
		ALLOC* m_allocator;
		this(ALLOC* base) {
			m_allocator = base;
		}
	}
	enum NOGC = true;

	alias TR = RefTypeOf!T;

	TR alloc(ARGS...)(auto ref ARGS args)
	{
		static if (ALLOC.stringof == "PoolStack") {
			auto mem = m_getAlloc().alloc(ElemSize);
		}
		else static if (ALLOC.stringof == "void") {
			auto mem = FL_allocate(ElemSize);
		} else {
			static if (hasMember!(ALLOC, "ident"))
				auto allocator_ = getAllocator!(ALLOC.ident)(false);
			else
				auto allocator_ = m_allocator;
			auto mem = allocator_.alloc(ElemSize);
		}
		TR omem = cast(TR)mem;
		
		logTrace("ObjectAllocator.alloc initialize");
		*omem = T(args);
		return omem;

	}

	void free(TR obj)
	{


		TR objc = obj;
		import memutils.helpers : destructRecurse;
		static if (is(TR == T*) && hasElaborateDestructor!T) {
			logTrace("ObjectAllocator.free Pointer destr ", T.stringof);
			destructRecurse(*objc);
		} 
		else static if (hasElaborateDestructor!TR) {
			logTrace("ObjectAllocator.free other destr ", T.stringof);
			destructRecurse(objc);
		} 

		static if (ALLOC.stringof == "PoolStack") {
			m_getAlloc().free((cast(void*)obj)[0 .. ElemSize]);
		}
		else static if (ALLOC.stringof == "void") {
			FL_deallocate((cast(void*)obj)[0 .. ElemSize]);
		}
		else {
			static if (hasMember!(ALLOC, "ident"))
				auto a = getAllocator!(ALLOC.ident)(true);
			else
				auto a = m_allocator;
			a.free((cast(void*)obj)[0 .. ElemSize]);
		}

	}
}

/// Allocates an array without touching the memory.
T[] allocArray(T, ALLOC = ThreadMem)(size_t n, ALLOC* base = null)
{
	static enum TSize = T.sizeof;
	static if (ALLOC.stringof == "void") {
		auto mem = FL_allocate(TSize * n);
		return (cast(T*)mem.ptr)[0 .. n];
	} else {
		static if (ALLOC.stringof == "PoolStack")
			auto allocator = ALLOC.top;
		else static if (hasMember!(ALLOC, "ident")) 
			auto allocator = getAllocator!(ALLOC.ident)(false);
		else static if (ALLOC.stringof != "void")
			auto allocator = base;
		auto mem = allocator.alloc(TSize * n);
		// logTrace("alloc ", T.stringof, ": ", mem.ptr);
		auto ret = (cast(T*)mem.ptr)[0 .. n];
		// logTrace("alloc ", ALLOC.stringof, ": ", mem.ptr, ":", mem.length);

		// don't touch the memory - all practical uses of this function will handle initialization.
		return ret;
	}
}

T[] reallocArray(T, ALLOC = ThreadMem)(T[] array, size_t n, ALLOC* base = null) {
	static enum TSize = T.sizeof;
	assert(n > array.length, "Cannot reallocate to smaller sizes");
	static if (ALLOC.stringof == "void") {

		auto mem = FL_reallocate((cast(void*)array.ptr)[0 .. array.length * TSize], TSize * n);
		return (cast(T*)mem.ptr)[0 .. n];
	}
	else {

		static if (ALLOC.stringof == "PoolStack")
			auto allocator = ALLOC.top;
		else static if (hasMember!(ALLOC, "ident")) 
			auto allocator = getAllocator!(ALLOC.ident)(false);
		else
			auto allocator = base;

		// logTrace("realloc before ", ALLOC.stringof, ": ", cast(void*)array.ptr, ":", array.length);

		//logTrace("realloc fre ", T.stringof, ": ", array.ptr);
		auto mem = allocator.realloc((cast(void*)array.ptr)[0 .. array.length * TSize], TSize * n);
		//logTrace("realloc ret ", T.stringof, ": ", mem.ptr);
		auto ret = (cast(T*)mem.ptr)[0 .. n];
		// logTrace("realloc after ", ALLOC.stringof, ": ", mem.ptr, ":", mem.length);

			
		return ret;
	}
}

nothrow void freeArray(T, ALLOC = ThreadMem)(auto ref T[] array, size_t max_destroy = size_t.max, size_t offset = 0, ALLOC* base = null)
{
	static enum TSize = T.sizeof;
	
	static if (hasElaborateDestructor!T) { // calls destructors, but not for indirections...
		size_t i;
		foreach (ref e; array) {
			if (i < offset) { i++; continue; }
			if (i + offset == max_destroy) break;
			import memutils.helpers : destructRecurse;
			destructRecurse(e);
			i++;
		}
	}

	static if (ALLOC.stringof == "void") {
		FL_deallocate((cast(void*)array.ptr)[0 .. array.length * TSize]);
	} 
	else {
		static if (ALLOC.stringof == "PoolStack")
			auto allocator = ALLOC.top;
		else static if (hasMember!(ALLOC, "ident")) {
			auto allocator = getAllocator!(ALLOC.ident)(true);
			if (allocator == typeof(allocator).init) return;
		} else {
			auto allocator = base;
		}

		allocator.free((cast(void*)array.ptr)[0 .. array.length * TSize]);
	}

	array = null;

}

mixin template ConvenienceAllocators(alias ALLOC, alias THIS) {
	package enum ident = ALLOC;
nothrow:
static:
	// objects
	auto alloc(T, ARGS...)(auto ref ARGS args) 
		if (!isArray!T)
	{
		return ObjectAllocator!(T, THIS)().alloc(args);
	}
	
	void free(T)(auto ref T* obj)
		if (!isArray!T && !is(T : Object))
	{
		scope(exit) obj = null;
		ObjectAllocator!(T, THIS)().free(obj);
	}
	
	void free(T)(auto ref T obj)
		if (!isArray!T && is(T  : Object))
	{
		scope(exit) obj = null;
		ObjectAllocator!(T, THIS)().free(obj);
	}

	/// arrays
	auto alloc(T)(size_t n)
		if (isArray!T)
	{
		static if (is(T == void[])) {
			return getAllocator!ALLOC().alloc(n);
		} else {
			alias ElType = UnConst!(typeof(T.init[0]));
			return allocArray!(ElType, THIS)(n);
		}
	}

	auto copy(T)(auto ref T arr)
		if (isArray!T)
	{
		alias ElType = UnConst!(typeof(arr[0]));
		enum ElSize = ElType.sizeof;
		auto arr_copy = allocArray!(ElType, THIS)(arr.length);
		memcpy(arr_copy.ptr, arr.ptr, arr.length * ElSize);

		return cast(T)arr_copy;
	}

	auto realloc(T)(auto ref T arr, size_t n, bool zeroise_mem = true)
		if (isArray!T)
	{
		static if (is(T == void[])) {
			return getAllocator!ALLOC().realloc(arr, n, zeroise_mem);
		} else {
			alias ElType = UnConst!(typeof(arr[0]));
			scope(exit) arr = null;
			auto arr_copy = reallocArray!(typeof(arr[0]), THIS)(arr, n);
			return cast(T) arr_copy;
		}
	}
	
	void free(T)(auto ref T arr, bool zeroise_mem = false)
		if (isArray!T)
	{
		static if (is(T == void[])) {
			return getAllocator!ALLOC().free(arr, zeroise_mem);
		} else {
			alias ElType = typeof(arr[0]);
			scope(exit) arr = null;
			freeArray!(ElType, THIS)(arr);
		}
	}

}
