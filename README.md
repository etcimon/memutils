# memutils

The memutils library provides a set of 4 enhanced allocators tweaked for better performance depending on the scope.
A new allocation syntax comes with many benefits, including the easy replacement of allocators.

- NativeGC : The GC Allocator pipes through the original garbage collection, but is integrated to support the new syntax.
- LocklessFreeList: This allocator is fine tuned for thread-local heap allocations and doesn't slow down due to locks or additional pressure on the GC.
- FiberPool: The Fiber Pool contains a list of destructors allocated through it and they are called when it goes out of scope. It is 
best used in a Fiber (Task) to prevent locking, GC pressure, and to release memory in the fastest way possible. 
- CryptoSafe: When storing sensitive data such as private certificates, passwords or keys, the CryptoSafe allocator
enhances safety by zeroising the memory after being freed, and optionally it can use a memory pool (SecurePool) 
that doesn't get dumped to disk on a crash or during OS sleep/hibernation.

The allocator-friendly containers are:
- Vector: An array.
- Array: A RefCounted vector.
- HashMap: A hash map.
- HashMapRef: A RefCounted hashmap.
- RBTree: A red black tree.
- DictionaryList: Similar to a MultiMap in C++, but implemented as a linear search array

The allocator-friendly lifetime management objects are:
- RefCounted: Similar to shared_ptr in C++, it's also compatible with interface casting.
- Unique: Similar to unique_ptr in C++, it destroys an object pointer allocated from the same allocator
 with `.free` or by letting it go out of scope.


### Examples:


You can use `GC`, `ThisThread`, `ThisFiber`, `SecureMem` for array or object allocations!

```D
 A a = ThisThread.alloc!A();
 // do something with "a"
 ThisThread.free(a);

 ubyte[] ub = GC.alloc!(ubyte[])(150);
 assert(ub.length == 150);
```

--------------

The `Vector` container, like every other container, takes ownership of the underlying data.

```D
 string val;
 string gcVal;
 {
 	Vector!char data; // Uses a thread-local allocator by default (LocklessFreeList)
 	data ~= "Hello there";
 	val = data[]; // use opslice [] operator to access the underlying array.
 	gcVal = data[].idup; // move it to the GC to escape the scope towards the unknown!
 }
 assert(gcVal == "Hello there");
 writeln(val); // SEGMENTATION FAULT: The data was collected! (this is a good thing).
```
--------------

The Array type is a RefCounted!(Vector), it allows a hash map to take partial
ownership, because objects marked @disable this(this) are not compatible with the containers.

 ```D
 {
 	HashMap!(string, Array!char) hmap;
 	hmap["hey"] = Array!(char)("Hello there!");
 	assert(hmap["hey"][] == "Hello there!");
 }
 ```

 --------------

 Using the GC for containers doesn't mean it won't free the memory when it goes out of scope!

 In this case, the GC is useful for moving objects to other threads, because of locking, or
 to let the application work without explicit calls to `free()`

 ```D
 string gcVal;
 {
 	Vector!(char, GC) data;
 	data ~= "Hello there";
 	gcVal = data[].idup;
 }
 assert(gcVal == "Hello there");
 ```

 --------------

 The `Unique` lifetime management object takes ownership of GC-allocated memory by default.
 It will free the memory explicitely when it goes out of scope, and it works as an object member!

 ```D
 class A {
 	int a;
 }
 A a = new A;
 { Unique!A = a; }
 assert(a is null);
 ```

 See source/tests.d for more examples.
