module memutils.borrow;
version(none):

/***
 *  borrow() is meant to replace `new` and `dup` with a do-it-all function that chooses
 *	ThisFiber or the GC for copying data in a collected fiber pool/gc.
 *		  
 *	This is useful for functions that return pointers/array/objects with 
 *  indirections or not, that would like to save cycles using Fiber allocator if available,
 *	but sparing the additional burden of one or more allocated `ref` parameter(s).	
 *
 *	The destructors are guaranteed to be called *eventually*. If in a fiber, the destructors
 *  are called immediately when the fiber is destroyed. As for the GC, it happens when eventual 
 *  allocations happen to trigger a collection, or if GC.collect() is called.
 */
alias BorrowType = ubyte;
enum : ubyte {
	COPY = 0,
	MOVE = 1,
	DEEP_COPY = 2,
	DEEP_MOVE = 3
}


// TODO: 	Move: use .move() if available, or make a copy of each item recursively.
///			copy: use opAssign if available, or fall back on .dup for each item recursively
///			deep_move: call borrow(MOVE) on each item recursively
///			deep_copy: use .borrow(DEEP_COPY) if available, fall back on borrow(COPY)

import std.traits : isImplicitlyConvertible;
T borrow(T)(in T val = null, in BorrowType btype = COPY) 
	if (is(T == class) || is(T == interface) || __traits(isAbstractClass, T))
{
	T ret;
	
	if (Fiber f = Fiber.getThis()) {
		// copy to fiber storage
		ret = ThisFiber.alloc!T();
		
		// Add destructor to fiber pool
		static if (hasElaborateDestructor!T || __traits(hasMember, T, "__dtor") ) 
			ThisFiber.addDtor(&ret.__dtor);
		
		ThisFiber.ignore(ret); // avoid debugger failures
		
		if (val)
			memcpy(&ret, &val, __traits(classInstanceSize, T));
	}
	else {
		static if (is(T == interface) || __traits(isAbstractClass, T)) {
			assert(val, "Cannot create an instance of an interface");
			ret = val.dup();
		}
		else {
			if (val) ret = val.dup();
			else ret = new T();
		}
	}
	
	return ret;
}

T* borrow(T)(in T val = T.init, in BorrowType btype = COPY)
	if (is(T == struct))
{
	T* ret;
	return borrow(ret);
}

T* borrow(T)(in T* val = null, in BorrowType btype = COPY) 
	if (is(T == struct))
{
	T* ret;
	
	if (Fiber f = Fiber.getThis()) {
		// copy to fiber storage
		ret = ThisFiber.alloc!T();
		
		// Add destructor to fiber pool
		static if (hasElaborateDestructor!T || __traits(hasMember, T, "__dtor") ) 
			ThisFiber.addDtor(&ret.__dtor);
		ThisFiber.ignore(ret); // avoid debugger failures
		
	}
	else {
		ret = new T();
	}
	
	if (val) { // todo: Borrow recursively on deep_copy
		static if (isImplicitelyConvertible!(T, T))
			*ret = *val;
		else
			memcpy(ret, val, T.sizeof);
	}
	
	return ret;
}

U borrow(U)(size_t length, in BorrowType btype = COPY)
	if (isArray!U)
{
	import std.range : ElementType;
	alias T = ElementType!U;
	T[] ret;
	
	if (Fiber f = Fiber.getThis()) {
		ret = ThisFiber.alloc!(T[])(length);
		registerFiberArray(ret);
		
	}
	else
		ret = new T[](length);
	
	return ret;
}

U borrow(U)(in U val, in BorrowType btype = COPY)
	if (isArray!U)
{
	import std.range : ElementType;
	import std.traits : isImplicitlyConvertible;
	alias T = ElementType!U;
	T[] ret;
	
	if (Fiber.getThis()) {
		ret = ThisFiber.alloc!(T[])(val.length);
		registerFiberArray(ret);
	}
	else
		ret = new T[](val.length);
	
	
	// TODO: borrow recursively on deep_copy
	static if (isImplicitlyConvertible!(T, T))
		ret[] = val[];
	else {
		memcpy(ret.ptr, val.ptr, val.length * T.sizeof);
	}
	
	return ret;
}
