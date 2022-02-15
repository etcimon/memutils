/**
    Defines a string based dictionary list with conserved insertion order.

    Copyright: © 2012-2014 RejectedSoftware e.K.
    License: Subject to the terms of the MIT license, as written in the included LICENSE file.
    Authors: Sönke Ludwig
*/
module memutils.dictionarylist;

import memutils.helpers;
import memutils.allocators;
import memutils.refcounted;
import memutils.utils;
import memutils.vector;

nothrow:
@trusted:
alias DictionaryListRef(KEY, VALUE, ALLOC = ThreadMem, bool case_sensitive = true, size_t NUM_STATIC_FIELDS = 8) = RefCounted!(DictionaryList!(KEY, VALUE, ALLOC, case_sensitive, NUM_STATIC_FIELDS), ALLOC);

/**
 * 
    Behaves similar to $(D VALUE[string]) but the insertion order is not changed
    and multiple values per key are supported.
    
    Note that despite case not being relevant for matching keys, iterating
    over the list will yield the original case of the key that was put in.

    Insertion and lookup has O(n) complexity.
*/
struct DictionaryList(KEY, VALUE, ALLOC = ThreadMem, bool case_sensitive = true, size_t NUM_STATIC_FIELDS = 8) {
	nothrow:
	@trusted:
	@disable this(this);

	import std.typecons : Tuple;
	
	private {
		static struct Field { uint keyCheckSum; KEY key; VALUE value; }
		Field[NUM_STATIC_FIELDS] m_fields;
		size_t m_fieldCount;
		Field[] m_extendedFields;
		size_t m_extendedFieldCount;
	}

	~this() {
		if (m_extendedFields) {
			auto sz = m_extendedFields.length;
			freeArray!(Field, ALLOC)(m_extendedFields.ptr[0 .. m_extendedFieldCount], sz);
		}
	}
	
	alias KeyType = KEY;
	alias ValueType = VALUE;
	
	struct FieldTuple { KeyType key; ValueType value; }

	@property bool empty() const { return length == 0; }

	/** The number of fields present in the map.
    */
	@property size_t length() const { return m_fieldCount + m_extendedFields.length; }
	
	/** Removes the first field that matches the given key.
    */
	void remove(KeyType key)
	{
		auto keysum = computeCheckSumI(key);
		auto idx = getIndex(m_fields[0 .. m_fieldCount], key, keysum);
		if( idx >= 0 ){
			auto slice = m_fields[0 .. m_fieldCount];
			removeFromArrayIdx(slice, idx);
			m_fieldCount--;
		} else {
			idx = getIndex(m_extendedFields, key, keysum);
			if (idx < 0) return;
			removeFromArrayIdx(m_extendedFields, idx);
		}
	}
	
	/** Removes all fields that matches the given key.
    */
	void removeAll(KeyType key)
	{
		auto keysum = computeCheckSumI(key);
		for (size_t i = 0; i < m_fieldCount;) {
			if (m_fields[i].keyCheckSum == keysum && matches(m_fields[i].key, key)) {
				auto slice = m_fields[0 .. m_fieldCount];
				removeFromArrayIdx(slice, i);
				m_fieldCount--;
			} else i++;
		}
		
		for (size_t i = 0; i < m_extendedFields.length;) {
			if (m_extendedFields[i].keyCheckSum == keysum && matches(m_extendedFields[i].key, key))
				removeFromArrayIdx(m_extendedFields, i);
			else i++;
		}
	}
	
	/** Adds a new field to the map.

        The new field will be added regardless of any existing fields that
        have the same key, possibly resulting in duplicates. Use opIndexAssign
        if you want to avoid duplicates.
    */
	void insert()(auto const ref KeyType key, ValueType value)
	{
		auto keysum = computeCheckSumI(key);
		if (m_fieldCount < m_fields.length) {
			m_fields[m_fieldCount++] = Field(keysum, *cast(KeyType*) &key, value);
		}
		else {
			grow(1);
			m_extendedFields[$-1] = Field(keysum, *cast(KeyType*) &key, value);
		}
	}
	
	/** Returns the first field that matches the given key.

        If no field is found, def_val is returned.
    */
	ValueType get(KeyType key, ValueType def_val = ValueType.init) {
		if (auto pv = key in this) return *pv;
		return def_val;
	}
	
	const(ValueType) get(in KeyType key, const(ValueType) def_val = const(ValueType).init) const
	{
		if (auto pv = key in this) return *pv;
		return def_val;
	}
	
	/** Returns all values matching the given key.

        Note that the version returning an array will allocate using the same allocator for each call.
    */
	Vector!(ValueType, ALLOC) getValuesAt()(auto const ref KeyType key)
	const {
		auto ret = Vector!(ValueType, ALLOC)(0);
		this.opApply( (k, const ref v) {
				// static if (is(ValueType == string)) logTrace("Checking field: ", v);
				//logTrace("Looping ", k, " => ", v);
				if (matches(key, k)) {
					//logTrace("Appending: ", v);
					ret ~= v;
				}
				return 0;
			});
		//logTrace("Finished getValuesAt with: ", ret[]);
		return ret.move();
	}
	
	/// ditto
	void getValuesAt(in KeyType key, scope void delegate(const(ValueType)) nothrow del)
	const {
		uint keysum = computeCheckSumI(key);
		foreach (ref f; m_fields[0 .. m_fieldCount]) {
			if (f == Field.init) continue;
			if (f.keyCheckSum != keysum) continue;
			if (matches(f.key, key)) del(f.value);
		}
		foreach (ref f; m_extendedFields) {
			if (f.keyCheckSum != keysum) continue;
			if (matches(f.key, key)) del(f.value);
		}
	}
	/** Returns the first value matching the given key.
    */
	inout(ValueType) opIndex(KeyType key)
	inout {
		auto pitm = key in this;
		if (pitm is null) return "?";
		return *pitm;
	}
	
	/** Adds or replaces the given field with a new value.
    */
	ValueType opIndexAssign(ValueType val, KeyType key)
	{
		auto pitm = key in this;
		if( pitm ) *pitm = val;
		else if( m_fieldCount < m_fields.length ) m_fields[m_fieldCount++] = Field(computeCheckSumI(key), key, val);
		else {
			grow(1);
			m_extendedFields[$-1] = Field(computeCheckSumI(key), key, val);
		}
		return val;
	}
	
	/** Returns a pointer to the first field that matches the given key.
    */
	inout(ValueType)* opBinaryRight(string op)(in KeyType key) inout if(op == "in") {
		return find(key);
	}
	
	inout(ValueType)* find(in KeyType key) inout 
	{
		uint keysum = computeCheckSumI(key);
		auto idx = getIndex(m_fields[0 .. m_fieldCount], key, keysum);
		if( idx >= 0 ) return &m_fields[idx].value;
		idx = getIndex(m_extendedFields, key, keysum);
		if( idx >= 0 ) return &m_extendedFields[idx].value;
		return null;
	}
	
	/// ditto
	bool opBinaryRight(string op)(KeyType key) inout if(op == "!in") {
		return !(key in this);
	}
	
	/** Iterates over all fields, including duplicates.
    */
	int opApply(int delegate(KeyType key, ref ValueType val) nothrow del)
	{
		foreach (ref kv; m_fields[0 .. m_fieldCount]) {
			if (kv == Field.init) return 0;
			if (auto ret = del(kv.key, kv.value))
				return ret;
		}
		foreach (ref kv; m_extendedFields) {
			if (auto ret = del(kv.key, kv.value))
				return ret;
		}
		return 0;
	}
	
	int opApply(int delegate(const ref KeyType key, const ref ValueType val) nothrow del) const
	{
		foreach (ref kv; m_fields[0 .. m_fieldCount]) {
			if (kv == Field.init) return 0;
			if (auto ret = del(kv.key, kv.value))
				return ret;
		}
		foreach (ref kv; m_extendedFields) {
			if (auto ret = del(kv.key, kv.value))
				return ret;
		}
		return 0;
	}
	
	/// ditto
	int opApply(int delegate(ref ValueType val) nothrow del)
	{
		return this.opApply((KeyType key, ref ValueType val) { return del(val); });
	}
	
	/// ditto
	int opApply(int delegate(KeyType key, ref const(ValueType) val) del) const
	{
		return (cast() this).opApply(cast(int delegate(KeyType, ref ValueType) nothrow) del);
	}
	
	/// ditto
	int opApply(int delegate(ref const(ValueType) val) del) const
	{
		return (cast() this).opApply(cast(int delegate(ref ValueType) nothrow) del);
	}

	bool opEquals(const ref DictionaryList!(KEY, VALUE, ALLOC) other) const
	{
		foreach (const ref KeyType key, const ref ValueType val; this)
		{
			bool found;
			other.getValuesAt(key, (const ValueType oval) {
					if (oval == val) {
						found = true;
						return;
					}
				});
			if (!found)
				return false;
		}
		
		return true;
	}

	private void grow(size_t n) {
		if (m_extendedFields.length + n < m_extendedFieldCount) {
			m_extendedFields = m_extendedFields.ptr[0 .. m_extendedFields.length + n];
			return;
		}
		if (m_extendedFields.length > 0)
		{
			size_t oldsz = m_extendedFields.length;
			m_extendedFields = m_extendedFields.ptr[0 .. m_extendedFieldCount];
			m_extendedFieldCount = (m_extendedFieldCount + n)*3/2;
			m_extendedFields = reallocArray!(Field, ALLOC)(m_extendedFields, m_extendedFieldCount)[0 .. oldsz + n];
			memset(m_extendedFields.ptr + oldsz, 0, (m_extendedFieldCount-oldsz)*Field.sizeof);
		}
		else {
			m_extendedFieldCount = 16;
			m_extendedFields = allocArray!(Field, ALLOC)(16).ptr[0 .. n];
			memset(m_extendedFields.ptr, 0, m_extendedFieldCount*Field.sizeof);
		}
	}

	private ptrdiff_t getIndex(in Field[] map, in KeyType key, uint keysum)
	const {
		foreach (i, ref const(Field) entry; map) {
			if (entry.keyCheckSum != keysum) continue;
			if (matches(entry.key, key)) return i;
		}
		return -1;
	}
	
	private static bool matches(in KeyType a, in KeyType b)
	{
		static if (case_sensitive) return a == b;
		else static if (is (KeyType == string)) return icmp2(a, b) == 0;
		else return a == b;
	}
	
	// very simple check sum function with a good chance to match
	// strings with different case equal
	private static uint computeCheckSumI(string s)
	@trusted {
		uint csum = 0;
		immutable(char)* pc = s.ptr, pe = s.ptr + s.length;
		for (; pc != pe; pc++) {
			static if (case_sensitive) csum ^= *pc;
			else csum ^= *pc & 0x1101_1111;
			csum = (csum << 1) | (csum >> 31);
		}
		return csum;
	}
	
	private static uint computeCheckSumI(T)(ref T obj)
	@trusted {
		return cast(uint)hashOf(obj, 0);
	}
}

private:
nothrow:
void removeFromArrayIdx(T)(ref T[] array, size_t idx)
{
	foreach( j; idx+1 .. array.length) { 
		array[j-1] = array[j];
	}
	array[array.length-1].destructRecurse();
	array = array.ptr[0 .. array.length-1];
}
/* =================== Decode ======================= */

/***************
 * Decodes and returns character starting at s[idx]. idx is advanced past the
 * decoded character. If the character is not well formed, a UtfException is
 * thrown and idx remains unchanged.
 */
 @safe @nogc pure nothrow
bool isValidDchar(dchar c)
{
    /* Note: FFFE and FFFF are specifically permitted by the
     * Unicode standard for application internal use, but are not
     * allowed for interchange.
     * (thanks to Arcane Jill)
     */

    return c < 0xD800 ||
        (c > 0xDFFF && c <= 0x10FFFF /*&& c != 0xFFFE && c != 0xFFFF*/);
}

@safe pure nothrow
dchar decode(const scope char[] s, ref size_t idx)
    in
    {
        assert(idx >= 0 && idx < s.length);
    }
    out (result)
    {
        assert(isValidDchar(result));
    }
    do
    {
        size_t len = s.length;
        dchar V;
        size_t i = idx;
        char u = s[i];

        if (u & 0x80)
        {   uint n;
            char u2;

            /* The following encodings are valid, except for the 5 and 6 byte
             * combinations:
             *  0xxxxxxx
             *  110xxxxx 10xxxxxx
             *  1110xxxx 10xxxxxx 10xxxxxx
             *  11110xxx 10xxxxxx 10xxxxxx 10xxxxxx
             *  111110xx 10xxxxxx 10xxxxxx 10xxxxxx 10xxxxxx
             *  1111110x 10xxxxxx 10xxxxxx 10xxxxxx 10xxxxxx 10xxxxxx
             */
            for (n = 1; ; n++)
            {
                if (n > 4)
                    goto Lerr;          // only do the first 4 of 6 encodings
                if (((u << n) & 0x80) == 0)
                {
                    if (n == 1)
                        goto Lerr;
                    break;
                }
            }

            // Pick off (7 - n) significant bits of B from first byte of octet
            V = cast(dchar)(u & ((1 << (7 - n)) - 1));

            if (i + (n - 1) >= len)
                goto Lerr;                      // off end of string

            /* The following combinations are overlong, and illegal:
             *  1100000x (10xxxxxx)
             *  11100000 100xxxxx (10xxxxxx)
             *  11110000 1000xxxx (10xxxxxx 10xxxxxx)
             *  11111000 10000xxx (10xxxxxx 10xxxxxx 10xxxxxx)
             *  11111100 100000xx (10xxxxxx 10xxxxxx 10xxxxxx 10xxxxxx)
             */
            u2 = s[i + 1];
            if ((u & 0xFE) == 0xC0 ||
                (u == 0xE0 && (u2 & 0xE0) == 0x80) ||
                (u == 0xF0 && (u2 & 0xF0) == 0x80) ||
                (u == 0xF8 && (u2 & 0xF8) == 0x80) ||
                (u == 0xFC && (u2 & 0xFC) == 0x80))
                goto Lerr;                      // overlong combination

            for (uint j = 1; j != n; j++)
            {
                u = s[i + j];
                if ((u & 0xC0) != 0x80)
                    goto Lerr;                  // trailing bytes are 10xxxxxx
                V = (V << 6) | (u & 0x3F);
            }
            if (!isValidDchar(V))
                goto Lerr;
            i += n;
        }
        else
        {
            V = cast(dchar) u;
            i++;
        }

        idx = i;
        return V;

      Lerr:
      return '?';
    //return V; // dummy return
    }
/// Special version of icmp() with optimization for ASCII characters
int icmp2(in string a, in string b)
@safe pure {
	size_t i = 0, j = 0;
	
	// fast skip equal prefix
	size_t min_len = min(a.length, b.length);
	while ( i < min_len && a[i] == b[i] ) i++;
	if( i > 0 && (a[i-1] & 0x80) ) i--; // don't stop half-way in a UTF-8 sequence
	j = i;
	
	// compare the differing character and the rest of the string
	while (i < a.length && j < b.length){
		uint ac = cast(uint)a[i];
		uint bc = cast(uint)b[j];
		if( !((ac | bc) & 0x80) ){
			i++;
			j++;
			if( ac >= 'A' && ac <= 'Z' ) ac += 'a' - 'A';
			if( bc >= 'A' && bc <= 'Z' ) bc += 'a' - 'A';
			if( ac < bc ) return -1;
			else if( ac > bc ) return 1;
		} else {
			dchar acp = decode(a, i);
			dchar bcp = decode(b, j);
			if( acp != bcp ){
				import std.string : toLower;
				acp = toLower(acp);
				bcp = toLower(bcp);
				if( acp < bcp ) return -1;
				else if( acp > bcp ) return 1;
			}
		}
	}
	
	if( i < a.length ) return 1;
	else if( j < b.length ) return -1;
	
	assert(i == a.length || j == b.length, "Strings equal but we didn't fully compare them!?");
	return 0;
}
