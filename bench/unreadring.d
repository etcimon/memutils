/**
	Release microbench: UnreadRing (malloc kernel) vs CircularBuffer
	(the leftover store Botan used before the ring) vs UnreadRingImpl!ThreadMem.

	The driver path must stay on malloc UnreadRing. ThreadMem / SecureMem
	are for Botan plaintext and must not regress that kernel by much;
	they will lose on allocate, not on take/put.

	  dub run --root memutils -c bench-unreadring -b release --compiler=ldc2
	  dub run --root memutils -c bench-unreadring -b release --compiler=dmd
*/
module bench_unreadring;

import memutils.unreadring;
import memutils.circularbuffer;
import memutils.utils : ThreadMem;
import core.time : MonoTime, Duration, nsecs;
import std.stdio : writeln, writefln;
import std.conv : to;

enum size_t Iters = 200_000;
enum size_t Warm = 2_000;

void main()
{
	writeln("memutils unread-ring bench  iters=", Iters);
	writeln("size      op            ring-malloc   circ-ThreadMem  ring-ThreadMem   ring/circ");
	benchSize(128, "take128");
	benchSize(2048, "take2k");
	benchSize(16 * 1024, "take16k");
	benchWrap();
	benchRecvStyle(2048);
	benchRecvStyle(16 * 1024);
}

void benchSize(size_t n, string name)
{
	auto src = new ubyte[](n);
	auto dst = new ubyte[](n);
	foreach (i, ref x; src) x = cast(ubyte)i;

	UnreadRing ring;
	scope (exit) ring.dispose();
	ring.reserve(64 * 1024);

	CircularBuffer!(ubyte, 0, ThreadMem) circ;
	circ.capacity = 64 * 1024;

	UnreadRingImpl!ThreadMem rtm;
	scope (exit) rtm.dispose();
	rtm.reserve(64 * 1024);

	// Warm + touch so pages are in.
	foreach (_; 0 .. Warm) {
		ring.put(src);
		ring.take(dst);
		circ.put(src);
		circ.read(dst);
		rtm.put(src);
		rtm.take(dst);
	}

	auto tRing = time(() {
		foreach (_; 0 .. Iters) {
			ring.put(src);
			auto got = ring.take(dst);
			dst[0] ^= cast(ubyte)got;
		}
	});
	auto tCirc = time(() {
		foreach (_; 0 .. Iters) {
			circ.put(src);
			circ.read(dst);
			dst[0] ^= dst[$ - 1];
		}
	});
	auto tRtm = time(() {
		foreach (_; 0 .. Iters) {
			rtm.put(src);
			auto got = rtm.take(dst);
			dst[0] ^= cast(ubyte)got;
		}
	});
	report(name, tRing, tCirc, tRtm);
}

void benchWrap()
{
	enum size_t cap = 64 * 1024;
	enum size_t n = 4096;
	auto src = new ubyte[](n);
	auto dst = new ubyte[](n);
	foreach (i, ref x; src) x = cast(ubyte)(i * 7 + 1);

	UnreadRing ring;
	scope (exit) ring.dispose();
	ring.reserve(cap);
	// Park start 16 bytes from the end so every put/take wraps.
	{
		auto pad = new ubyte[](cap - 16);
		ring.put(pad);
		ring.take(pad);
	}

	CircularBuffer!(ubyte, 0, ThreadMem) circ;
	circ.capacity = cap;
	{
		auto pad = new ubyte[](cap - 16);
		circ.put(pad);
		circ.read(pad);
	}

	UnreadRingImpl!ThreadMem rtm;
	scope (exit) rtm.dispose();
	rtm.reserve(cap);
	{
		auto pad = new ubyte[](cap - 16);
		rtm.put(pad);
		rtm.take(pad);
	}

	foreach (_; 0 .. Warm) {
		ring.put(src); ring.take(dst);
		circ.put(src); circ.read(dst);
		rtm.put(src); rtm.take(dst);
	}

	auto tRing = time(() {
		foreach (_; 0 .. Iters) {
			ring.put(src);
			auto got = ring.take(dst);
			dst[0] ^= cast(ubyte)got;
		}
	});
	auto tCirc = time(() {
		foreach (_; 0 .. Iters) {
			circ.put(src);
			circ.read(dst);
			dst[0] ^= dst[$ - 1];
		}
	});
	auto tRtm = time(() {
		foreach (_; 0 .. Iters) {
			rtm.put(src);
			auto got = rtm.take(dst);
			dst[0] ^= cast(ubyte)got;
		}
	});
	report("wrap4k", tRing, tCirc, tRtm);
}

void benchRecvStyle(size_t n)
{
	auto src = new ubyte[](n);
	auto dst = new ubyte[](n);
	foreach (i, ref x; src) x = cast(ubyte)i;

	UnreadRing ring;
	scope (exit) ring.dispose();
	ring.reserve(64 * 1024);

	CircularBuffer!(ubyte, 0, ThreadMem) circ;
	circ.capacity = 64 * 1024;

	UnreadRingImpl!ThreadMem rtm;
	scope (exit) rtm.dispose();
	rtm.reserve(64 * 1024);

	foreach (_; 0 .. Warm) {
		auto d = ring.peekDst();
		auto m = n < d.length ? n : d.length;
		d[0 .. m] = src[0 .. m];
		ring.putN(m);
		ring.take(dst[0 .. m]);
		auto cd = circ.peekDst();
		auto cm = n < cd.length ? n : cd.length;
		cd[0 .. cm] = src[0 .. cm];
		circ.putN(cm);
		circ.read(dst[0 .. cm]);
	}

	auto tRing = time(() {
		foreach (_; 0 .. Iters) {
			auto d = ring.peekDst();
			auto m = n < d.length ? n : d.length;
			d[0 .. m] = src[0 .. m];
			ring.putN(m);
			auto got = ring.take(dst[0 .. m]);
			dst[0] ^= cast(ubyte)got;
		}
	});
	auto tCirc = time(() {
		foreach (_; 0 .. Iters) {
			auto d = circ.peekDst();
			auto m = n < d.length ? n : d.length;
			d[0 .. m] = src[0 .. m];
			circ.putN(m);
			circ.read(dst[0 .. m]);
			dst[0] ^= dst[m - 1];
		}
	});
	auto tRtm = time(() {
		foreach (_; 0 .. Iters) {
			auto d = rtm.peekDst();
			auto m = n < d.length ? n : d.length;
			d[0 .. m] = src[0 .. m];
			rtm.putN(m);
			auto got = rtm.take(dst[0 .. m]);
			dst[0] ^= cast(ubyte)got;
		}
	});
	report(n == 2048 ? "recv2k" : "recv16k", tRing, tCirc, tRtm);
}

Duration time(scope void delegate() dg)
{
	auto t0 = MonoTime.currTime;
	dg();
	return MonoTime.currTime - t0;
}

void report(string name, Duration ring, Duration circ, Duration rtm)
{
	double ns(Duration d) { return cast(double)d.total!"nsecs" / Iters; }
	auto nr = ns(ring);
	auto nc = ns(circ);
	auto nt = ns(rtm);
	auto ratio = nc > 0 ? nr / nc : 0;
	writefln("%-9s %-12s %10.2f ns %14.2f ns %14.2f ns    %5.2fx",
		name, "put+take", nr, nc, nt, ratio);
}
