/**
 * Copyright (c) 2026 Jeffrey Jonathan Jennings
 *
 * @author Jeffrey Jonathan Jennings (J3)
 *
 *
 */
package scalar_udf;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;

import org.apache.flink.table.functions.FunctionContext;
import org.apache.flink.table.functions.ScalarFunction;

/**
 * A Flink scalar user-defined function (UDF) that computes a stable
 * <b>deduplication key</b> (a.k.a. idempotency key) from the business-level
 * fields of an event.
 *
 * <p>Streaming pipelines deliver duplicate records constantly ─ at-least-once
 * Kafka delivery, source replay after job restart, client-side retries that
 * did not de-duplicate themselves, upstream systems that re-emit on recovery.
 * An <i>idempotency key</i> is a deterministic fingerprint of the logical
 * event (not its transport envelope) so that a downstream operator can ask
 * "have I already processed this?" and safely skip on a yes. The classic
 * Flink pattern uses {@code ROW_NUMBER() OVER (PARTITION BY dedup_key …)} or
 * keyed-state membership checks against such a key.
 *
 * <h3>What the key must guarantee</h3>
 * <ul>
 *   <li><b>Stable across retries</b> ─ the same logical event produces the
 *       same key, even if delivered via a different partition, offset, or
 *       broker.</li>
 *   <li><b>Distinct across different events</b> ─ two events that differ in
 *       <i>any</i> of their business fields must produce different keys.</li>
 *   <li><b>Computed from payload, not from transport metadata</b> ─ Kafka
 *       offsets, ingestion timestamps, and partition numbers differ on
 *       retry and must be excluded from the key.</li>
 * </ul>
 *
 * <h3>Encoding</h3>
 * The function hashes each field with a <b>4-byte big-endian length prefix</b>
 * followed by the UTF-8 bytes of the field, then emits the SHA-256 hex
 * digest. A {@code null} field is encoded as the prefix {@code 0xFFFFFFFF}
 * ({@code -1}) with no following bytes, making it distinct from the empty
 * string (prefix {@code 0x00000000} with zero following bytes).
 *
 * <p>The length-prefix scheme is chosen deliberately over a naive separator
 * (e.g. joining fields with {@code 0x1F}) because a separator-based scheme
 * collides when a field <i>contains</i> the separator byte:
 *
 * <pre>{@code
 *   ["a|b", "c"]  →  "a|b|c"   // with separator '|'
 *   ["a", "b|c"]  →  "a|b|c"   // same hash — COLLISION
 * }</pre>
 *
 * Length-prefix encoding is unambiguous no matter what bytes appear inside
 * the fields, so two different field lists can never hash to the same key.
 *
 * <h3>Input handling</h3>
 * <ul>
 *   <li>{@code NULL} array ⇒ {@code NULL} output.</li>
 *   <li>Empty array ⇒ {@code NULL} output. A dedup key derived from zero
 *       fields would be a single global constant, almost certainly a bug.</li>
 *   <li>Array containing some {@code NULL} elements ⇒ those elements are
 *       encoded distinctly from empty strings and participate in the hash.</li>
 *   <li>Field values are <b>not</b> normalized (no trim, no case-folding).
 *       If two source systems emit {@code "ORDER-123"} and {@code "order-123"}
 *       for the same logical event, that is a data-contract concern to fix
 *       upstream; canonicalize before calling this UDF if loose matching is
 *       intended.</li>
 * </ul>
 *
 * <h3>SQL invocation</h3>
 * <pre>{@code
 * CREATE FUNCTION dedup_key
 *     AS 'scalar_udf.DedupKey'
 *     LANGUAGE JAVA;
 *
 * -- Step 1: compute a stable idempotency key from payload fields only,
 * --         then dedupe by keeping the earliest occurrence of each key.
 * INSERT INTO orders_clean
 * SELECT *
 *   FROM (
 *     SELECT dedup_key(ARRAY[
 *              source_system,
 *              event_type,
 *              CAST(business_id  AS STRING),
 *              CAST(occurred_at  AS STRING)
 *            ]) AS idempotency_key,
 *            *,
 *            ROW_NUMBER() OVER (
 *              PARTITION BY dedup_key(ARRAY[
 *                source_system, event_type,
 *                CAST(business_id AS STRING),
 *                CAST(occurred_at AS STRING)
 *              ])
 *              ORDER BY event_ts
 *            ) AS rn
 *       FROM orders_raw
 *   )
 *  WHERE rn = 1;
 * }</pre>
 */
public class DedupKey extends ScalarFunction {

    private static final String ALGORITHM = "SHA-256";
    private static final int NULL_LENGTH_MARKER = -1;

    private transient MessageDigest digest;

    /**
     * Initializes the {@link MessageDigest} instance once per task slot.
     * {@code MessageDigest} is not thread-safe but is cheap to reset between
     * calls; Flink invokes {@code eval} from a single task thread per parallel
     * instance, so caching one instance is both correct and efficient.
     *
     * @param context the function context supplied by the Flink runtime
     * @throws NoSuchAlgorithmException if the JVM does not provide SHA-256
     *         (every standards-compliant JRE does)
     */
    @Override
    public void open(FunctionContext context) throws NoSuchAlgorithmException {
        digest = MessageDigest.getInstance(ALGORITHM);
    }

    /**
     * Computes the deduplication key for a list of business-level fields.
     *
     * <p>Flink discovers scalar UDF logic by reflecting on public {@code eval}
     * methods, so the method name and visibility must remain as declared.
     *
     * @param fields the business fields that uniquely identify the logical
     *               event; may be {@code null} to represent a SQL
     *               {@code NULL} {@code ARRAY} value, and individual
     *               elements may be {@code null}
     * @return a 64-character lower-case hex string representing the SHA-256
     *         of the length-prefix-encoded field sequence; or {@code null}
     *         if {@code fields} is {@code null} or empty
     */
    public String eval(String[] fields) {
        if (fields == null || fields.length == 0)
            return null;

        digest.reset();
        for (String field : fields) {
            if (field == null) {
                writeInt(NULL_LENGTH_MARKER);
            } else {
                byte[] bytes = field.getBytes(StandardCharsets.UTF_8);
                writeInt(bytes.length);
                digest.update(bytes);
            }
        }
        return toHex(digest.digest());
    }

    private void writeInt(int n) {
        digest.update((byte) (n >>> 24));
        digest.update((byte) (n >>> 16));
        digest.update((byte) (n >>> 8));
        digest.update((byte) n);
    }

    private static String toHex(byte[] bytes) {
        char[] hex = new char[bytes.length * 2];
        for (int i = 0; i < bytes.length; i++) {
            int v = bytes[i] & 0xFF;
            hex[i * 2]     = Character.forDigit(v >>> 4, 16);
            hex[i * 2 + 1] = Character.forDigit(v & 0x0F, 16);
        }
        return new String(hex);
    }
}
