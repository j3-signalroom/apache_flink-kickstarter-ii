/**
 * Copyright (c) 2026 Jeffrey Jonathan Jennings
 *
 * @author Jeffrey Jonathan Jennings (J3)
 *
 *
 */
package scalar_udf;

import java.nio.charset.StandardCharsets;

import org.apache.flink.table.functions.ScalarFunction;

/**
 * A Flink scalar user-defined function (UDF) that maps a string key to a
 * non-negative bucket index in the range {@code [0, numBuckets)} using the
 * same hash function Kafka's default partitioner uses.
 *
 * <p>"Consistent" here means <b>cross-system consistent</b>: given the same
 * key and the same {@code numBuckets}, this UDF produces the same bucket
 * that Kafka's producer would have chosen for the same partition count,
 * because both use the 32-bit {@code murmur2} variant from
 * {@code org.apache.kafka.common.utils.Utils#murmur2(byte[])}. That makes
 * it the right tool whenever Flink output needs to land on the same Kafka
 * partition, database shard, or cache slot as upstream or downstream
 * systems that follow the Kafka convention.
 *
 * <h3>When to use which hash</h3>
 * There is no universal "best" partition hash — pick the one that matches
 * the system you need to co-partition with:
 * <ul>
 *   <li><b>Kafka producer / consumer</b>, most JVM streaming tools ⇒
 *       {@code murmur2} (this UDF).</li>
 *   <li>Spark {@code HashPartitioner} ⇒ Java {@code Object.hashCode()} —
 *       <i>not</i> portable and biased on short sequential strings; avoid
 *       for cross-system work.</li>
 *   <li>Some CDC / log-compaction consumers ⇒ {@code murmur3} 32-bit —
 *       similar name, different constants; the two are not
 *       interchangeable.</li>
 *   <li>Cryptographic or security-sensitive bucketing (e.g. preventing
 *       adversarial hot-spotting) ⇒ HMAC-SHA256 truncated. Slower, not
 *       needed for ordinary partitioning.</li>
 * </ul>
 *
 * <h3>Example use cases</h3>
 * <ul>
 *   <li><b>Kafka co-partitioning</b> — keep Flink sinks aligned with the
 *       producer-side partition count so downstream joiners see paired
 *       events on the same partition without a repartition step.</li>
 *   <li><b>Database / cache sharding</b> — route keyed writes to shard
 *       {@code consistent_bucket(customer_id, shard_count)} so the same
 *       customer always lands on the same shard.</li>
 *   <li><b>Deterministic A/B cohort assignment</b> — bucket users into
 *       100 slots and treat {@code < 10} as the treatment arm; the
 *       assignment is stable across job restarts and across services.</li>
 *   <li><b>Streaming reservoir sampling at fixed rate</b> —
 *       {@code WHERE consistent_bucket(event_id, 100) < 5} keeps ~5 % of
 *       events deterministically (same {@code event_id} is always
 *       sampled or always dropped).</li>
 * </ul>
 *
 * <h3>Null semantics</h3>
 * <ul>
 *   <li>{@code key = NULL} ⇒ output is {@code NULL}. Matches Kafka's
 *       behavior of round-robin-ing null-keyed records rather than
 *       assigning them a deterministic partition; callers who need a
 *       stable bucket for absent keys should substitute a sentinel
 *       upstream.</li>
 *   <li>{@code numBuckets = NULL} ⇒ output is {@code NULL}.</li>
 *   <li>{@code numBuckets ≤ 0} ⇒ throws {@link IllegalArgumentException};
 *       a configuration error, not a data error.</li>
 * </ul>
 *
 * <h3>SQL invocation</h3>
 * <pre>{@code
 * CREATE FUNCTION consistent_bucket
 *     AS 'scalar_udf.ConsistentBucket'
 *     LANGUAGE JAVA;
 *
 * -- Route rows into the same partitions Kafka's producer would have:
 * INSERT INTO orders_kafka /*+ OPTIONS('sink.partitioner'='round-robin') *\/
 * SELECT consistent_bucket(customer_id, 32) AS target_partition,
 *        *
 *   FROM orders_stream;
 *
 * -- Deterministic 10% traffic sample:
 * SELECT *
 *   FROM clickstream
 *  WHERE consistent_bucket(user_id, 100) < 10;
 * }</pre>
 */
public class ConsistentBucket extends ScalarFunction {

    // murmur2 constants, verbatim from
    // org.apache.kafka.common.utils.Utils#murmur2(byte[])
    private static final int SEED = 0x9747b28c;
    private static final int M    = 0x5bd1e995;
    private static final int R    = 24;

    /**
     * Computes the bucket index for a key.
     *
     * <p>Flink discovers scalar UDF logic by reflecting on public {@code eval}
     * methods, so the method name and visibility must remain as declared.
     *
     * @param key        the partitioning key; may be {@code null} to represent
     *                   a SQL {@code NULL} value
     * @param numBuckets the total number of buckets / partitions; must be
     *                   positive. May be {@code null} to represent a SQL
     *                   {@code NULL}.
     * @return an integer in the range {@code [0, numBuckets)}, or
     *         {@code null} if either argument is {@code null}
     * @throws IllegalArgumentException if {@code numBuckets} is zero or negative
     */
    public Integer eval(String key, Integer numBuckets) {
        if (key == null || numBuckets == null)
            return null;
        return bucket(key, numBuckets);
    }

    /**
     * Static entry point suitable for direct calls from non-Flink code
     * (tests, batch tooling). Kept public so that parity with the Python
     * port and with Kafka's partitioner can be verified outside the Flink
     * runtime.
     */
    public static int bucket(String key, int numBuckets) {
        if (numBuckets <= 0)
            throw new IllegalArgumentException("numBuckets must be positive, got " + numBuckets);
        int h = murmur2(key.getBytes(StandardCharsets.UTF_8));
        // Kafka's Utils.toPositive: mask the sign bit rather than Math.abs,
        // because Math.abs(Integer.MIN_VALUE) == Integer.MIN_VALUE and would
        // yield a negative modulus.
        return (h & 0x7FFFFFFF) % numBuckets;
    }

    /**
     * 32-bit murmur2 hash, ported verbatim from
     * {@code org.apache.kafka.common.utils.Utils#murmur2(byte[])}. Exposed
     * as {@code static} so the algorithm can be cross-checked against Kafka
     * and against the Python port without instantiating the UDF.
     */
    public static int murmur2(byte[] data) {
        int length = data.length;
        int h = SEED ^ length;
        int length4 = length / 4;

        for (int i = 0; i < length4; i++) {
            final int i4 = i * 4;
            int k = (data[i4]     & 0xff)
                  | ((data[i4 + 1] & 0xff) << 8)
                  | ((data[i4 + 2] & 0xff) << 16)
                  | ((data[i4 + 3] & 0xff) << 24);
            k *= M;
            k ^= k >>> R;
            k *= M;
            h *= M;
            h ^= k;
        }
        switch (length % 4) {
            case 3:
                h ^= (data[(length & ~3) + 2] & 0xff) << 16;
                // fall through
            case 2:
                h ^= (data[(length & ~3) + 1] & 0xff) << 8;
                // fall through
            case 1:
                h ^= (data[length & ~3] & 0xff);
                h *= M;
                break;
            default:
                break;
        }
        h ^= h >>> 13;
        h *= M;
        h ^= h >>> 15;
        return h;
    }
}
