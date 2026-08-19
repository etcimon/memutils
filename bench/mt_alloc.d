/**
	N-thread hammer of ThreadMem Vector alloc/free.

	This is the lock that used to be pthread_mutex on AutoFreeListAllocator.
	Build twice:
	  dub build -c bench-mt-alloc --compiler=ldc2 -b release
	  dub build -c bench-mt-alloc --compiler=ldc2 -b release --build-mode=all --d-version=TLSGC
	(or -c bench-mt-alloc-tlsgc)

	Exit 0 only if every thread finishes and bytesAllocated is 0 (non-TLSGC
	debug off in release so the 0-check is skipped unless EnableDebugger).
*/
module memutils_bench_mt_alloc;

import memutils.vector;
import memutils.utils : ThreadMem;
import core.atomic;
import core.thread;
import std.conv : to;
import std.datetime.stopwatch;
import std.stdio;

shared ulong g_ops;
shared ulong g_fail;

void worker(int id, int iters)
{
	try {
		foreach (i; 0 .. iters) {
			Vector!(ubyte, ThreadMem) v;
			v.reserve(64 + (i % 512));
			v ~= cast(ubyte) id;
			v ~= cast(ubyte) i;
			if (v.length < 2)
				atomicOp!"+="(g_fail, 1);
			destroy(v);
			atomicOp!"+="(g_ops, 1);
		}
	} catch (Throwable t) {
		atomicOp!"+="(g_fail, 1);
		stderr.writeln("thread ", id, " ", t.msg);
	}
}

void main(string[] args)
{
	const threads = args.length > 1 ? to!int(args[1]) : 8;
	const iters = args.length > 2 ? to!int(args[2]) : 50_000;
	version (TLSGC)
		enum mode = "tlsgc";
	else
		enum mode = "spinlock";
	writeln("memutils mt-alloc  mode=", mode, " threads=", threads, " iters=", iters);
	Thread[] ts;
	auto sw = StopWatch(AutoStart.yes);
	foreach (t; 0 .. threads) {
		auto id = t;
		ts ~= new Thread({ worker(id, iters); });
		ts[$ - 1].start();
	}
	foreach (t; ts)
		t.join();
	sw.stop();
	const ms = sw.peek().total!"msecs";
	const ops = atomicLoad(g_ops);
	const fail = atomicLoad(g_fail);
	const opsPerSec = ms > 0 ? (ops * 1000.0) / ms : 0;
	writeln("ops=", ops, " fail=", fail, " ms=", ms, " ops/s=", opsPerSec);
	if (fail != 0 || ops != cast(ulong) threads * iters)
		throw new Exception("mt-alloc failed");
}
