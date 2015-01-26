module memutils.tests;
import memutils.all;

import std.stdio : writeln;

// Test hashmap, freelists
unittest {
	{
		HashMapRef!(string, string) hm;
		hm["hey"] = "you";
		assert(getAllocator!LocklessFreeList().bytesAllocated() > 0);
		void hello(HashMapRef!(string, string) map) {
			assert(map["hey"] == "you");
			map["you"] = "hey";
		}
		hello(hm);
		assert(hm["you"] == "hey");
		destroy(hm);
		assert(hm.empty);
	}
	assert(getAllocator!LocklessFreeList().bytesAllocated() == 0);
	
}

// Test Vector, FreeLists & Array
unittest {
	{
		assert(getAllocator!LocklessFreeList().bytesAllocated() == 0);
		Vector!ubyte data;
		data ~= "Hello there";
		assert(getAllocator!LocklessFreeList().bytesAllocated() > 0);
		assert(data[] == "Hello there");

		Vector!(Array!ubyte) arr;
		arr ~= data.dupr;
		assert(arr[0] == data && arr[0][] == "Hello there");
	}
	assert(getAllocator!LocklessFreeList().bytesAllocated() == 0);
}

// Test HashMap, FreeLists & Array
unittest {
	assert(getAllocator!LocklessFreeList().bytesAllocated() == 0);
	{
		HashMap!(string, Array!dchar) hm;
		hm["hey"] = array("you"d);
		hm["hello"] = hm["hey"];
		assert(*hm["hello"] is *hm["hey"]);
		hm["hello"] = hm["hey"].dupr;
		assert(*hm["hello"] !is *hm["hey"]);
		auto vec = hm["hey"].dup;
		assert(vec[] == hm["hey"][]);


		assert(!__traits(compiles, { void handler(HashMap!(string, Array!dchar) hm) { } handler(hm); }));
	}

	assert(getAllocator!LocklessFreeList().bytesAllocated() == 0);
}

// Test RBTree
unittest {
	assert(getAllocator!LocklessFreeList().bytesAllocated() == 0);
	{
		RBTree!(int, "a < b", true, LocklessFreeList) rbtree;

		rbtree.insert( [50, 51, 52, 53, 54] );
		auto vec = rbtree.lowerBoundRange(52).vector();
		assert(vec[] == [50, 51]);
	}
	assert(getAllocator!LocklessFreeList().bytesAllocated() == 0);
}

// Test Unique
void uniqueTest(int ALLOC)() {
	class A { int a; }
	Unique!(A, ALLOC) a;
	auto inst = FreeListObjectAlloc!(A, ALLOC).alloc();
	A a_check = inst;
	inst.a = 10;
	auto bytes = getAllocator!ALLOC().bytesAllocated();
	assert(bytes > 0);
	a = inst;
	assert(!inst);
	assert(a.a == 10);
	a.free();
	assert(getAllocator!ALLOC().bytesAllocated() < bytes);
}

unittest {
	uniqueTest!NativeGC();
	uniqueTest!CryptoSafe();
	uniqueTest!LocklessFreeList();
}

version(unittest) static this() 
{
	import backtrace.backtrace;
	import std.stdio : stdout;
	install(stdout, PrintOptions.init, 0); 
}