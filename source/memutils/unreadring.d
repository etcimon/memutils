/**
	Power-of-two unread ring as a mixin.

	Mix into a host (libasync TCP/UDS connection, Botan
	`TLSBlockingChannel`) or use `UnreadRingImpl` / `UnreadRing` /
	`SecureUnreadRing`. Field names are `unread*`-prefixed so the host
	can keep `read` / `empty` / `peek`.

	`ALLOC = void` is raw `malloc`/`free` (libasync leftover). Botan
	mixes `UnreadRingMixin!SecureMem` so dispose zeroises. Do not mix
	`ThreadMem` into the driver path.

	`unreadDrainRecv` / `unreadOnTCP` are the leftover TCP kernel:
	libasync `TCPEvent.READ`/`CLOSE` park `recv` into `unreadPeekDst`.
	`TCPEvent` is a template parameter so memutils does not import
	libasync.
*/
module memutils.unreadring;

import core.stdc.string : memcpy;
import memutils.utils : SecureMem, allocArray, freeArray;
import memutils.cpuid : MemutilsCpuid;

enum size_t unreadRingInitCap = 64 * 1024;

ubyte* unreadRingNew(ALLOC)(size_t ncap)
{
	static if (is(ALLOC == void)) {
		import core.stdc.stdlib : malloc;
		auto np = cast(ubyte*) malloc(ncap);
		if (!np) assert(false, "UnreadRing OOM");
		return np;
	} else {
		ubyte[] arr;
		try arr = allocArray!(ubyte, ALLOC)(ncap);
		catch (Exception) return null;
		return arr.ptr;
	}
}

void unreadRingDelete(ALLOC)(ubyte* p, size_t cap)
{
	if (!p) return;
	static if (is(ALLOC == void)) {
		import core.stdc.stdlib : free;
		free(p);
	} else {
		try freeArray!(ubyte, ALLOC)(p[0 .. cap]);
		catch (Exception) {}
	}
}

mixin template UnreadRingMixin(ALLOC = void) {
	ubyte* unreadPtr;
	size_t unreadCap;   // 0 or power of two
	size_t unreadStart;
	size_t unreadFill;

@safe:

	@property size_t unreadLength() const @nogc { return unreadFill; }
	@property bool unreadEmpty() const @nogc { return unreadFill == 0; }
	@property size_t unreadFreeSpace() const @nogc { return unreadCap > unreadFill ? unreadCap - unreadFill : 0; }
	@property size_t unreadCapacity() const @nogc { return unreadCap; }

	/// Grow to at least `n` (rounded up to a power of two). Botan
	/// `dataCb` uses this the way CircularBuffer.capacity did.
	@property void unreadCapacity(size_t n)
	{
		if (n <= unreadCap) return;
		unreadEnsure(n > unreadFill ? n - unreadFill : n);
	}

	void unreadDispose()
	@trusted {
		if (!unreadPtr) {
			unreadCap = unreadStart = unreadFill = 0;
			return;
		}
		unreadRingDelete!ALLOC(unreadPtr, unreadCap);
		unreadPtr = null;
		unreadCap = unreadStart = unreadFill = 0;
	}

	void unreadReserve(size_t extra)
	{
		unreadEnsure(extra);
	}

	/// Contiguous readable prefix (CircularBuffer.peek).
	inout(ubyte)[] unreadPeek() inout @trusted @nogc
	{
		if (!unreadPtr || !unreadFill) return null;
		size_t n = unreadFill;
		if (unreadStart + unreadFill > unreadCap)
			n = unreadCap - unreadStart;
		return unreadPtr[unreadStart .. unreadStart + n];
	}

	/// Contiguous writable tail. TCP `recv` / TLS records write here.
	ubyte[] unreadPeekDst()
	@trusted @nogc {
		pragma(inline, true);
		if (!unreadPtr || unreadFill >= unreadCap) return null;
		size_t off, n;
		if (unreadStart + unreadFill < unreadCap) {
			off = unreadStart + unreadFill;
			n = unreadCap - off;
		} else {
			off = (unreadStart + unreadFill) & (unreadCap - 1);
			n = unreadStart - off;
		}
		if (!n) return null;
		version (LDC) {
			import memutils.cpuid : MemutilsCpuid;
			if (MemutilsCpuid.hasPrefetch()) {
				import ldc.intrinsics : llvm_prefetch;
				llvm_prefetch(cast(void*)(unreadPtr + off), 1, 3, 1);
			}
		}
		return unreadPtr[off .. off + n];
	}

	void unreadPutN(size_t n) @nogc
	{
		pragma(inline, true);
		debug assert(n <= unreadFreeSpace);
		unreadFill += n;
	}

	void unreadPut(scope const(ubyte)[] src)
	@trusted {
		if (!src.length) return;
		unreadEnsure(src.length);
		unreadRingMove!"put"(unreadPtr, (unreadStart + unreadFill) & (unreadCap - 1), unreadCap,
			cast(ubyte*)src.ptr, src.length);
		unreadFill += src.length;
	}

	size_t unreadTake(scope ubyte[] dst)
	@trusted @nogc {
		pragma(inline, true);
		auto n = dst.length;
		if (n > unreadFill) n = unreadFill;
		if (!n) return 0;
		unreadRingMove!"take"(dst.ptr, unreadStart, unreadCap, unreadPtr, n);
		unreadStart = (unreadStart + n) & (unreadCap - 1);
		unreadFill -= n;
		if (!unreadFill) unreadStart = 0;
		return n;
	}

	/// CircularBuffer.read: dest must fit.
	void unreadRead(scope ubyte[] dst)
	@trusted @nogc {
		debug assert(dst.length <= unreadFill);
		auto n = unreadTake(dst);
		debug assert(n == dst.length);
	}

	/// Park kernel leftover. `recv` returns >0 bytes, 0 = EAGAIN/empty, <0 = retry.
	/// Eventcore leftover `/hello` must call `stream.recv` in a tight
	/// loop (a `scope delegate` here dropped that path to ~0.6× stock).
	size_t unreadDrainRecv(Recv)(scope Recv recv, ref bool sockMaybeMore,
			size_t drainCap = unreadRingInitCap, int retryLimit = 100)
	@trusted {
		if (!sockMaybeMore) return 0;
		if (!unreadCap) unreadReserve(unreadRingInitCap);
		size_t got;
		int retries;
		for (;;) {
			if (!unreadFreeSpace || got >= drainCap)
				break;
			ubyte[] dst = unreadPeekDst();
			if (!dst.length) {
				sockMaybeMore = false;
				break;
			}
			if (dst.length > drainCap - got)
				dst = dst[0 .. drainCap - got];
			auto n = recv(dst);
			if (n > 0) {
				unreadPutN(cast(size_t) n);
				got += cast(size_t) n;
				retries = 0;
				continue;
			}
			if (n < 0 && ++retries < retryLimit)
				continue;
			sockMaybeMore = false;
			break;
		}
		return got;
	}

	/// `Ev` is libasync `TCPEvent`. READ/CLOSE drain; DESTROY disposes.
	void unreadOnTCP(Ev, Recv)(Ev ev, scope Recv recv, ref bool sockMaybeMore)
	{
		if (ev == Ev.READ || ev == Ev.CLOSE)
			unreadDrainRecv(recv, sockMaybeMore);
		else static if (__traits(hasMember, Ev, "DESTROY")) {
			if (ev == Ev.DESTROY)
				unreadDispose();
		}
	}

	void unreadEnsure(size_t extra)
	@trusted {
		if (!extra) return;
		if (unreadFill > size_t.max - extra) return;
		auto need = unreadFill + extra;
		if (need <= unreadCap) return;
		size_t ncap = unreadCap ? unreadCap : unreadRingInitCap;
		while (ncap && ncap < need) {
			auto next = ncap << 1;
			if (next <= ncap) return;
			ncap = next;
		}
		if (!ncap || ncap < need) return;
		ubyte* np = unreadRingNew!ALLOC(ncap);
		if (!np) return;
		if (unreadFill && unreadPtr)
			unreadRingMove!"take"(np, unreadStart, unreadCap, unreadPtr, unreadFill);
		if (unreadPtr)
			unreadRingDelete!ALLOC(unreadPtr, unreadCap);
		unreadPtr = np;
		unreadCap = ncap;
		unreadStart = 0;
	}
}

/// Convenience host. Same names as the pre-mixin struct (`ptr`, `put`, …).
struct UnreadRingImpl(ALLOC = void) {
	mixin UnreadRingMixin!ALLOC;
	alias ptr = unreadPtr;
	alias cap = unreadCap;
	alias start = unreadStart;
	alias fill = unreadFill;
	alias length = unreadLength;
	alias empty = unreadEmpty;
	alias freeSpace = unreadFreeSpace;
	alias capacity = unreadCapacity;
	alias dispose = unreadDispose;
	alias reserve = unreadReserve;
	alias peek = unreadPeek;
	alias peekDst = unreadPeekDst;
	alias putN = unreadPutN;
	alias put = unreadPut;
	alias take = unreadTake;
	alias read = unreadRead;
	alias ensure = unreadEnsure;
	alias drainRecv = unreadDrainRecv;
	alias onTCPUnread = unreadOnTCP;
}

alias UnreadRing = UnreadRingImpl!void;
alias SecureUnreadRing = UnreadRingImpl!SecureMem;

void unreadRingMove(string which)(ubyte* a, size_t off, size_t cap, ubyte* b, size_t n)
@trusted nothrow @nogc {
	pragma(inline, true);

	const size_t first = cap - off;
	size_t wrap = void;
	size_t rest = void;
	ubyte* p0 = void;
	ubyte* p1 = void;
	const(ubyte)* q0 = void;
	const(ubyte)* q1 = void;

	version (LDC) {
		import ldc.intrinsics : llvm_expect, llvm_memcpy, llvm_prefetch;
		import ldc.llvmasm : __asm;

		static if (which == "put") {
			p0 = a + off;
			q0 = b;
		} else {
			p0 = a;
			q0 = b + off;
		}
		if (MemutilsCpuid.hasPrefetch()) {
			llvm_prefetch(cast(const(void)*)q0, 0, 3, 1);
			llvm_prefetch(cast(void*)p0, 1, 3, 1);
		}

		version (X86_64) {
			if (MemutilsCpuid.hasCmov())
				wrap = __asm!size_t(
					"xorq $0, $0; cmpq $2, $1; cmova $3, $0",
					"=&r,r,r,r,~{cc}",
					n, first, 1UL);
			else
				wrap = n > first ? 1 : 0;
		} else {
			wrap = n > first ? 1 : 0;
		}

		if (llvm_expect(wrap != 0, false))
			goto Lwrap;

	Lcontig:
		llvm_memcpy!size_t(cast(void*)p0, cast(const(void)*)q0, n, false);
		return;

	Lwrap:
		rest = n - first;
		static if (which == "put") {
			p1 = a;
			q1 = b + first;
		} else {
			p1 = a + first;
			q1 = b;
		}
		llvm_memcpy!size_t(cast(void*)p0, cast(const(void)*)q0, first, false);
		llvm_memcpy!size_t(cast(void*)p1, cast(const(void)*)q1, rest, false);
		return;
	} else {
		static if (which == "put") {
			if (n <= first) memcpy(a + off, b, n);
			else {
				memcpy(a + off, b, first);
				memcpy(a, b + first, n - first);
			}
		} else {
			if (n <= first) memcpy(a, b + off, n);
			else {
				memcpy(a, b + off, first);
				memcpy(a + first, b, n - first);
			}
		}
	}
}

version (UnreadRingDump) {
	void dumpUnreadRingPut(ubyte* ring, size_t off, size_t cap, ubyte* src, size_t n)
	@trusted nothrow @nogc {
		pragma(inline, false);
		unreadRingMove!"put"(ring, off, cap, src, n);
	}

	void dumpUnreadRingTake(ubyte* dst, size_t off, size_t cap, ubyte* ring, size_t n)
	@trusted nothrow @nogc {
		pragma(inline, false);
		unreadRingMove!"take"(dst, off, cap, ring, n);
	}
}

unittest {
	UnreadRing r;
	scope (exit) r.dispose();

	ubyte[64] a = void;
	ubyte[64] b = void;
	foreach (i, ref x; a) x = cast(ubyte)(i * 3 + 1);

	assert(r.take(b[]) == 0);
	r.put(null);
	assert(r.empty);

	r.put(a[]);
	assert(r.length == a.length);
	assert(r.take(b[]) == a.length);
	assert(b[] == a[]);
	assert(r.empty);
	r.dispose();

	ubyte[unreadRingInitCap] pad = void;
	foreach (i, ref x; pad) x = cast(ubyte)i;
	r.put(pad[0 .. unreadRingInitCap - 8]);
	assert(r.take(pad[0 .. unreadRingInitCap - 8]) == unreadRingInitCap - 8);
	assert(r.empty);
	ubyte[16] seamIn = void;
	ubyte[16] seamOut = void;
	foreach (i, ref x; seamIn) x = cast(ubyte)(0xA0 + i);
	r.put(seamIn[]);
	assert(r.length == 16);
	assert(r.take(seamOut[]) == 16);
	assert(seamOut[] == seamIn[]);
	assert(r.empty);
	r.dispose();

	auto big = new ubyte[](unreadRingInitCap + 100);
	foreach (i, ref x; big) x = cast(ubyte)i;
	r.put(big);
	assert(r.length == big.length);
	auto outb = new ubyte[](big.length);
	assert(r.take(outb) == big.length);
	assert(outb[] == big[]);
	assert(r.empty);
	r.dispose();

	r.reserve(unreadRingInitCap);
	assert(r.peekDst().length == unreadRingInitCap);
	auto d = r.peekDst();
	d[0 .. 64] = a[];
	r.putN(64);
	assert(r.length == 64);
	assert(r.take(b[]) == 64);
	assert(b[] == a[]);
	assert(r.empty);
	assert(r.peekDst().length == unreadRingInitCap);

	r.put(pad[0 .. unreadRingInitCap - 8]);
	assert(r.take(pad[0 .. unreadRingInitCap - 16]) == unreadRingInitCap - 16);
	d = r.peekDst();
	assert(d.length == 8);
	d[] = seamIn[0 .. 8];
	r.putN(8);
	d = r.peekDst();
	assert(d.length == unreadRingInitCap - 16);
	d[0 .. 8] = seamIn[8 .. 16];
	r.putN(8);
	ubyte[24] seamAll = void;
	assert(r.take(seamAll[]) == 24);
	assert(seamAll[0 .. 8] == pad[unreadRingInitCap - 16 .. unreadRingInitCap - 8]);
	assert(seamAll[8 .. 16] == seamIn[0 .. 8]);
	assert(seamAll[16 .. 24] == seamIn[8 .. 16]);

	r.reserve(unreadRingInitCap);
	auto before = r.cap;
	r.ensure(size_t.max);
	assert(r.cap == before);

	struct Host {
		mixin UnreadRingMixin!void;
	}
	Host h;
	scope (exit) h.unreadDispose();
	h.unreadPut(a[]);
	assert(h.unreadLength == a.length);
	assert(h.unreadTake(b[]) == a.length);
	assert(b[] == a[]);
	assert(h.unreadEmpty);

	bool more = true;
	ubyte[8] src = [1, 2, 3, 4, 5, 6, 7, 8];
	size_t off;
	auto parked = h.unreadDrainRecv((ubyte[] dst) {
		if (off >= src.length) return 0;
		auto n = dst.length;
		if (n > src.length - off) n = src.length - off;
		dst[0 .. n] = src[off .. off + n];
		off += n;
		return cast(ptrdiff_t) n;
	}, more);
	assert(parked == src.length);
	assert(!more);
	ubyte[8] out8;
	assert(h.unreadTake(out8[]) == 8);
	assert(out8[] == src[]);

	enum FakeTCP { CONNECT, READ, WRITE, CLOSE, ERROR, DESTROY }
	more = true;
	off = 0;
	h.unreadOnTCP(FakeTCP.READ, (ubyte[] dst) {
		if (off >= src.length) return 0;
		auto n = dst.length < src.length - off ? dst.length : src.length - off;
		dst[0 .. n] = src[off .. off + n];
		off += n;
		return cast(ptrdiff_t) n;
	}, more);
	assert(h.unreadLength == src.length);
	h.unreadOnTCP(FakeTCP.DESTROY, (ubyte[]) { return 0; }, more);
	assert(h.unreadPtr is null);
}
