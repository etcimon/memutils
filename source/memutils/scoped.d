/**
  	Taken from Phobos, tweaked for convenience

	Copyright: Copyright the respective authors, 2008-
	License:   $(WEB boost.org/LICENSE_1_0.txt, Boost License 1.0).
		Authors:   $(WEB erdani.org, Andrei Alexandrescu),
		$(WEB bartoszmilewski.wordpress.com, Bartosz Milewski),
		Don Clugston,
		Shin Fujishiro,
		Kenji Hara
*/
module memutils.scoped;


/**
Allocates a $(D class) object right inside the current scope,
therefore avoiding the overhead of $(D new). This facility is unsafe;
it is the responsibility of the user to not escape a reference to the
object outside the scope.

Note: it's illegal to move a class reference even if you are sure there
are no pointers to it. As such, it is illegal to move a scoped object.
 */
template scoped(T)
	if (is(T == class))
{
	// _d_newclass now use default GC alignment (looks like (void*).sizeof * 2 for
	// small objects). We will just use the maximum of filed alignments.
	alias alignment = classInstanceAlignment!T;
	alias aligned = _alignUp!alignment;
	
	static struct Scoped
	{
		// Addition of `alignment` is required as `Scoped_store` can be misaligned in memory.
		private void[aligned(__traits(classInstanceSize, T) + size_t.sizeof) + alignment] Scoped_store = void;
		
		@property inout(T) opStar() inout
		{
			void* alignedStore = cast(void*) aligned(cast(size_t) Scoped_store.ptr);
			// As `Scoped` can be unaligned moved in memory class instance should be moved accordingly.
			immutable size_t d = alignedStore - Scoped_store.ptr;
			size_t* currD = cast(size_t*) &Scoped_store[$ - size_t.sizeof];
			if(d != *currD)
			{
				import core.stdc.string;
				memmove(alignedStore, Scoped_store.ptr + *currD, __traits(classInstanceSize, T));
				*currD = d;
			}
			return cast(inout(T)) alignedStore;
		}
		alias opStar this;
		
		@disable this();
		@disable this(this);
		
		~this()
		{
			// `destroy` will also write .init but we have no functions in druntime
			// for deterministic finalization and memory releasing for now.
			.destroy(opStar);
		}
	}
	
	/// Returns the scoped object
	@system auto scoped(Args...)(auto ref Args args)
	{
		import std.conv : emplace;
		
		Scoped result = void;
		void* alignedStore = cast(void*) aligned(cast(size_t) result.Scoped_store.ptr);
		immutable size_t d = alignedStore - result.Scoped_store.ptr;
		*cast(size_t*) &result.Scoped_store[$ - size_t.sizeof] = d;
		emplace!(Unqual!T)(result.Scoped_store[d .. $ - size_t.sizeof], args);
		return result;
	}
}