/**
	Runtime ISA flags for memutils kernels (unread-ring copies, TAS pause).

	memutils is a leaf: it does not import botan.utils.cpuid or botan_math.
	Public SSE/CMOV bits come from druntime `core.cpuid`. ERMS is CPUID
	leaf 7 EBX[9]; druntime parses that bit but does not publish `erms()`.

	Baseline x86_64 `rep movsb` is 8086-era and always legal; ERMS only
	means it is fast. `CMOV` and SSE `PREFETCH`/`PAUSE` are gated so a
	CPU without the bit never executes them.
*/
module memutils.cpuid;

version (X86)
	enum bool memutilsX86 = true;
else version (X86_64)
	enum bool memutilsX86 = true;
else
	enum bool memutilsX86 = false;

version (X86_64)
	import core.cpuid : sse2, avx2, hasCmov, aes, hasPclmulqdq;
else version (X86)
	import core.cpuid : sse2, avx2, hasCmov, aes, hasPclmulqdq;

static if (memutilsX86)
{
	immutable bool g_mu_sse2;
	immutable bool g_mu_cmov;
	immutable bool g_mu_erms;
	immutable bool g_mu_avx2;

	shared static this()
	{
		g_mu_sse2 = sse2;
		g_mu_cmov = hasCmov;
		g_mu_avx2 = avx2;
		uint ebx = muLeaf7Ebx();
		g_mu_erms = (ebx & (1u << 9)) != 0; // ERMS
	}

	private uint muLeaf7Ebx()
	{
		version (LDC)
		{
			import ldc.llvmasm : __asmtuple;
			auto t = __asmtuple!(uint, uint, uint, uint)(
				"cpuid", "={eax},={ebx},={ecx},={edx},{eax},{ecx}", 7, 0);
			return t.v[1];
		}
		else version (GNU)
		{
			uint a = void, b = void, c = void, d = void;
			asm pure nothrow @nogc {
				"cpuid"
				: "=a"(a), "=b"(b), "=c"(c), "=d"(d)
				: "a"(7), "c"(0);
			}
			return b;
		}
		else version (D_InlineAsm_X86_64)
		{
			uint b = void;
			asm pure nothrow @nogc {
				mov EAX, 7;
				xor ECX, ECX;
				cpuid;
				mov b, EBX;
			}
			return b;
		}
		else version (D_InlineAsm_X86)
		{
			uint b = void;
			asm pure nothrow @nogc {
				mov EAX, 7;
				xor ECX, ECX;
				cpuid;
				mov b, EBX;
			}
			return b;
		}
		else
			return 0;
	}
}
else
{
	enum bool g_mu_sse2 = false;
	enum bool g_mu_cmov = false;
	enum bool g_mu_erms = false;
	enum bool g_mu_avx2 = false;
}

struct MemutilsCpuid
{
pure nothrow @nogc:

	/// SSE2. x86_64 always; 32-bit from druntime.
	static bool hasSse2() { return g_mu_sse2; }

	/// CMOV. AMD64 requires it; 32-bit from druntime.
	static bool hasCmov() { return g_mu_cmov; }

	/// Enhanced REP MOVSB/STOSB (leaf 7 EBX[9]). Performance, not legality.
	static bool hasErms() { return g_mu_erms; }

	/// AVX2 + OS XSAVE (druntime).
	static bool hasAvx2() { return g_mu_avx2; }

	/// SSE PREFETCH. x86_64 always; 32-bit needs SSE2. Elsewhere LLVM
	/// `llvm_prefetch` is a hint (nop if the target has none).
	static bool hasPrefetch()
	{
		version (X86_64)
			return true;
		else version (X86)
			return g_mu_sse2;
		else
			return true;
	}

	/// `PAUSE` (F3 90). x86_64 always; 32-bit always (REP NOP on pre-P4).
	static bool hasPause()
	{
		version (X86_64)
			return true;
		else version (X86)
			return true;
		else
			return false;
	}
}

static if (memutilsX86)
unittest
{
	import core.cpuid : sse2, hasCmov;
	assert(MemutilsCpuid.hasSse2() == sse2);
	assert(MemutilsCpuid.hasCmov() == hasCmov);
	cast(void) MemutilsCpuid.hasErms();
	cast(void) MemutilsCpuid.hasPause();
}
