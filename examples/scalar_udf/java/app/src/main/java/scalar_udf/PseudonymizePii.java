/**
 * Copyright (c) 2026 Jeffrey Jonathan Jennings
 *
 * @author Jeffrey Jonathan Jennings (J3)
 *
 *
 */
package scalar_udf;

import java.nio.charset.StandardCharsets;

import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;

import org.apache.flink.table.functions.FunctionContext;
import org.apache.flink.table.functions.ScalarFunction;

/**
 * A Flink scalar user-defined function (UDF) that pseudonymizes a personally
 * identifiable information (PII) value into a stable, keyed hash suitable for
 * downstream analytics.
 *
 * <p>The function computes {@code HMAC-SHA256(secret, namespace || 0x1F || value)}
 * and returns the result as a lower-case hexadecimal string. Because HMAC-SHA256
 * is a keyed one-way function:
 *
 * <ul>
 *   <li><b>Deterministic</b> — the same {@code (namespace, value)} pair always
 *       produces the same pseudonym, so joins, GROUP BYs, and DISTINCT counts
 *       continue to work on the pseudonymized column.</li>
 *   <li><b>Irreversible without the secret</b> — an analyst who sees only the
 *       output column cannot recover the original PII, even if they know the
 *       value space (e.g. all US phone numbers), provided the secret stays
 *       confidential.</li>
 *   <li><b>Domain-separated</b> — the {@code namespace} argument prevents a
 *       pseudonymized email from colliding with a pseudonymized phone number
 *       that happened to share string bytes, which would otherwise let an
 *       analyst link records across columns they should not be able to link.</li>
 * </ul>
 *
 * <p>The secret is loaded once per task slot inside {@link #open(FunctionContext)} via
 * {@link SecretsResolver}: when {@code PII_PSEUDONYM_SECRET_ID} is set the value is
 * fetched from AWS Secrets Manager (honoring {@code AWS_ENDPOINT_URL_SECRETSMANAGER} so
 * LocalStack works in dev), otherwise the resolver falls back to the
 * {@code PII_PSEUDONYM_SECRET} env var. Either way the secret never appears in query
 * plans or logs.
 *
 * <h3>SQL invocation</h3>
 * <pre>{@code
 * CREATE FUNCTION pseudonymize_pii
 *     AS 'scalar_udf.PseudonymizePii'
 *     LANGUAGE JAVA;
 *
 * SELECT pseudonymize_pii('email', email_address) AS email_pseudonym,
 *        pseudonymize_pii('phone', phone_number)  AS phone_pseudonym,
 *        order_total
 *   FROM orders;
 * }</pre>
 */
public class PseudonymizePii extends ScalarFunction {

    private static final String ALGORITHM = "HmacSHA256";
    private static final String SECRET_BASE_NAME = "PII_PSEUDONYM";
    private static final byte NAMESPACE_SEPARATOR = 0x1F;

    private transient Mac mac;

    /**
     * Initializes the HMAC primitive once per task slot. Flink calls
     * {@code open} before the first {@code eval} invocation on each parallel
     * instance, which makes it the right place to load secrets and build
     * objects that are expensive to construct but cheap to reuse.
     *
     * @param context the function context supplied by the Flink runtime
     * @throws Exception if the secret is missing or the JVM lacks HMAC-SHA256
     */
    @Override
    public void open(FunctionContext context) throws Exception {
        String secret = SecretsResolver.resolve(SECRET_BASE_NAME);
        mac = Mac.getInstance(ALGORITHM);
        mac.init(new SecretKeySpec(secret.getBytes(StandardCharsets.UTF_8), ALGORITHM));
    }

    /**
     * Pseudonymizes a single PII value within the given namespace.
     *
     * <p>Flink discovers scalar UDF logic by reflecting on public {@code eval}
     * methods, so the method name and visibility must remain as declared.
     *
     * @param namespace a short label identifying the PII domain (e.g.
     *                  {@code "email"}, {@code "phone"}, {@code "ssn"}); must
     *                  not be {@code null}. Using distinct namespaces per
     *                  column prevents cross-column linkability.
     * @param value     the raw PII value to pseudonymize; may be {@code null}
     *                  to represent a SQL {@code NULL} value
     * @return a 64-character lower-case hex string representing the HMAC-SHA256
     *         of {@code namespace || 0x1F || value}, or {@code null} if
     *         {@code value} was {@code null} (preserving SQL {@code NULL}
     *         semantics)
     */
    public String eval(String namespace, String value) {
        if (value == null)
            return null;
        if (namespace == null)
            throw new IllegalArgumentException("namespace must not be null");

        mac.reset();
        mac.update(namespace.getBytes(StandardCharsets.UTF_8));
        mac.update(NAMESPACE_SEPARATOR);
        mac.update(value.getBytes(StandardCharsets.UTF_8));
        return toHex(mac.doFinal());
    }

    /**
     * Converts a raw byte array (the 32-byte HMAC-SHA256 digest) into its 64-character
     * lower-case hexadecimal string representation. This is a common encoding for hashes
     * that preserves lexicographic ordering and is more compact than Base64.
     * 
     * @param bytes the byte array to convert
     * @return a 64-character lower-case hexadecimal string representing the input bytes
     */
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
