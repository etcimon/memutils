module memutils.containers.multimap;

import memutils.allocators.allocators;
import memutils.containers.dictionarylist;
import std.conv : to;
import std.exception : enforce;

alias MultiMap(KEY, VALUE, int ALLOC, bool case_sensitive = true, size_t NUM_STATIC_FIELDS = 8) = RefCounted!(DictionaryList!(KEY, VALUE, case_sensitive, NUM_STATIC_FIELDS));
