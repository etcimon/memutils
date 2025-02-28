module memutils.scoped;

import core.thread : Fiber;
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
import std.traits : hasElaborateDestructor, isArray;
import std.algorithm : min;
import std.exception;
import core.exception;
import core.stdc.string : memcpy;

alias ScopedPool = RefCounted!ScopedPoolImpl;

final class ScopedPoolImpl {
	// TODO: Use a name for debugging?

	int id;
	/// Initializes a scoped pool with max_mem
	/// max_mem doesn't do anything at the moment
	this(size_t max_mem = 0) {
		PoolStack.push(max_mem);
		id = PoolStack.top.id;
		//logDebug("ScopedPool.this id: ", id);
	}
	
	this(ManagedPool pool) {
		PoolStack.push(pool);
		id = PoolStack.top.id;
	}

	~this() {
		//logDebug("ScopedPool.~this id: ", id, " PoolStack.top.id: ", PoolStack.top.id);
		debug if(id != PoolStack.top.id) {
			//logDebug("Unfreezing...");
			unfreeze();
		}
		PoolStack.pop();
	}

	/// Use only if ScopedPool is the highest on stack.
	void freeze() {
		enforce(id == PoolStack.top.id);
		enforce(PoolStack.freeze(1) == 1, "Failed to freeze pool");
	}

	void unfreeze() {
		enforce(PoolStack.unfreeze(1) == 1, "Failed to unfreeze pool");
		enforce(id == PoolStack.top.id);
	}
}

T alloc(T, ARGS...)(auto ref ARGS args)
	if (is(T == class) || is(T == interface) || __traits(isAbstractClass, T))
{
	T ret;
	
	if (!PoolStack.empty) {
		ret = ObjectAllocator!(T, PoolStack).alloc(args);
		
		// Add destructor to pool
		static if (hasElaborateDestructor!T || __traits(hasMember, T, "__xdtor") ) 
			PoolStack.top().onDestroy(&ret.__xdtor);
	}
	else {
		ret = new T(args);
	}
	
	return ret;
}

T* alloc(T, ARGS...)(auto ref ARGS args)
	if (!isArray!T && (!(is(T == class) || is(T == interface) || __traits(isAbstractClass, T))))
{
	T* ret;
	
	if (!PoolStack.empty) {
		ret = ObjectAllocator!(T, PoolStack).alloc(args);
		
		// Add destructor to pool
		static if (hasElaborateDestructor!T || __traits(hasMember, T, "__xdtor") ) 
			PoolStack.top.onDestroy(&ret.__xdtor);
		
	}
	else {
		ret = new T(args);
	}
	
	return ret;
}

/// arrays
auto alloc(T)(size_t n)
	if (isArray!T)
{
	import std.range : ElementType;
	
	T ret;
	if (!PoolStack.empty) {
		ret = allocArray!(ElementType!T, PoolStack)(n);
		registerPoolArray(ret);
	}
	else {
		ret = new T(n);
	}
	return ret;
}

auto realloc(T)(ref T arr, size_t n)
	if (isArray!T)
{
	import std.range : ElementType;
	T ret;
	if (!PoolStack.empty) {
		scope(exit) arr = null;
		ret = reallocArray!(ElementType!T, PoolStack)(arr, n);
		reregisterPoolArray(arr, ret);
	}
	else {
		ret.length = n;
		ret[0 .. arr.length] = arr[];
		arr = null;
	}
	return ret;
}

auto copy(T)(auto ref T arr)
	if (isArray!T)
{
	import std.range : ElementType;
	
	alias ElType = UnConst!(typeof(arr[0]));

	ElType[] ret;
	if (!PoolStack.empty) {
		ret = allocArray!(ElType, PoolStack)(arr.length);
		memcpy(cast(void*)ret.ptr, cast(void*)arr.ptr, arr.length * ElType.sizeof);
	} else {
		ret.length = arr.length;
		ret[] = arr[];
	}

	return cast(T)ret;
}

struct PoolStack {
static:
	@property bool empty() { return m_tstack.empty && m_fstack.empty; }

	/// returns the most recent unfrozen pool, null if none available
	@property ManagedPool top() {
		assert(!m_fstack.empty || !m_tstack.empty, "No Pool found on stack");
		assert((Fiber.getThis() && !m_fstack.empty) || !m_tstack.empty, "PoolStack.top() called with empty PoolStack");
		if (Fiber.getThis() && !m_fstack.empty) {
			return m_fstack.top;
		}
		return m_tstack.top;
	}

	/// creates a new pool as the fiber stack top or the thread stack top
	void push(size_t max_mem = 0) {
		logTrace("Pushing PoolStack");
		if (Fiber.getThis())
			return m_fstack.push(max_mem);
		m_tstack.push(max_mem);
		//logTrace("Pushed ThreadStack");
	}

	void push(ManagedPool pool) {
		logTrace("Push ManagedPool ThreadStack");
		
		if (Fiber.getThis())
			return m_fstack.push(pool);
		m_tstack.push(pool);
	}

	/// destroy the most recent pool and free all its resources, calling destructors
	/// if you're in a fiber, search for stack top in the fiber stack and destroy it.
	/// otherwise, search in the thread stack and destroy it.
	void pop() {
		logTrace("Pop PoolStack");
		if (Fiber.getThis() && (!m_fstack.empty || !m_ffreezer.empty))
		{
			//logTrace("Pop FiberStack");
			assert(!m_fstack.empty, "pop() called on empty FiberPoolStack");
			return m_fstack.pop();
		}
		assert(!m_tstack.empty, "pop() called on empty ThreadPoolStack");
		return m_tstack.pop();
		//logTrace("Destroyign ", ret.back.id);

	}

	void disable() {
		freeze(m_tstack.length + m_fstack.length);
	}

	void enable() {
		unfreeze(m_ffreezer.length + m_tfreezer.length);
	}

	// returns number of pools frozen
	size_t freeze(size_t n = 1) {
		auto minsz = min(m_fstack.length, n);

		if (minsz > 0) {
			auto frozen = m_fstack.freeze(minsz);
			m_ffreezer.push(frozen);
		}

		if (minsz < n) {
			auto tsz = min(m_tstack.length, n - minsz);
			if (tsz > 0) {
				auto frozen = m_tstack.freeze(tsz);
			 	m_tfreezer.push(frozen);
			}
			return tsz + minsz;
		}
		return minsz;
	}

	// returns number of pools unfrozen
	size_t unfreeze(size_t n = 1) {
		auto minsz = min(m_ffreezer.length, n);
		
		if (minsz > 0) {
			auto frozen = m_ffreezer.pop(minsz);
			m_fstack.unfreeze(frozen);

		}
		
		if (minsz < n) {
			auto tsz = min(m_tfreezer.length, n - minsz);
			if (tsz > 0) {
				auto frozen = m_tfreezer.pop(tsz);
				m_tstack.unfreeze(frozen);

			}
			return tsz + minsz;
		}
		return minsz;
	}

	~this() {
		destroy(m_fstack);
		destroy(m_tstack);
	}

private static:
	// active
	ThreadPoolStack m_tstack;
	FiberPoolStack m_fstack;

	// frozen
	ThreadPoolFreezer m_tfreezer;
	FiberPoolFreezer m_ffreezer;

}

alias ManagedPool = RefCounted!(Pool);

package:

alias Pool = PoolAllocator!(AutoFreeListAllocator!(MallocAllocator));

/// User utility for allocating on lower level pools
struct ThreadPoolFreezer 
{
	@disable this(this);
	@property size_t length() const { return m_pools.length; }
	@property bool empty() const { return length == 0; }

	void push(Array!(ManagedPool, Malloc) pools)
	{
		//logTrace("Push Thread Freezer of ", m_pools.length);
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
		//logTrace("Pushed Thread Freezer now ", m_pools.length);
	}

	Array!(ManagedPool, Malloc) pop(size_t n) {
		assert(!empty);
		//logTrace("Pop Thread Freezer of ", m_pools.length, " id ", m_pools.back.id);
		// already sorted
		auto pools = Array!(ManagedPool, Malloc)( m_pools[$-n .. $] );

		
		m_pools.length = (m_pools.length - 1);
		//logTrace("Popped Thread Freezer returning ", pools.length, " expecting ", n);
		//logTrace("Returning ID ", pools.back.id);
		return pools;
	}
	
package:
	Vector!(ManagedPool, Malloc) m_pools;
}

/// User utility for allocating on lower level pools
struct FiberPoolFreezer
{
	@disable this(this);
	@property size_t fibers() const { return m_pools.length; }
	
	@property size_t length() const { 
		Fiber f = Fiber.getThis();
		if (auto ptr = (f in m_pools)) {
			return (*ptr).length;
		}
		return 0;
	}

	@property bool empty() const {
		return length == 0; 
	}

	void push(Array!(ManagedPool, Malloc) pools)
	{
		logDebug("Push Fiber Freezer of ", length);
		Fiber f = Fiber.getThis();
		assert(f !is null);
		if (auto ptr = (f in m_pools)) {
			auto arr = *ptr;

			// insert sorted
			foreach(ref item; pools[]) {
				bool found;
				foreach (size_t i, ref el; arr[]) {
					if (item.id < el.id) {
						arr.insertBefore(i, item);
						found = true;
						break;
					}
				}
				if (!found) arr ~= item;
			}
			//logTrace("Pushed Fiber Freezer of ", length);
			return;
		}
		//else
		m_pools[f] = pools.cloneToRef;
		//logTrace("Pushed Fiber Freezer of ", length);
	}

	Array!(ManagedPool, Malloc) pop(size_t n) {
		logDebug("Pop Fiber Freezer of ", length);
		assert(!empty);
		
		Fiber f = Fiber.getThis();
		auto arr = m_pools[f];

		if (arr.empty) {
			m_pools.remove(f);
			return Array!(ManagedPool, Malloc)();
		}

		// already sorted
		auto pools = Array!(ManagedPool, Malloc)( arr[$-n .. $] );
		arr.length = (arr.length - n);
		//logTrace("Popped Fiber Freezer of ", length);
		return pools;
	}

private:

	HashMap!(Fiber, Array!(ManagedPool, Malloc), Malloc) m_pools;
}
struct ThreadPoolStack
{
	@disable this(this);
	@property size_t length() const { return m_pools.length; }
	@property bool empty() const { return length == 0; }
	size_t opDollar() const { return length; }
	@property bool hasTop() { return length > 0 && cnt-1 == top.id; }


	ManagedPool opIndex(size_t n) {
		//logTrace("OpIndex[", n, "] in Thread Pool of ", length, " top: ", cnt, " id: ", m_pools[n].id);
		return m_pools[n];
	}

	@property ManagedPool top() 
	{
		//logTrace("Front Thread Pool of ", length);
		if (empty) {
			//logTrace("Empty");
			return ManagedPool();
		}
		return m_pools.back;
	}

	void pop()
	{
		assert(!empty);
		//logTrace("Pop Thread Pool of ", length, " top: ", cnt, " back id: ", m_pools.back.id);
		auto pool = m_pools.back;
		//assert(pool.id == cnt-1);
		//--cnt;
		m_pools.removeBack();
		//if (!empty) logTrace("Popped Thread Pool of ", length, " top: ", cnt, " back id: ", m_pools.back.id);
	}

	void push(ManagedPool pool) {
		if (pool.id == -1) {
			pool.id = cnt++;
		}
		//pool.id = *cast(int*)&pool.id;

		m_pools.pushBack(pool);
	}

	void push(size_t max_mem = 0) {
		//if (!m_pools.empty) logTrace("Push Thread Pool of ", length, " top: ", cnt, " back id: ", m_pools.back.id);
		//else logTrace("Push Thread Pool of ", length, " top: ", cnt);
		ManagedPool pool = ManagedPool(max_mem);
		pool.id = cnt++;
		m_pools.pushBack(pool);
		//logTrace("Pushed Thread Pool of ", length, " top: ", cnt, " back id: ", m_pools.back.id);
	}

	Array!(ManagedPool, Malloc) freeze(size_t n) {
		assert(!empty);
		//if (!m_pools.empty) logTrace("Freeze ", n, " in Thread Pool of ", length, " top: ", cnt);
		//else logTrace("Freeze ", n, " in Thread Pool of ", length, " top: ", cnt, " back id: ", m_pools.back.id);
		assert(n <= length);
		auto ret = Array!(ManagedPool, Malloc)(n);
		ret[] = m_pools[$-n .. $];
		m_pools.removeBack(n);
		//logTrace("Returning ", ret.length);
		//if (!empty) logTrace("Freezeed ", n, " in Thread Pool of ", length, " top: ", cnt, " back id: ", m_pools.back.id);
		return ret;
	}

	void unfreeze(Array!(ManagedPool, Malloc) pools) {
		//logTrace("Unfreeze ", pools.length, " in Thread Pool of ", length, " top: ", cnt, " back id: ", m_pools.back.id);
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
		//logTrace("Unfreezed ", pools.length, " in Thread Pool of ", length, " top: ", cnt, " back id: ", m_pools.back.id);
	}

package:
	int cnt;
	Vector!(ManagedPool, Malloc) m_pools;
}

struct FiberPoolStack
{
	@disable this(this);
	@property size_t fibers() const { return m_pools.length; }

	@property size_t length() const {
		Fiber f = Fiber.getThis();
		if (auto ptr = (f in m_pools)) {
			return (*ptr).length;
		}
		return 0;
	}

	@property bool hasTop() { return length > 0 && cnt[Fiber.getThis()]-1 == top.id; }

	@property bool empty() const {
		return length == 0; 
	}

	size_t opDollar() const { return length; }

	ManagedPool opIndex(size_t n) {
		assert(!empty);
		Fiber f = Fiber.getThis();
		//logTrace("OpIndex[", n, "] in Fiber Pool of ", length, " top: ", cnt, " id: ", m_pools[f][n].id);
		return m_pools[f][n];

	}

	@property ManagedPool top() 
	{
		assert(!empty);
		Fiber f = Fiber.getThis();
		if (auto ptr = (f in m_pools)) {
			//logTrace("top in Fiber Pool of ", length, " top: ", cnt, " len: ", (*ptr).back().id);
			return (*ptr).back();
		}
		return ManagedPool();

	}

	// returns next item ie. top()
	void pop() {
		assert(!empty);

		Fiber f = Fiber.getThis();
		logDebug("pop in Fiber Pool of ", length, " top: ", cnt[Fiber.getThis()]);
		logDebug(" id: ", m_pools[f].back.id);
		auto arr = m_pools[f];
		assert(arr.back.id == cnt[Fiber.getThis()]-1);
		arr.removeBack();
		cnt[Fiber.getThis()] = cnt[Fiber.getThis()] - 1;
		if (arr.empty) {
			m_pools.remove(f);
			cnt.remove(f);
		}
		if (!empty) logTrace("popped in Fiber Pool of ", length, " top: ", cnt[Fiber.getThis()], " id: ", m_pools[f].back.id);
	}

	void push(ManagedPool pool) {	
		Fiber f = Fiber.getThis();
		assert(f !is null);
		int* cur_cnt = (Fiber.getThis() in cnt);

		if (pool.id == -1) {
			if (!cur_cnt) {
				cnt[Fiber.getThis()] = 0;
				cur_cnt = (Fiber.getThis() in cnt);
			}
			pool.id = *cur_cnt;
			*cur_cnt = (*cur_cnt) + 1;
		}
		//pool.id = *cast(int*)&pool.id;

		if (auto ptr = (f in m_pools)) {
			*ptr ~= pool;
			logTrace("Pushed in Fiber Pool of ", length, " top: ", *cur_cnt, " id: ", m_pools[f].back.id);
			return;
		}
		//else
		m_pools[f] = Array!(ManagedPool, Malloc)();
		m_pools[f] ~= pool;
	}

	void push(size_t max_mem = 0)
	{
		Fiber f = Fiber.getThis();
		//logDebug("Got fiber ", cast(void*)&f);
		//logDebug("Push in Fiber Pool of ", length, " top: ", *cur_cnt);
		assert(f !is null);

		ManagedPool pool = ManagedPool(max_mem);
		int* cur_cnt = (Fiber.getThis() in cnt);
		if (!cur_cnt) {
			cnt[Fiber.getThis()] = 0;
			cur_cnt = (Fiber.getThis() in cnt);
		}
		pool.id = *cur_cnt;
		*cur_cnt = (*cur_cnt) + 1;

		if (auto ptr = (f in m_pools)) {
			*ptr ~= pool;
			logTrace("Pushed in Fiber Pool of ", length, " top: ", *cur_cnt, " id: ", m_pools[f].back.id);
			return;
		}
		//else
		m_pools[f] = Array!(ManagedPool, Malloc)();
		m_pools[f] ~= pool;
		//logDebug("Pushed in Fiber Pool of ", length, " top: ", cnt[Fiber.getThis()], " id: ", m_pools[f].back.id);
	}

	// returns the frozen items
	Array!(ManagedPool, Malloc) freeze(size_t n) {
		assert(n <= length);
		Fiber f = Fiber.getThis();
		logDebug("Freeze in Fiber Pool of ", length, " top: ", cnt[Fiber.getThis()], " id: ", m_pools[f].back.id);
		auto arr = m_pools[f];
		logDebug("Got array");
		auto ret = Array!(ManagedPool, Malloc)(n);
		ret[] = arr[$-n .. $];
		arr.removeBack(n);
		logDebug("Frozen in Fiber Pool of ", length, " top: ", cnt[Fiber.getThis()]);
		return ret;
	}


	void unfreeze(Array!(ManagedPool, Malloc) items)
	{
		Fiber f = Fiber.getThis();
		assert(f !is null);
		logDebug("Unfreeze in Fiber Pool of ", length, " top: ", cnt[Fiber.getThis()]);
		if (auto ptr = (f in m_pools)) {
			auto arr = *ptr;
			// insert sorted
			foreach(ref item; items[]) {
				bool found;
				foreach (size_t i, ref el; arr[]) {
					if (item.id < el.id) {
						arr.insertBefore(i, item);
						found = true;
						break;
					}
				}
				if (!found) arr ~= item;
			}
			logDebug("Unfrozen in Fiber Pool of ", length, " top: ", cnt[Fiber.getThis()], " id: ", m_pools[f].back.id);
			return;
		}
		assert(false);
	}
package:
	HashMap!(Fiber, int) cnt;
	HashMap!(Fiber, Array!(ManagedPool, Malloc), Malloc) m_pools;
}


private void registerPoolArray(T)(ref T arr) {
	import std.range : ElementType;
	// Add destructors to fiber pool
	static if (is(T == struct) && (hasElaborateDestructor!(ElementType!T) || __traits(hasMember, ElementType!T, "__xdtor") )) {
		foreach (ref el; arr)
			PoolStack.top.onDestroy(&el.__xdtor);
	}
}

private void reregisterPoolArray(T)(ref T arr, ref T arr2) {
	import std.range : ElementType;
	// Add destructors to fiber pool
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