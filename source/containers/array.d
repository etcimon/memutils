module containers.array;

import memutils.containers.vector;
import memutils.allocators.allocators;
import memutils.lifetime.refcounted;

template Array(T, int ALLOC = LocklessFreeList) 
	if (!is (T == RefCounted!(Vector!(T, ALLOCATOR))))
{
	alias Array = RefCounted!(Vector!(T, ALLOCATOR));
}

alias SecureArray(T) = Array!(T, CryptoSafeAllocator);