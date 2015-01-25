module memutils.helpers;

package:

void* extractUnalignedPointer(void* base)
{
	ubyte misalign = *(cast(const(ubyte)*)base-1);
	assert(misalign <= Allocator.alignment);
	return base - misalign;
}

void* adjustPointerAlignment(void* base)
{
	ubyte misalign = Allocator.alignment - (cast(size_t)base & Allocator.alignmentMask);
	base += misalign;
	*(cast(ubyte*)base-1) = misalign;
	return base;
}

template UnConst(T) {
	static if (is(T U == const(U))) {
		alias UnConst = U;
	} else static if (is(T V == immutable(V))) {
		alias UnConst = V;
	} else alias UnConst = T;
}

pure {
	/**
    * XOR arrays. Postcondition output[i] = input[i] ^ output[i] forall i = 0...length
    * @param output = the input/output buffer
    * @param input = the read-only input buffer
    * @param length = the length of the buffers
    */
	void xorBuf(T)(T* output, const(T)* input, size_t length)
	{
		while (length >= 8)
		{
			output[0 .. 8] ^= input[0 .. 8];
			
			output += 8; input += 8; length -= 8;
		}
		
		output[0 .. length] ^= input[0 .. length];
	}
	
	/**
    * XOR arrays. Postcondition output[i] = input[i] ^ in2[i] forall i = 0...length
    * @param output = the output buffer
    * @param input = the first input buffer
    * @param in2 = the second output buffer
    * @param length = the length of the three buffers
    */
	void xorBuf(T)(T* output,
		const(T)* input,
		const(T)* input2,
		size_t length)
	{
		while (length >= 8)
		{
			output[0 .. 8] = input[0 .. 8] ^ input2[0 .. 8];
			
			input += 8; input2 += 8; output += 8; length -= 8;
		}
		
		output[0 .. length] = input[0 .. length] ^ input2[0 .. length];
	}
	
	version(none) {
		static if (BOTAN_TARGET_UNALIGNED_MEMORY_ACCESS_OK) {
			
			void xorBuf(ubyte* output, const(ubyte)* input, size_t length)
			{
				while (length >= 8)
				{
					*cast(ulong*)(output) ^= *cast(const ulong*)(input);
					output += 8; input += 8; length -= 8;
				}
				
				output[0 .. length] ^= input[0 .. length];
			}
			
			void xorBuf(ubyte* output,
				const(ubyte)* input,
				const(ubyte)* input2,
				size_t length)
			{
				while (length >= 8)
				{
					*cast(ulong*)(output) = (*cast(const ulong*) input) ^ (*cast(const ulong*)input2);
					
					input += 8; input2 += 8; output += 8; length -= 8;
				}
				
				output[0 .. length] = input[0 .. length] ^ input2[0 .. length];
			}
			
		}
	}
}
void xorBuf(int Alloc, int Alloc2)(ref Vector!( ubyte, Alloc ) output,
	ref Vector!( ubyte, Alloc2 ) input,
	size_t n)
{
	xorBuf(output.ptr, input.ptr, n);
}

void xorBuf(int Alloc)(ref Vector!( ubyte, Alloc ) output,
	const(ubyte)* input,
	size_t n)
{
	xorBuf(output.ptr, input, n);
}

void xorBuf(int Alloc, int Alloc2)(ref Vector!( ubyte, Alloc ) output,
	const(ubyte)* input,
	ref Vector!( ubyte, Alloc2 ) input2,
	size_t n)
{
	xorBuf(output.ptr, input, input2.ptr, n);
}
