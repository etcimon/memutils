module memutils.constants;

enum LogLevel = Trace;
enum AdvancedCryptoSafety = true; /// uses a swap protected pool on top of CryptoSafeAllocator
								  /// otherwise, uses a regular lockless freelist

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