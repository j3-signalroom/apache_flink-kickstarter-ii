# Java Scalar User-Defined Function (UDF) examples ─ a tour from unit conversion to cross-system keying

> This package contains **seven scalar UDFs** that together illustrate the simplest and oldest category of Flink user-defined function: a pure, row-at-a-time function callable from SQL. They are grouped into three themes ─ starting with the tiniest possible "Hello, UDF" and building up to the scalar UDFs you are most likely to reach for in a real streaming pipeline.
>
> **Unit-conversion primer** (the "Hello, UDF" pair)
> - **`CelsiusToFahrenheit`** ─ converts a `DOUBLE` Celsius temperature to its Fahrenheit equivalent using `F = (C × 9/5) + 32`.
> - **`FahrenheitToCelsius`** ─ converts a `DOUBLE` Fahrenheit temperature to its Celsius equivalent using `C = (F − 32) × 5/9`.
>
> **PII & data-governance UDFs**
> - **`PseudonymizePii`** ─ deterministic, keyed HMAC-SHA256 pseudonym of a PII value, domain-separated by a namespace argument. Use to hide raw PII from analysts while keeping joins and aggregations stable.
> - **`ResolveIdentity`** ─ un-keyed SHA-256 of a normalized identity signal (email trimmed+lower-cased, phone digits-only, etc.). Use as a portable join key across systems that don't share a secret.
> - **`TokenizePan`** ─ tokenizes a Primary Account Number (PAN) into a `{BIN}{HMAC-hex middle}{last-4}` shape, taking the Flink pipeline out of PCI DSS scope while preserving BIN and last-4 for fraud analytics and reconciliation.
>
> **Pipeline-reliability UDFs**
> - **`DedupKey`** ─ computes a stable idempotency key from an `ARRAY<STRING>` of business-level fields using length-prefix-encoded SHA-256. Use in a `ROW_NUMBER() OVER (PARTITION BY dedup_key …)` pattern to defang at-least-once duplicates.
> - **`ConsistentBucket`** ─ maps a key to `[0, num_buckets)` using Kafka's 32-bit `murmur2` ─ the exact same hash Kafka's default partitioner uses, so Flink output co-partitions with Kafka producers, database shards, and cache slots.
>
> All seven UDFs ship in the same uber JAR and are registered as separate Flink functions from that one artifact. Together they demonstrate how the [`ScalarFunction`](https://nightlies.apache.org/flink/flink-docs-stable/docs/dev/table/functions/udfs/#scalar-functions) API lets you write plain, deterministic Java methods that Flink can call once per input row and inline directly into the query plan ─ no state, no timers, no operator graph surgery required.

**Table of Contents**
<!-- toc -->
+ [**1.0 What is a Scalar UDF?**](#10-what-is-a-scalar-udf)
    + [**1.1 Where scalar UDFs sit in the UDF hierarchy**](#11-where-scalar-udfs-sit-in-the-udf-hierarchy)
    + [**1.2 How Flink discovers and calls a scalar UDF**](#12-how-flink-discovers-and-calls-a-scalar-udf)
    + [**1.3 Determinism and `NULL` handling**](#13-determinism-and-null-handling)
    + [**1.4 One-time setup in `open(FunctionContext)`**](#14-one-time-setup-in-openfunctioncontext)
+ [**2.0 Temperature conversions ─ the "Hello, UDF" pair**](#20-temperature-conversions--the-hello-udf-pair)
    + [**2.1 `CelsiusToFahrenheit`**](#21-celsiustofahrenheit)
    + [**2.2 `FahrenheitToCelsius`**](#22-fahrenheittocelsius)
+ [**3.0 PII & data-governance UDFs**](#30-pii--data-governance-udfs)
    + [**3.1 `PseudonymizePii` ─ irreversibly hide PII while keeping joins intact**](#31-pseudonymizepii--irreversibly-hide-pii-while-keeping-joins-intact)
    + [**3.2 `ResolveIdentity` ─ portable canonical key across partner systems**](#32-resolveidentity--portable-canonical-key-across-partner-systems)
    + [**3.3 `TokenizePan` ─ drop a Flink pipeline out of PCI DSS scope**](#33-tokenizepan--drop-a-flink-pipeline-out-of-pci-dss-scope)
+ [**4.0 Pipeline-reliability UDFs**](#40-pipeline-reliability-udfs)
    + [**4.1 `DedupKey` ─ stable idempotency key for at-least-once streams**](#41-dedupkey--stable-idempotency-key-for-at-least-once-streams)
    + [**4.2 `ConsistentBucket` ─ Kafka-compatible murmur2 partitioning**](#42-consistentbucket--kafka-compatible-murmur2-partitioning)
+ [**5.0 Comparing the UDFs in this package**](#50-comparing-the-udfs-in-this-package)
+ [**6.0 Resources**](#60-resources)
<!-- tocstop -->

## **1.0 What is a Scalar UDF?**

A **Scalar UDF** is a user-defined function that takes zero or more input values from a single row and returns exactly one value. It is the closest Flink equivalent of a built-in SQL function like `UPPER()`, `ABS()`, or `CAST()`: the function sees one row at a time, has no memory of prior rows, and produces exactly one output value per invocation.

### **1.1 Where scalar UDFs sit in the UDF hierarchy**

Flink exposes four categories of user-defined function. Scalar UDFs are the simplest, and most of the heavier categories build on the same reflection-based `eval()` discovery mechanism:

| UDF category | Rows in | Rows out | State | Example use case |
|---|---|---|---|---|
| **Scalar** (this example) | 1 value from 1 row | 1 value | ❌ | Unit conversion, string cleaning, deterministic math, keyed hashing, partitioning |
| Table-valued | 1 row | 0..N rows | ❌ | Exploding a CSV column into multiple rows |
| Aggregate | N rows | 1 value | ✅ | `GEOMEAN()`, weighted median |
| Process Table Function (PTF) | Table argument | 0..N rows | ✅ (set semantics) | Sessionization, stateful enrichment |

Choose a scalar UDF when the computation depends only on the current row's values and can be expressed as a pure function.

### **1.2 How Flink discovers and calls a scalar UDF**

A scalar UDF is a Java class that extends [`org.apache.flink.table.functions.ScalarFunction`](https://nightlies.apache.org/flink/flink-docs-stable/api/java/org/apache/flink/table/functions/ScalarFunction.html) and declares one or more public methods named `eval`. Flink uses reflection to find the `eval` method whose parameter types match the SQL call site, so:

- The method name **must** be `eval` (lower-case).
- The method **must** be `public`.
- You may overload `eval` with different parameter lists; Flink picks the one that matches the SQL invocation.

The simplest class in this package follows the minimal skeleton:

```java
package scalar_udf;

import org.apache.flink.table.functions.ScalarFunction;

public class CelsiusToFahrenheit extends ScalarFunction {
    public Double eval(Double celsius) {
        if (celsius == null) return null;
        return (celsius * 9.0 / 5.0) + 32.0;
    }
}
```

At SQL level, you register the class as a function that points at the uber JAR on the Flink classpath:

```sql
CREATE FUNCTION celsius_to_fahrenheit
    AS 'scalar_udf.CelsiusToFahrenheit'
    USING JAR 'file:///opt/flink/usrlib/scalar-udf.jar';
```

and call it like any built-in scalar function:

```sql
SELECT sensor_id,
       celsius_temperature,
       celsius_to_fahrenheit(celsius_temperature) AS fahrenheit_temperature
  FROM celsius_reading;
```

### **1.3 Determinism and `NULL` handling**

Every UDF in this package is **deterministic**: the same input always produces the same output. Determinism is not just documentation ─ it is a contract that lets the Flink planner safely cache, reorder, and replay calls during failure recovery. For pseudonymization and bucketing, determinism is also what makes joins and `GROUP BY` work on the UDF's output. If you need a non-deterministic scalar UDF (e.g., one that reads the wall clock), override `isDeterministic()` and return `false`.

Every `eval` method also preserves SQL `NULL` semantics by returning `null` when the input is `null`. This keeps the UDF transparent to the rest of the query: a `NULL` stays `NULL` through the pipeline rather than silently becoming a surprise value.

### **1.4 One-time setup in `open(FunctionContext)`**

Several UDFs in this package (`PseudonymizePii`, `TokenizePan`, `ResolveIdentity`, `DedupKey`) override [`open(FunctionContext)`](https://nightlies.apache.org/flink/flink-docs-stable/api/java/org/apache/flink/table/functions/UserDefinedFunction.html#open-org.apache.flink.table.functions.FunctionContext-) to set up state once per parallel subtask before the first `eval()` call. This is where you:

- Load secrets from environment variables (used by `PseudonymizePii` and `TokenizePan`).
- Pre-construct cryptographic primitives (`Mac`, `MessageDigest`) so each row doesn't pay the allocation cost.

Because Flink invokes `eval()` from a single task thread per parallel instance, cached `Mac` / `MessageDigest` instances do not need synchronization ─ they are effectively thread-confined.

---

## **2.0 Temperature conversions ─ the "Hello, UDF" pair**

These two UDFs are the teaching case: the smallest possible shape of a scalar UDF that still does something real. They take a `DOUBLE`, return a `DOUBLE`, have no state, and handle `NULL` the SQL-standard way.

### **2.1 `CelsiusToFahrenheit`**

Applies the standard formula `F = (C × 9/5) + 32`. The `eval` method takes a nullable `Double` and returns a nullable `Double`, so the function plugs in wherever a `DOUBLE` column flows.

Source: [`CelsiusToFahrenheit.java`](app/src/main/java/scalar_udf/CelsiusToFahrenheit.java)

```
Kafka (celsius_reading)
        │
        ▼
  ┌────────────────────┐
  │ celsius_reading    │   Flink SQL source table (JSON / earliest-offset)
  └────────┬───────────┘
           │
           ▼
  celsius_to_fahrenheit(celsius_temperature)    ← stateless scalar call per row
           │
           ▼
  ┌────────────────────────┐
  │ celsius_to_fahrenheit  │   Flink SQL sink table → Kafka (celsius_to_fahrenheit)
  └────────────────────────┘
```

The UDF is invoked once per input row; no keying, no state, no windowing. The Flink planner inlines the call into the scan-and-project pipeline, so throughput is essentially the cost of the arithmetic plus the Kafka I/O.

### **2.2 `FahrenheitToCelsius`**

Applies the inverse formula `C = (F − 32) × 5/9`. Same signature (`Double eval(Double)`), same determinism and `NULL`-preservation guarantees as `CelsiusToFahrenheit` ─ only the arithmetic differs.

Source: [`FahrenheitToCelsius.java`](app/src/main/java/scalar_udf/FahrenheitToCelsius.java)

```
Kafka (fahrenheit_reading)
        │
        ▼
  ┌──────────────────────┐
  │ fahrenheit_reading   │   Flink SQL source table (JSON / earliest-offset)
  └────────┬─────────────┘
           │
           ▼
  fahrenheit_to_celsius(fahrenheit_temperature)   ← stateless scalar call per row
           │
           ▼
  ┌──────────────────────────┐
  │ fahrenheit_to_celsius    │   Flink SQL sink table → Kafka (fahrenheit_to_celsius)
  └──────────────────────────┘
```

---

## **3.0 PII & data-governance UDFs**

These three UDFs cover the overlapping but distinct problems of **hiding PII from analysts**, **resolving the same real-world entity across systems**, and **reducing the PCI DSS blast radius of a Flink pipeline handling payment cards**. They share a common implementation shape ─ they all `open()` once to set up a cryptographic primitive, then hash per row ─ but the design choices differ deliberately:

- Secret or no secret?
- Per-call normalization or raw bytes?
- Hex blob or a structured PAN-shaped output?

The comparison table in [§5](#50-comparing-the-udfs-in-this-package) tabulates those differences.

### **3.1 `PseudonymizePii` ─ irreversibly hide PII while keeping joins intact**

Computes `HMAC-SHA256(secret, namespace || 0x1F || value)` and returns a 64-character hex string. Because the key (pepper) is loaded in `open()` from the `PII_PSEUDONYM_SECRET` environment variable, the raw PII cannot be recovered by anyone who sees only the pseudonymized column ─ yet the same PII always pseudonymizes to the same value, so `JOIN`, `GROUP BY`, and `COUNT DISTINCT` continue to work on the pseudonymized column.

The mandatory `namespace` argument (`'email'`, `'phone'`, `'ssn'`) provides **domain separation**: the same underlying string pseudonymizes to a different value in each namespace, which prevents an analyst from silently linking an email column to a contact-email column in a different table.

Source: [`PseudonymizePii.java`](app/src/main/java/scalar_udf/PseudonymizePii.java)

```sql
CREATE FUNCTION pseudonymize_pii
    AS 'scalar_udf.PseudonymizePii'
    LANGUAGE JAVA;

SELECT pseudonymize_pii('email', email_address) AS email_pseudonym,
       pseudonymize_pii('phone', phone_number)  AS phone_pseudonym,
       order_total
  FROM orders;
```

> **Why HMAC instead of `SHA-256(salt ‖ value)`?** Prepending a fixed salt to a hash is vulnerable to length-extension attacks on Merkle-Damgård hashes like SHA-256. HMAC is specifically designed to resist that. Per-value **random** salts are deliberately *not* used because they would break the join-stability that makes the output useful for analytics.

### **3.2 `ResolveIdentity` ─ portable canonical key across partner systems**

Computes `SHA-256(type || 0x1F || normalized_value)` after normalizing the value per identity type (email → trim+lower-case, phone → digits-only, default → trim+lower-case). The output is a 64-character hex string that two partner systems can derive independently without sharing a secret ─ that is the whole point of the **un-keyed** hash, and the deliberate inverse of the design choice made in `PseudonymizePii`.

The tradeoff: un-keyed means the output is feasible to brute-force if the plaintext domain is small (e.g., all US phone numbers), so a resolved identity key is a **linkage identifier**, not a privacy pseudonym. When you need both portability *and* irreversibility, you need an out-of-band mechanism (e.g., a shared secret via [DCR / clean-room infrastructure](https://docs.snowflake.com/en/user-guide/cleanrooms/overview)).

Source: [`ResolveIdentity.java`](app/src/main/java/scalar_udf/ResolveIdentity.java)

```sql
CREATE FUNCTION resolve_identity
    AS 'scalar_udf.ResolveIdentity'
    LANGUAGE JAVA;

-- Join customers from the CRM to events from the web analytics system
-- using a canonical email-based identity key:
SELECT c.customer_id,
       e.event_name,
       e.event_ts
  FROM crm_customers    c
  JOIN analytics_events e
    ON resolve_identity('email', c.email_address)
     = resolve_identity('email', e.user_email);
```

> **Phone-number caveat:** the UDF's phone rule is "keep digits 0-9", which means `(415) 555-0134` (10 digits) and `+1-415-555-0134` (11 digits) resolve to **different** keys. Country-code inference requires a numbering-plan database like Google's [`libphonenumber`](https://github.com/google/libphonenumber); **E.164-normalize phone values upstream** before passing them to this UDF.

### **3.3 `TokenizePan` ─ drop a Flink pipeline out of PCI DSS scope**

Tokenizes a Primary Account Number (PAN) into a token of the form `{BIN (first 6)}{HMAC-SHA256 hex middle}{last 4}` ─ same length as the input PAN, but the middle digits are replaced with keyed hex characters. A 16-digit PAN `4111111111111111` with an HMAC secret known only to the tokenization service becomes something like `411111a3c92b1111`.

This is **irreversible deterministic tokenization**: the token cannot be converted back to a PAN without the secret (no vault lookup is involved), so downstream systems that hold only tokens fall out of PCI DSS scope. PCI DSS §3.3 permits displaying first-6 and last-4; preserving them keeps fraud models, card-type analytics, and statement-reconciliation UIs working without any code change.

Source: [`TokenizePan.java`](app/src/main/java/scalar_udf/TokenizePan.java)

```sql
CREATE FUNCTION tokenize_pan
    AS 'scalar_udf.TokenizePan'
    LANGUAGE JAVA;

SELECT order_id,
       tokenize_pan(card_number) AS card_token,
       SUBSTRING(tokenize_pan(card_number), 1, 6) AS bin,
       order_total
  FROM orders;
```

> **What this is *not*:** a vault-backed reversible tokenizer. If you need to charge the card later, use your PSP's network-token API ─ those require network I/O and state, which belong in an async function or an external service, not in a scalar UDF. And using this UDF is a necessary-but-not-sufficient PCI step; you still need secret custody, rotation, and network segmentation between the "has PAN" and "has only tokens" zones.

---

## **4.0 Pipeline-reliability UDFs**

These two UDFs address two recurring operational problems in streaming pipelines: **duplicates** (because Kafka is at-least-once and sources get replayed on restart) and **partition skew** (because a sink, shard, or cache has a fixed partition count that upstream and downstream must agree on).

### **4.1 `DedupKey` ─ stable idempotency key for at-least-once streams**

Takes an `ARRAY<STRING>` of the business-level fields that identify a logical event (`source_system`, `event_type`, business id, occurrence time, etc.) and returns a 64-character SHA-256 hex digest of the **length-prefix-encoded** field sequence. The key is stable across retries, replays, and partition changes, so a downstream `ROW_NUMBER() OVER (PARTITION BY dedup_key …)` is all it takes to defang at-least-once duplicates.

The non-obvious design choice is **length-prefix encoding** rather than a naive separator. With a separator like `|`, the two inputs `["a|b", "c"]` and `["a", "b|c"]` would hash to the same key because both concatenate to `a|b|c`. Length-prefix (`[4-byte BE length][UTF-8 bytes]` per field) is unambiguous no matter what bytes appear inside the fields, so two different field lists can never collide.

`NULL` fields are encoded as the length marker `0xFFFFFFFF` with no following bytes, making them distinct from empty strings (`0x00000000` with zero following bytes). The UDF does *not* normalize values (no trim, no case-folding) ─ normalization would hide real bugs from source systems that emit the "same" event with different formatting.

Source: [`DedupKey.java`](app/src/main/java/scalar_udf/DedupKey.java)

```sql
CREATE FUNCTION dedup_key
    AS 'scalar_udf.DedupKey'
    LANGUAGE JAVA;

-- Dedupe by keeping the earliest occurrence of each idempotency key:
INSERT INTO orders_clean
SELECT *
  FROM (
    SELECT dedup_key(ARRAY[
             source_system,
             event_type,
             CAST(business_id AS STRING),
             CAST(occurred_at AS STRING)
           ]) AS idempotency_key,
           *,
           ROW_NUMBER() OVER (
             PARTITION BY dedup_key(ARRAY[
               source_system, event_type,
               CAST(business_id AS STRING),
               CAST(occurred_at AS STRING)
             ])
             ORDER BY event_ts
           ) AS rn
      FROM orders_raw
  )
 WHERE rn = 1;
```

### **4.2 `ConsistentBucket` ─ Kafka-compatible murmur2 partitioning**

Maps a string key to a non-negative bucket index in `[0, num_buckets)` using the **same** 32-bit `murmur2` hash that Kafka's default partitioner uses (`org.apache.kafka.common.utils.Utils#murmur2`). Because both implementations produce byte-identical output for the same input, a Flink-computed bucket always matches the Kafka-producer partition for the same key and partition count.

"Consistent" here means **cross-system consistent**, not "consistent hashing" in the Karger / Dynamo sense. There is no universal best partition hash ─ the right hash is the one that matches the system you need to co-partition with. For Kafka producers and most JVM streaming tools, that is `murmur2`.

Source: [`ConsistentBucket.java`](app/src/main/java/scalar_udf/ConsistentBucket.java)

```sql
CREATE FUNCTION consistent_bucket
    AS 'scalar_udf.ConsistentBucket'
    LANGUAGE JAVA;

-- Database shard routing: same customer always lands on the same shard
INSERT INTO orders_shard_0
SELECT * FROM orders_stream
 WHERE consistent_bucket(CAST(customer_id AS STRING), 16) = 0;

-- Deterministic 10% A/B test cohort (same user_id always in the same arm)
SELECT *
  FROM clickstream
 WHERE consistent_bucket(user_id, 100) < 10;

-- Deterministic ~5% sampling (same event_id always sampled or always dropped)
SELECT *
  FROM raw_events
 WHERE consistent_bucket(event_id, 100) < 5;
```

> **Hash compatibility is strict:** Kafka's `murmur2` is *not* interchangeable with `murmur3`, with Spark's `HashPartitioner` (which uses Java `Object.hashCode()`), or with Guava's `Hashing.murmur3_32()`. Those hashes share a name or a family, but their constants differ and they produce different bucket assignments. If your target system isn't Kafka, verify which hash it uses before relying on this UDF for co-partitioning.

---

## **5.0 Comparing the UDFs in this package**

All seven classes share the same scalar-UDF contract; the table below tabulates where their design choices diverge.

| UDF | Input signature | Output | Keyed? | Reversible? | Primary purpose |
|---|---|---|---|---|---|
| `CelsiusToFahrenheit` | `Double` | `Double` | N/A | Yes (inverse UDF) | Unit conversion |
| `FahrenheitToCelsius` | `Double` | `Double` | N/A | Yes (inverse UDF) | Unit conversion |
| `PseudonymizePii` | `(String namespace, String value)` | `String` (64-char hex) | ✅ HMAC-SHA256 | ❌ | Irreversibly hide PII from analysts |
| `ResolveIdentity` | `(String type, String raw)` | `String` (64-char hex) | ❌ SHA-256 | ❌ (but brute-forceable in small domains) | Portable join key across partner systems |
| `TokenizePan` | `String pan` | `String` (PAN-shaped) | ✅ HMAC-SHA256 | ❌ | PCI DSS scope reduction |
| `DedupKey` | `String[] fields` | `String` (64-char hex) | ❌ SHA-256 | ❌ | Idempotency key for at-least-once streams |
| `ConsistentBucket` | `(String key, Integer numBuckets)` | `Integer` `[0, N)` | ❌ murmur2 | ❌ | Kafka-compatible partitioning / bucketing |

Cross-cutting contract every UDF honors:

| Aspect | Value |
|---|---|
| Base class | `org.apache.flink.table.functions.ScalarFunction` |
| `eval` method name / visibility | `eval`, `public` |
| State | None |
| Determinism | Deterministic (default) |
| `NULL` input → | `NULL` output |
| Rows in → rows out | 1 → 1 |
| SQL registration | `CREATE FUNCTION <name> AS 'scalar_udf.<ClassName>' USING JAR …` |

All seven UDFs compile into the same uber JAR (`app-1.0.0-SNAPSHOT.jar`, produced by `./gradlew shadowJar`) and are registered as separate Flink functions via `CREATE FUNCTION ... USING JAR` statements that point to the same artifact but reference different fully-qualified class names.

---

## **6.0 Resources**
- [Apache Flink User-defined Functions](https://nightlies.apache.org/flink/flink-docs-stable/docs/dev/table/functions/udfs/)
- [Apache Flink Scalar Functions](https://nightlies.apache.org/flink/flink-docs-stable/docs/dev/table/functions/udfs/#scalar-functions)
- [Create a User-Defined Function with Confluent Cloud for Apache Flink](https://docs.confluent.io/cloud/current/flink/how-to-guides/create-udf.html)
- [RFC 2104: HMAC ─ Keyed-Hashing for Message Authentication](https://www.rfc-editor.org/rfc/rfc2104) (algorithm behind `PseudonymizePii` and `TokenizePan`)
- [PCI DSS v4.0 §3.3 ─ PAN Display](https://www.pcisecuritystandards.org/document_library/) (rationale for the first-6 + last-4 format in `TokenizePan`)
- [ITU-T E.164 ─ The international public telecommunication numbering plan](https://www.itu.int/rec/T-REC-E.164) (phone normalization contract for `ResolveIdentity`)
- [Apache Kafka `Utils.murmur2`](https://github.com/apache/kafka/blob/trunk/clients/src/main/java/org/apache/kafka/common/utils/Utils.java) (reference implementation `ConsistentBucket` ports verbatim)
