module memutils.constants;

enum { // overhead allocator definitions, lazily loaded
	NativeGC = 0x00, // instances are freed automatically when no references exist in the program's threads
	LocklessFreeList = 0x01, // instances are owned by the creating thread thus must be freed by it
	CryptoSafe = 0x02, // Same as above, but zeroise is called upon freeing
	ScopedFiberPool = 0x03 // One per fiber, calls object destructors when reset. Uses GC if no fiber is set
}

package enum Mallocator = 0x04; // For use by the DebugAllocator.


package:
const LogLevel = Trace;
version(CryptoSafe) 	const HasCryptoSafe = true;
else					const HasCryptoSafe = false;

/// uses a swap protected pool on top of CryptoSafeAllocator
/// otherwise, uses a regular lockless freelist
version(SecurePool)		const HasSecurePool = true;
else					const HasSecurePool = false;

const SecurePool_MLock_Max = 524_287;

version(Have_Botan_d) 	const HasBotan = true; 
else 					const HasBotan = false;

version(DebugAllocations) const HasDebugAllocations = true;
else version(unittest)	  const HasDebugAllocations = true;
else					  const HasDebugAllocations = false;

enum { // LogLevel
	Trace,
	Info,
	Debug,
	Error,
	None
}

void logTrace(ARGS...)(ARGS args) {
	static if (LogLevel <= Trace) {
		import std.stdio: writeln;
		writeln("T: ", args);
	}
}

void logInfo(ARGS...)(ARGS args) {
	static if (LogLevel <= Info) {
		import std.stdio: writeln;
		writeln("I: ", args);
	}
}

void logDebug(ARGS...)(ARGS args) {
	
	static if (LogLevel <= Debug) {
		import std.stdio: writeln;
		writeln("D: ", args);
	}
}

void logError(ARGS...)(ARGS args) {
	static if (LogLevel <= Error) {
		import std.stdio: writeln, stderr;
		stderr.writeln("E: ", args);
	}
}