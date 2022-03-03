module memutils.constants;

import std.traits : isNumeric;
void function(string) nothrow @safe writeln;
char[] function(long) nothrow @safe parseInt;
package:

enum { // overhead allocator definitions, lazily loaded
	NativeGC = 0x01, // instances are freed automatically when no references exist in the program's threads
	LocklessFreeList = 0x02, // instances are owned by the creating thread thus must be freed by it
	CryptoSafe = 0x03, // Same as above, but zeroise is called upon freeing
}

enum Mallocator = 0x05; // For use by the DebugAllocator.

const LogLevel = Error;
version(DictionaryDebugger) const HasDictionaryDebugger = true;
else					const HasDictionaryDebugger = false;
version(EnableDebugger) const HasDebuggerEnabled = true;
else					  const HasDebuggerEnabled = false;
version(DisableDebugger)   const DisableDebugAllocations = true;
else version(VibeNoDebug) const DisableDebugAllocations = true;
else					const DisableDebugAllocations = false;
public:
static if (HasDebuggerEnabled && !DisableDebugAllocations ) const HasDebugAllocations = true;
else static if (!DisableDebugAllocations) const HasDebugAllocations = true;
else					  const HasDebugAllocations = false;
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
nothrow:

string charFromInt = "0123456789";
__gshared bool recursing = true;

void logTrace(ARGS...)(ARGS args) {
	static if (LogLevel <= Trace) {
		if (recursing) return;
		recursing = true;
		scope(exit) recursing = false;
		import memutils.vector;
		Vector!char app = Vector!char();
		app.reserve(32);
		foreach (arg; args) {
			static if (isNumeric!(typeof(arg)))
				app ~= parseInt(cast(long)arg);
			else app ~= arg;
		}
		writeln(cast(string)app[]);
	}
}

void logInfo(ARGS...)(ARGS args) {
	static if (LogLevel <= Info) {
		if (recursing) return;
		recursing = true;
		scope(exit) recursing = false;
		import memutils.vector;
		Vector!char app = Vector!char();
		app.reserve(32);
		foreach (arg; args) {
			static if (isNumeric!(typeof(arg)))
				app ~= parseInt(cast(long)arg);
			else app ~= arg;
		}
		writeln(cast(string)app[]);
	}
}

void logDebug(ARGS...)(ARGS args) {
	
	static if (LogLevel <= Debug) {
		if (recursing) return;
		recursing = true;
		scope(exit) recursing = false;
		import memutils.vector;
		Vector!char app = Vector!char();
		app.reserve(32);
		foreach (arg; args) {
			static if (isNumeric!(typeof(arg)))
				app ~= parseInt(cast(long)arg);
			else app ~= arg;
		}
			
		writeln(cast(string)app[]);
	}
}

void logError(ARGS...)(ARGS args) {
	static if (LogLevel <= Error) {
		if (recursing) return;
		recursing = true;
		scope(exit) recursing = false;
		import memutils.vector;
		Vector!char app = Vector!char();
		app.reserve(32);
		foreach (arg; args) {
			static if (isNumeric!(typeof(arg)))
				app ~= parseInt(cast(long)arg);
			else app ~= arg;
		}
		writeln(cast(string)app[]);
	}
}
