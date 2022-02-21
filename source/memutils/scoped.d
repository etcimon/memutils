module memutils.scoped;

import memutils.constants;
import memutils.allocators;
import memutils.pool;
import memutils.utils;
import memutils.vector;
import memutils.refcounted;
import memutils.unique;
import memutils.hashmap;
import memutils.freelist;
import memutils.memory;
import memutils.helpers;
import std.traits : isArray, hasElaborateDestructor;

alias ScopedPool = ScopedPoolImpl;
@trusted:
nothrow:
struct ScopedPoolImpl {
nothrow:
	// TODO: Use a name for debugging?

	int id;
	/// Initializes a scoped pool with max_mem
	this(size_t max_mem) {
		PoolStack.push(max_mem);
		id = PoolStack.top.id;
	}

	this(ManagedPool pool) {
		PoolStack.push(pool);
	}

	~this() {
		if (id != PoolStack.top.id) return;
		PoolStack.pop();
	}

	/// Use only if ScopedPool is the highest on stack.
	void freeze() {
		assert(id == PoolStack.top.id);
		PoolStack.freeze(1);
	}

	void unfreeze() {
		PoolStack.unfreeze(1);
		assert(id == PoolStack.top.id);
	}
}
/*
T alloc(T, ARGS...)(auto ref ARGS args)
	if (is(T == class) || is(T == interface) || __traits(isAbstractClass, T))
{
	T ret;
	
	if (!PoolStack.empty) {
		ret = ObjectAllocator!(T, PoolStack).alloc(args);
		
		// Add destructor to pool
		logTrace("Trying to add __dtor for ", T.stringof);
		static if (hasElaborateDestructor!T || __traits(hasMember, T, "__dtor") ) {
			PoolStack.top().onDestroy(&ret.__dtor);
		}
	}
	
	return ret;
}
*/
T* alloc(T, ARGS...)(auto ref ARGS args)
{
	T* ret;
	
	if (!PoolStack.empty) {
		ret = ObjectAllocator!(T, PoolStack).alloc(args);
		
		// Add destructor to pool
		static if (hasElaborateDestructor!T || __traits(hasMember, T, "__xdtor") ) 
			PoolStack.top.onDestroy(&((*ret).__xdtor));
		
	}
	
	return ret;
}

/// arrays
auto alloc(T)(size_t n)
	if (isArray!T)
{
	
	T ret;
	if (!PoolStack.empty) {
		ret = allocArray!(ElementType!T, PoolStack)(n);
		registerPoolArray(ret);
	}
	return ret;
}

auto realloc(T)(ref T arr, size_t n)
	if (isArray!T)
{
	T ret;
	if (!PoolStack.empty) {
		scope(exit) arr = null;
		ret = reallocArray!(ElementType!T, PoolStack)(arr, n);
		reregisterPoolArray(arr, ret);
	}
}


struct PoolStack {
static:
nothrow:
	@property bool empty() { return m_tstack.empty; }

	/// returns the most recent unfrozen pool, null if none available
	@property ManagedPool top() {
		return m_tstack.top;
	}
	void push(ManagedPool pool) {
		logTrace("Push ManagedPool ThreadStack");
		m_tstack.push(pool);
	}
	/// creates a new pool as the fiber stack top or the thread stack top
	void push(size_t max_mem = 0) {
		//logTrace("Pushing PoolStack");
		
		logTrace("Push ThreadStack");
		m_tstack.push(max_mem);
		//logTrace("Pushed ThreadStack");
	}

	/// destroy the most recent pool and free all its resources, calling destructors
	/// if you're in a fiber, search for stack top in the fiber stack or the fiber freezer and destroy it.
	/// otherwise, search in the thread stack or the thread freezer and destroy it.
	void pop() {
		//logTrace("Pop PoolStack");
		// else
		//auto top = m_tstack.top;
		//assert(top, "Can't find a pool to pop");
		logTrace("Pop ThreadStack");
		if (m_tstack.hasTop)
			return m_tstack.pop();
		logTrace("Doesn't have top?");
		//else
		logTrace("Destroying");

	}

	void disable() {
		freeze(m_tstack.length);
	}

	void enable() {
		unfreeze(m_tfreezer.length);
	}

	// returns number of pools frozen
	size_t freeze(size_t n = 1) {
		logTrace("Freeze");
		auto tsz = min(m_tstack.length, n);
		if (tsz > 0) {
			auto frozen = m_tstack.freeze(tsz);
			m_tfreezer.push(frozen);
		}
		return tsz;
	}

	// returns number of pools unfrozen
	size_t unfreeze(size_t n = 1) {
		logTrace("Unfreeze");
		auto tsz = min(m_tfreezer.length, n);
		if (tsz > 0) {
			auto frozen = m_tfreezer.pop(tsz);
			m_tstack.unfreeze(frozen);
		}
		return tsz;
	}

private static:
	// active
	__gshared ThreadPoolStack m_tstack;

	// frozen
	__gshared ThreadPoolFreezer m_tfreezer;

}

package:

alias Pool = PoolAllocator!(AutoFreeListAllocator!(MallocAllocator));
alias ManagedPool = RefCounted!Pool;

/// User utility for allocating on lower level pools
struct ThreadPoolFreezer 
{
nothrow:
	@disable this(this);
	@property size_t length() const { return m_pools.length; }
	@property bool empty() const { return length == 0; }

	void push(ref Vector!(ManagedPool, ThreadMem) pools)
	{
		logTrace("Push Thread Freezer of ", m_pools.length);
		// insert sorted
		foreach(ref item; pools[]) {
			bool found;
			foreach (size_t i, ref el; m_pools[]) {
				if (item.id < el.id) {
					m_pools.insertBefore(i, item);
					found = true;
					break;
				}
			}
			if (!found) m_pools ~= item;
		}
		logTrace("Pushed Thread Freezer now ", m_pools.length);
	}

	Vector!(ManagedPool, ThreadMem) pop(size_t n) {
		assert(!empty);
		logTrace("Pop Thread Freezer of ", m_pools.length, " id ", m_pools.back.id);
		// already sorted
		auto pools = Vector!(ManagedPool, ThreadMem)( m_pools[$-n .. $] );
		m_pools.length = (m_pools.length - n);
		logTrace("Popped Thread Freezer returning ", pools.length, " expecting ", n);
		logTrace("Returning ID ", pools.back.id);
		return pools.move;
	}
	
package:
	Vector!(ManagedPool, ThreadMem) m_pools;
}

struct ThreadPoolStack
{
nothrow:
	@disable this(this);
	@property size_t length() const { return m_pools.length; }
	@property bool empty() const { return length == 0; }
	size_t opDollar() const { return length; }
	@property bool hasTop() { return length > 0 && cnt == top.id; }


	ManagedPool opIndex(size_t n) {
		logTrace("OpIndex[", n, "] in Thread Pool of ", length, " top: ", cnt, " id: ", m_pools[n].id);
		return m_pools[n];
	}

	@property ManagedPool top() 
	{
		logTrace("Front Thread Pool of ", length);
		if (empty) {
			logTrace("Empty");
			return ManagedPool(0);
		}
		return m_pools.back;
	}

	void pop()
	{
		assert(!empty);
		logTrace("Pop Thread Pool of ", length, " top: ", cnt, " back id: ", m_pools.back.id);
		auto pool = m_pools.back;
		assert(pool.id == cnt);
		--cnt;
		m_pools.removeBack();
		logTrace("Popped Thread Pool of ", length, " top: ", cnt, " back id: ", m_pools.length > 0 ? charFromInt[m_pools.back.id] : '?');
	}

	void push(ManagedPool pool) {
		pool.id = ++cnt;
		m_pools.pushBack(pool);
	}
	
	void push(size_t max_mem = 0) {
		if (!m_pools.empty) logTrace("Push Thread Pool of ", length, " top: ", cnt, " back id: ", m_pools.back.id);
		else logTrace("Push Thread Pool of ", length, " top: ", cnt);
		ManagedPool pool = ManagedPool(max_mem);
		pool.id = ++cnt;
		m_pools.pushBack(pool);
		logTrace("Pushed Thread Pool of ", length, " top: ", cnt, " back id: ", m_pools.back.id);
	}

	Vector!(ManagedPool, ThreadMem) freeze(size_t n) {
		assert(!empty);
		if (!m_pools.empty) logTrace("Freeze ", n, " in Thread Pool of ", length, " top: ", cnt);
		else logTrace("Freeze ", n, " in Thread Pool of ", length, " top: ", cnt, " back id: ", m_pools.back.id);
		assert(n <= length);
		Vector!(ManagedPool, ThreadMem) ret = Vector!(ManagedPool, ThreadMem)( m_pools[$-n .. $] );
		m_pools.length = (m_pools.length - n);
		logTrace("Returning ", ret.length);
		logTrace("Freezeed ", n, " in Thread Pool of ", length, " top: ", cnt, " back id: ", m_pools.length > 0 ? charFromInt[m_pools.back.id] : '?');
		return ret.move;
	}

	void unfreeze(ref Vector!(ManagedPool, ThreadMem) pools) {
		logTrace("Unfreeze ", pools.length, " in Thread Pool of ", length, " top: ", cnt, " back id: ", m_pools.length > 0 ? charFromInt[m_pools.back.id] : '?');
		// insert sorted
		foreach(ref item; pools[]) {
			bool found;
			foreach (size_t i, ref el; m_pools[]) {
				if (item.id < el.id) {
					m_pools.insertBefore(i, item);
					found = true;
					break;
				}
			}
			if (!found) m_pools ~= item;
		}
		logTrace("Unfreezed ", pools.length, " in Thread Pool of ", length, " top: ", cnt, " back id: ", m_pools.back.id);
	}

package:
	int cnt;
	Vector!(ManagedPool, ThreadMem) m_pools;
}


private void registerPoolArray(T)(ref T arr) {
	// Add destructors to fiber pool
	static if (is(T == struct) && (hasElaborateDestructor!(ElementType!T) || __traits(hasMember, ElementType!T, "__xdtor") )) {
		foreach (ref el; arr)
			PoolStack.top.onDestroy(&el.__xdtor);
	}
}

private void reregisterPoolArray(T)(ref T arr, ref T arr2) {
	// Add destructors to fiber pool
	logTrace("reregisterPoolArray");
	static if (is(T == struct) && (hasElaborateDestructor!(ElementType!T) || __traits(hasMember, ElementType!T, "__xdtor") )) {
		if (arr.ptr is arr2.ptr && arr2.length > arr.length) {
			foreach (ref el; arr2[arr.length - 1 .. $])
				PoolStack.top.onDestroy(&el.__xdtor);
		}
		else {
			PoolStack.top.removeArrayDtors(&arr.back.__xdtor, arr.length);
			registerPoolArray(arr2);
		}
	}
}