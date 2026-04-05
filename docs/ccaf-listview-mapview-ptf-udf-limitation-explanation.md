## Why `@StateHint` POJO with `Map`/`List` is "extremely large state" sensitive

The root cause is how **`@StateHint` maps to Flink's underlying state primitives**.

### What `@StateHint` actually uses under the hood

When you annotate a POJO with `@StateHint`, Flink backs it with a single **`ValueState<YourPojo>`**. That means the entire POJO — including any `Map` or `List` fields inside it — is treated as one atomic value. A common mistake new developers to Flink might make is having as state a `ValueState<Map<String, Integer>>` while the map entries are intended to only be randomly accessed. In this case, it is definitely better to use `MapState<String, Integer>`, especially because out-of-core state backends such as `RocksDBStateBackend` serialize/deserialize `ValueState` states **completely on every access**, while for `MapState`, serialization occurs **per-entry**.

So a `@StateHint` POJO with a `Map<String, Integer>` field is mechanically equivalent to `ValueState<Map<String, Integer>>` — the entire map gets serialized to bytes and written to RocksDB on every `eval()` call, and deserialized from bytes back to a heap object on every read.

### What `MapView`/`ListView` would give you instead

`MapView` and `ListView` are facades over Flink's native **`MapState`** and **`ListState`** primitives. In RocksDB:
- Each **`MapState` entry** is stored as an independent RocksDB key (`partition_key + map_entry_key → value`). You can look up, update, or delete a single entry without touching the rest.
- Each **`ListState` entry** is similarly stored per-element.

This is why `MapView`/`ListView` are designed for "extremely large" collections — you never materialize the whole thing on the JVM heap. You do surgical point lookups via JNI into RocksDB.

### The concrete hard limit this surfaces

States that use merge operations in RocksDB (e.g. `ListState`) can silently accumulate value sizes > 2^31 bytes and will then fail on their next retrieval. This is currently a limitation of RocksDB JNI. As RocksDB's JNI bridge API is based on `byte[]`, the maximum supported size per value is 2^31 bytes. `MapState` is used as a replacement for `ListState` or `ValueState` in case the records get too big for the RocksDB JNI bridge.

So the hard cliff is **2 GB per serialized value** — if your `@StateHint` POJO's map grows large enough that its serialized form exceeds 2^31 bytes, you get a silent corruption and then a crash on the next read.

### Why Confluent's PTF EA doesn't support `MapView`/`ListView` yet

This is a tracked sub-task: FLINK-37598 — "Support `ListView` and `MapView` in PTFs" — filed by Timo Walther (the FLIP-440 author) to add list state and map state support in PTFs. It wasn't in the original FLIP-440 scope and is a planned addition. The Confluent EA simply reflects the upstream Flink state: `MapView`/`ListView` in PTFs are not yet implemented in Flink itself, let alone wired through Confluent's managed platform.

---

## Summary
When you use `@StateHint` with a POJO containing a `Map` or `List` field, Flink treats the **entire POJO as one single value** in storage. Every time an event arrives, Flink has to:

1. Read the whole thing from RocksDB and deserialize it into memory
2. Let your code make whatever change it needs (maybe just updating one entry)
3. Serialize the whole thing back and write it to RocksDB

So if your map has 10,000 entries and you only need to update one of them, you're still reading and writing all 10,000 entries on every single event.

`MapView` and `ListView` (which aren't supported in PTFs yet) would fix this by storing each map/list entry as its own independent record in RocksDB — so you only touch the one entry you actually need.

The phrase "extremely large state" in the Confluent docs is basically shorthand for: *"at some point your map/list gets big enough that this full serialize/deserialize cycle on every event becomes a real performance problem"* — and there's also a hard technical cliff at 2GB where the whole thing crashes.

---

## Hard limit cliff at 2 GB per serialized value

RocksDB's JNI (Java Native Interface) bridge — the layer that lets Java talk to RocksDB's native C++ code — passes data back and forth as `byte[]` arrays. Java's `byte[]` has a maximum length of `2^31 - 1` bytes (just under 2GB).

So when Flink tries to serialize your entire POJO (including its map or list) into a `byte[]` to hand off to RocksDB, if the serialized result exceeds 2GB, it silently overflows. You don't get an error immediately — the write may appear to succeed. The crash happens on the **next read**, when Flink tries to deserialize the corrupted bytes back into your POJO.

That's what makes it particularly nasty — it's not a clean "your state is too big" error at write time. It's a silent corruption that blows up later, potentially after a checkpoint/restore cycle, making it hard to diagnose.

For a `MapState` or `ListState` (what `MapView`/`ListView` would use), this limit applies **per entry** rather than to the entire collection, so you'd have to have a single map value or list element exceed 2GB to hit it — which is essentially never going to happen in practice.
