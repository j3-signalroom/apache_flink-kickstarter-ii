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
 * A Flink scalar user-defined function (UDF) that performs cross-system
 * identity resolution by turning a raw identity signal into a stable,
 * system-agnostic canonical identifier.
 *
 * <p>Given an {@code identity_type} (e.g. {@code "email"}, {@code "phone"},
 * {@code "user_id"}) and a {@code raw_value} as it appears in some source
 * system, the function:
 *
 * <ol>
 *   <li><b>Normalizes</b> the value per type so that superficial formatting
 *       differences ─ {@code "Alice@Example.com "} vs {@code "alice@example.com"},
 *       or {@code "(415) 555-0134"} vs {@code "+1-415-555-0134"} ─ collapse
 *       to the same canonical form.</li>
 *   <li><b>Hashes</b> {@code normalized_type || 0x1F || normalized_value}
 *       with SHA-256 and returns the lower-case hex digest.</li>
 * </ol>
 *
 * <p>The resulting 64-character hex string is the <i>resolved identity key</i>:
 * two rows from different source systems that refer to the same real-world
 * entity produce the same key and can be joined without a shared primary key.
 *
 * <h3>Keyed vs. un-keyed design choice</h3>
 * Unlike {@link PseudonymizePii}, this UDF deliberately uses an <b>un-keyed</b>
 * hash (plain SHA-256, no secret). Identity resolution is about
 * <i>interoperability</i>: partner systems that do not share a secret must
 * still derive the same key for the same underlying entity. The tradeoff is
 * that the output is feasible to brute-force when the plaintext space is
 * small (e.g. all valid US phone numbers), so a resolved identity key should
 * be treated as a <b>linkage identifier</b>, not as a privacy-preserving
 * pseudonym. When the value must be both join-stable <i>and</i> irreversible,
 * use {@link PseudonymizePii} instead.
 *
 * <h3>Normalization rules</h3>
 * <ul>
 *   <li>{@code "email"} ─ trim, then lower-case the entire address.</li>
 *   <li>{@code "phone"} ─ keep only ASCII digits {@code 0-9}; strip
 *       {@code '+'}, spaces, parentheses, dashes, dots, and any non-digit
 *       character. Callers that need country-code prefixing should do so
 *       upstream before invoking the UDF.</li>
 *   <li>Any other {@code identity_type} ─ trim and lower-case.</li>
 * </ul>
 *
 * <h3>SQL invocation</h3>
 * <pre>{@code
 * CREATE FUNCTION resolve_identity
 *     AS 'scalar_udf.ResolveIdentity'
 *     LANGUAGE JAVA;
 *
 * -- Join customers from CRM with events from the web analytics system
 * -- using a canonical email-based identity key:
 * SELECT c.customer_id,
 *        e.event_name,
 *        e.event_ts
 *   FROM crm_customers       c
 *   JOIN analytics_events    e
 *     ON resolve_identity('email', c.email_address)
 *      = resolve_identity('email', e.user_email);
 * }</pre>
 */
public class ResolveIdentity extends ScalarFunction {

    private static final String ALGORITHM = "SHA-256";
    private static final byte TYPE_SEPARATOR = 0x1F;

    private transient MessageDigest digest;

    /**
     * Initializes the {@link MessageDigest} instance once per task slot.
     * {@code MessageDigest} is not thread-safe but is cheap to reset between
     * calls, so caching one instance per parallel subtask avoids per-row
     * allocation on the hot path. Flink invokes {@code eval} from a single
     * task thread per instance, so no additional synchronization is needed.
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
     * Resolves a single identity signal to its canonical hex key.
     *
     * <p>Flink discovers scalar UDF logic by reflecting on public {@code eval}
     * methods, so the method name and visibility must remain as declared.
     *
     * @param identityType a short label identifying the kind of identifier
     *                     (e.g. {@code "email"}, {@code "phone"},
     *                     {@code "user_id"}); must not be {@code null}. The
     *                     type is lower-cased and trimmed before use, so
     *                     {@code "Email"} and {@code "email"} are equivalent.
     * @param rawValue     the raw identifier as it appears in the source
     *                     system; may be {@code null} to represent a SQL
     *                     {@code NULL}
     * @return a 64-character lower-case hex string representing the SHA-256
     *         of {@code normalized_type || 0x1F || normalized_value}; or
     *         {@code null} if {@code rawValue} is {@code null} or if
     *         normalization produces an empty string (preserving SQL
     *         {@code NULL} semantics for effectively-empty inputs)
     */
    public String eval(String identityType, String rawValue) {
        if (rawValue == null)
            return null;
        if (identityType == null)
            throw new IllegalArgumentException("identityType must not be null");

        String normalizedType = identityType.strip().toLowerCase();
        String normalizedValue = normalize(normalizedType, rawValue);
        if (normalizedValue.isEmpty())
            return null;

        digest.reset();
        digest.update(normalizedType.getBytes(StandardCharsets.UTF_8));
        digest.update(TYPE_SEPARATOR);
        digest.update(normalizedValue.getBytes(StandardCharsets.UTF_8));
        return toHex(digest.digest());
    }

    private static String normalize(String normalizedType, String rawValue) {
        String trimmed = rawValue.strip();
        switch (normalizedType) {
            case "email":
                return trimmed.toLowerCase();
            case "phone":
                StringBuilder digits = new StringBuilder(trimmed.length());
                for (int i = 0; i < trimmed.length(); i++) {
                    char c = trimmed.charAt(i);
                    if (c >= '0' && c <= '9') {
                        digits.append(c);
                    }
                }
                return digits.toString();
            default:
                return trimmed.toLowerCase();
        }
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
