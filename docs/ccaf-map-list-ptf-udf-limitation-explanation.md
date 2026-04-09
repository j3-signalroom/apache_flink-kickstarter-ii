# Why `@StateHint` POJO with `Map` or `List` Are Sensitive to "Extremely Large State"

The issue isn’t just “large state.”

It’s **how that state is physically stored and accessed**.

**Table of Contents**
<!--toc-start-->
- [1.0 What `@StateHint` Really Means Under the Hood](#10-what-statehint-really-means-under-the-hood)
<!--toc-end-->

---

## **1.0 What `@StateHint` Really Means Under the Hood**

When you annotate a POJO with `@StateHint`, Flink backs it with a single **`ValueState<YourPojo>`**. That means the entire POJO — including any `Map` or `List` fields inside it — is treated as one atomic value. 

So, this:

```java
public static class MyState {
    public Map<String, Integer> myMap;
}
```

...is effectively:

```java
ValueState<Map<String, Integer>> myState;
```

**Implication**

Every access becomes:

1. Read entire POJO from [RocksDB](https://rocksdb.org/) (deserialize)
2. Modify one tiny part
3. Write entire POJO back (serialize)

Even if you only update one key in the map, you still pay the cost of the entire structure.

## **2.0 Why This Can Become a Scaling Problem**

States that use merge operations in [RocksDB](https://rocksdb.org/) (e.g. `ListState`) can silently accumulate value sizes > 2^31 bytes and will then fail on their next retrieval. This is currently a limitation of RocksDB JNI. As RocksDB's JNI bridge API is based on `byte[]`, the maximum supported size per value is 2^31 bytes. `MapState` is used as a replacement for `ListState` or `ValueState` in case the records get too big for the RocksDB JNI bridge.

So the hard cliff is **2 GB per serialized value** — if your `@StateHint` POJO's map grows large enough that its serialized form exceeds 2^31 bytes, you get a silent corruption and then a crash on the next read.

#### **2.1 Hard limit cliff at 2 GB per serialized value**

RocksDB's JNI (Java Native Interface) bridge — the layer that lets Java talk to RocksDB's native C++ code — passes data back and forth as `byte[]` arrays. Java's `byte[]` has a maximum length of `2^31 - 1` bytes (just under 2GB).

So when Flink tries to serialize your entire POJO (including its map or list) into a `byte[]` to hand off to RocksDB, if the serialized result exceeds 2GB, it silently overflows. You don't get an error immediately — the write may appear to succeed. The crash happens on the **next read**, when Flink tries to deserialize the corrupted bytes back into your POJO.

That's what makes it particularly nasty — it's not a clean "your state is too big" error at write time. It's a silent corruption that blows up later, potentially after a checkpoint/restore cycle, making it hard to diagnose.

For a `MapState` or `ListState`, this limit applies **per entry** rather than to the entire collection, so you'd have to have a single map value or list element exceed 2GB to hit it — which is essentially never going to happen in practice.

---

## **2.0 The Solution: PTF should use `MapView` and `ListView`**

`MapView` and `ListView` are facades over Flink's native **`MapState`** and **`ListState`** primitives. In RocksDB:
- Each **`MapState` entry** is stored as an independent RocksDB key (`partition_key + map_entry_key → value`). You can look up, update, or delete a single entry without touching the rest.
- Each **`ListState` entry** is similarly stored per-element.

This is why `MapView` and `ListView` are designed for "extremely large" collections — you never materialize the whole thing on the JVM heap. You do surgical point lookups via JNI into RocksDB.

### **2.1 Why Confluent's PTF Early Access doesn't support `MapView` or `ListView` yet**

This is a tracked sub-task: [FLINK-37598 — "Support `ListView` and `MapView` in PTFs"](https://issues.apache.org/jira/browse/FLINK-37598) — filed by Timo Walther (the [FLIP-440](https://cwiki.apache.org/confluence/pages/viewpage.action?pageId=298781093) author) to add list state and map state support in PTFs. It wasn't in the original FLIP-440 scope and is a planned addition. The Confluent Early Access simply reflects the upstream Flink state: `MapView` and `ListView` in PTFs are not yet implemented in Flink itself, let alone wired through Confluent's managed platform.

---

## **3.0 Summary**
When you use `@StateHint` with a POJO containing a `Map` or `List` field, Flink treats the **entire POJO as one single value** in storage. Every time an event arrives, Flink has to:

1. Read the whole thing from RocksDB and deserialize it into memory
2. Let your code make whatever change it needs (maybe just updating one entry)
3. Serialize the whole thing back and write it to RocksDB

So if your map has 10,000 entries and you only need to update one of them, you're still reading and writing all 10,000 entries on every single event.

`MapView` and `ListView` (which aren't supported in PTFs yet) would fix this by storing each map and list entry as its own independent record in RocksDB — so you only touch the one entry you actually need.

The phrase "extremely large state" in the Confluent docs is basically shorthand for: *"at some point your map or list gets big enough that this full serdes cycle on every event becomes a real performance problem"* — and there's also a hard technical cliff at 2GB where the whole thing crashes.
