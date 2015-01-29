module memutils.tests;
import memutils.all;

import std.stdio : writeln;

// Test hashmap, freelists
void hashmapFreeListTest(ALLOC)() {
	logTrace("hashmapFreeListTest ",  ALLOC.stringof);
	Fiber f = Fiber.getThis();
	assert(getAllocator!(ALLOC.ident)().bytesAllocated() == 0);
	{
		HashMapRef!(string, string, ALLOC) hm;
		hm["hey"] = "you";
		assert(getAllocator!(ALLOC.ident)().bytesAllocated() > 0);
		void hello(HashMapRef!(string, string, ALLOC) map) {
			assert(map["hey"] == "you");
			map["you"] = "hey";
		}
		hello(hm);
		assert(hm["you"] == "hey");
		destroy(hm);
		assert(hm.empty);
	}
	assert(getAllocator!(ALLOC.ident)().bytesAllocated() == 0);
	
}

// Test Vector, FreeLists & Array
void vectorArrayTest(ALLOC)() {
	logTrace("vectorArrayTest ", ALLOC.stringof);
	{
		assert(getAllocator!(ALLOC.ident)().bytesAllocated() == 0);
		Vector!(ubyte, ALLOC) data;
		data ~= "Hello there";
		assert(getAllocator!(ALLOC.ident)().bytesAllocated() > 0);
		assert(data[] == "Hello there");

		Vector!(Array!(ubyte, ALLOC), ALLOC) arr;
		arr ~= data.dupr;
		assert(arr[0] == data && arr[0][] == "Hello there");
	}
	assert(getAllocator!(ALLOC.ident)().bytesAllocated() == 0);
}

// Test HashMap, FreeLists & Array
void hashmapComplexTest(ALLOC)() {
	logTrace("hashmapComplexTest ",  ALLOC.stringof);
	assert(getAllocator!(ALLOC.ident)().bytesAllocated() == 0);
	{
		HashMap!(string, Array!dchar, ALLOC) hm;
		hm["hey"] = array("you"d);
		hm["hello"] = hm["hey"];
		assert(*hm["hello"] is *hm["hey"]);
		hm["hello"] = hm["hey"].dupr;
		assert(*hm["hello"] !is *hm["hey"]);
		auto vec = hm["hey"].dup;
		assert(vec[] == hm["hey"][]);


		assert(!__traits(compiles, { void handler(HashMap!(string, Array!dchar, ALLOC) hm) { } handler(hm); }));
	}

	assert(getAllocator!(ALLOC.ident)().bytesAllocated() == 0);
}

// Test RBTree
void rbTreeTest(ALLOC)() {
	logTrace("rbTreeTest ",  ALLOC.stringof);
	assert(getAllocator!(ALLOC.ident)().bytesAllocated() == 0);
	{
		RBTree!(int, "a < b", true, ALLOC) rbtree;

		rbtree.insert( [50, 51, 52, 53, 54] );
		auto vec = rbtree.lowerBoundRange(52).vector();
		assert(vec[] == [50, 51]);
	}
	assert(getAllocator!(ALLOC.ident)().bytesAllocated() == 0);
}

// Test Unique
void uniqueTest(ALLOC)() {
	logTrace("uniqueTest ",  ALLOC.stringof);

	assert(getAllocator!(ALLOC.ident)().bytesAllocated() == 0);
	{
		class A { int a; }
		Unique!(A, ALLOC) a;
		auto inst = ObjectAllocator!(A, ALLOC).alloc();
		A a_check = inst;
		inst.a = 10;
		auto bytes = getAllocator!(ALLOC.ident)().bytesAllocated();
		assert(bytes > 0);
		a = inst;
		assert(!inst);
		assert(a.a == 10);
		a.free();
	}
	assert(getAllocator!(ALLOC.ident)().bytesAllocated() == 0);
}

// Test FreeList casting
void refCountedCastTest(ALLOC)() {
	logTrace("refCountedCastTest ",  ALLOC.stringof);
	class A {
		this() { a=0; }
		protected int a;
		protected void incr() {
			a += 1;
		}
		public final int get() {
			return a;
		}
	}
	class B : A {
		int c;
		int d;
		long e;
		override protected void incr() {
			a += 3;
		}
	}

	alias ARef = RefCounted!(A, ALLOC);
	alias BRef = RefCounted!(B, ALLOC);

	assert(getAllocator!(ALLOC.ident)().bytesAllocated() == 0);
	{
		ARef a;
		a = ARef();
		a.incr();
		assert(a.get() == 1);
		destroy(a); /// destruction test
		assert(!a);
		assert(getAllocator!(ALLOC.ident)().bytesAllocated() == 0);

		{ /// cast test
			BRef b = BRef();
			a = cast(ARef) b;
			static void doIncr(ARef a_ref) { a_ref.incr(); }
			doIncr(a);
			assert(a.get() == 3);
		}
		ARef c = a;
		assert(c.get() == 3);
		destroy(c);
		assert(a);
	}
	// The B object allocates a lot more. If A destructor called B's dtor we get 0 here.
	assert(getAllocator!(ALLOC.ident)().bytesAllocated() == 0);
}



// todo: test FiberPool, Circular buffer, Scoped

unittest {
	import core.thread;
	hashmapFreeListTest!GC();
	hashmapFreeListTest!SecureMem();
	hashmapFreeListTest!ThisThread();
	Fiber f;
	f = new Fiber(delegate { hashmapFreeListTest!ThisFiber(); });
	f.call();
	destroyFiberPool(f);

	vectorArrayTest!GC();
	vectorArrayTest!SecureMem();
	vectorArrayTest!ThisThread();

	f = new Fiber(delegate { vectorArrayTest!ThisFiber(); });
	f.call();
	destroyFiberPool(f);

	hashmapComplexTest!GC();
	hashmapComplexTest!SecureMem();
	hashmapComplexTest!ThisThread();

	f = new Fiber(delegate { hashmapComplexTest!ThisFiber(); });
	f.call();
	destroyFiberPool(f);

	rbTreeTest!GC();
	rbTreeTest!SecureMem();
	rbTreeTest!ThisThread();

	f = new Fiber(delegate { rbTreeTest!ThisFiber(); });
	f.call();
	destroyFiberPool(f);

	uniqueTest!GC();
	uniqueTest!SecureMem();
	uniqueTest!ThisThread();

	f = new Fiber(delegate { uniqueTest!ThisFiber(); });
	f.call();
	destroyFiberPool(f);

	refCountedCastTest!GC();
	refCountedCastTest!SecureMem();
	refCountedCastTest!ThisThread();

	f = new Fiber(delegate { refCountedCastTest!ThisFiber(); });
	f.call();
	destroyFiberPool(f);

}

version(unittest) static this() 
{
	import backtrace.backtrace;
	import std.stdio : stdout;
	install(stdout, PrintOptions.init, 0); 
}