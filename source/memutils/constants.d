module memutils.constants;

package:

enum { // overhead allocator definitions, lazily loaded
	NativeGC = 0x01, // instances are freed automatically when no references exist in the program's threads
	LocklessFreeList = 0x02, // instances are owned by the creating thread thus must be freed by it
	CryptoSafe = 0x03, // Same as above, but zeroise is called upon freeing
}

enum Mallocator = 0x05; // For use by the DebugAllocator.

const LogLevel = Error;
version(CryptoSafe) 	const HasCryptoSafe = true;
else					const HasCryptoSafe = false;

/// uses a swap protected pool on top of CryptoSafeAllocator
/// otherwise, uses a regular lockless freelist
version(SecurePool)		const HasSecurePool = true;
else				const HasSecurePool = false;

const SecurePool_MLock_Max = 524_287;

version(Have_botan) 	const HasBotan = true; 
else			const HasBotan = false;
version(DictionaryDebugger) const HasDictionaryDebugger = true;
else					const HasDictionaryDebugger = false;
// Opt-in via -version=EnableDebugger (works for DUB -b debug and -b release).
// Unit tests turn it on automatically. DisableDebugger / VibeNoDebug win.
version (EnableDebugger)     const HasDebuggerEnabled = true;
else version (unittest)      const HasDebuggerEnabled = true;
else                         const HasDebuggerEnabled = false;
version (DisableDebugger)    const DisableDebugAllocations = true;
else version (VibeNoDebug)   const DisableDebugAllocations = true;
else                         const DisableDebugAllocations = false;
public:
enum bool HasDebugAllocations = HasDebuggerEnabled && !DisableDebugAllocations;

// Same gate Unique!(T,void) already used: D 2.071+ exposes gc_inFinalizer.
// Allocator locks / TLSGC freelists must not run from a GC finalizer (see allocators.d).
static if (__VERSION__ >= 2071) {
	extern (C) bool gc_inFinalizer() nothrow @nogc;
	enum HasGCCheck = true;
} else version (GCCheck) {
	extern (C) bool gc_inFinalizer() nothrow @nogc;
	enum HasGCCheck = true;
} else enum HasGCCheck = false;

package:
version(SkipMemutilsTests) const SkipUnitTests = true;
else					   const SkipUnitTests = false;

enum { // LogLevel
	Trace,
	Info,
	Debug,
	Error,
	None
}

void logTrace(ARGS...)(lazy ARGS args) {
	static if (LogLevel <= Trace) {
		import std.stdio: writeln;
		writeln("T: ", args);
	}
}

void logInfo(ARGS...)(lazy ARGS args) {
	static if (LogLevel <= Info) {
		import std.stdio: writeln;
		writeln("I: ", args);
	}
}

void logDebug(ARGS...)(lazy ARGS args) {
	
	static if (LogLevel <= Debug) {
		import std.stdio: writeln;
		writeln("D: ", args);
	}
}

void logError(ARGS...)(lazy ARGS args) {
	static if (LogLevel <= Error) {
		import std.stdio: writeln, stderr;
		stderr.writeln("E: ", args);
	}
}
