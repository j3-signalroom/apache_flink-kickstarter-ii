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
 * A Flink scalar user-defined function (UDF) that tokenizes a Primary Account
 * Number (PAN) for PCI DSS scope reduction.
 *
 * <p>For each input PAN the function emits a token of the form
 * <pre>
 *     &lt;BIN (first 6 digits)&gt; &lt;HMAC hex middle&gt; &lt;last 4 digits&gt;
 * </pre>
 * — same length as the input PAN, with the middle digits replaced by a
 * keyed hex string. For a 16-digit PAN {@code 4111111111111111} and a
 * secret known only to the tokenization service, the output looks like
 * {@code 411111a3c92b1111}.
 *
 * <h3>What this achieves</h3>
 * <ul>
 *   <li><b>Scope reduction</b> — downstream systems see only the token.
 *       Because the middle is a keyed one-way hash, the full PAN cannot be
 *       reconstructed from the token (nor from the token plus the BIN and
 *       last-4), so those systems fall out of PCI DSS scope. The original
 *       PAN remains only in the upstream "cardholder data environment"
 *       that holds the secret.</li>
 *   <li><b>Deterministic</b> — the same PAN always maps to the same token,
 *       so analytics joins, {@code GROUP BY}, and {@code COUNT DISTINCT}
 *       on the token column behave exactly as they would on the PAN.</li>
 *   <li><b>PCI DSS 3.3-compatible display</b> — preserves first 6 (BIN)
 *       and last 4, which is the maximum PAN info PCI DSS permits to be
 *       displayed and is what customer-support UIs, fraud models, and
 *       statement reconciliation already rely on.</li>
 *   <li><b>Obviously not a PAN</b> — the hex middle contains characters
 *       {@code a}-{@code f}, so the token cannot be mistaken for a real
 *       card number or accidentally submitted to a payment processor. A
 *       Luhn check on the token will almost always fail.</li>
 * </ul>
 *
 * <h3>What this is NOT</h3>
 * <ul>
 *   <li><b>Not reversible.</b> This is <i>irreversible</i> tokenization;
 *       there is no vault lookup to recover the PAN. If you need to charge
 *       the card later, tokenize against a vault service (e.g. a network
 *       token or your PSP's tokenization API) instead — those live outside
 *       a Flink scalar UDF because they require network I/O and state.</li>
 *   <li><b>Not a PCI DSS compliance attestation.</b> Using this UDF is a
 *       necessary but not sufficient step; your organization still needs
 *       to control access to the secret, rotate it on a schedule, and
 *       segment the network between the "has PAN" and "has only tokens"
 *       zones.</li>
 * </ul>
 *
 * <h3>Input handling</h3>
 * The function is forgiving of common formatting: it strips any non-digit
 * character (spaces, dashes, dots) before validating. It returns SQL
 * {@code NULL} for:
 * <ul>
 *   <li>{@code NULL} input,</li>
 *   <li>an input that contains fewer than 13 or more than 19 digits after
 *       stripping (outside the ISO/IEC 7812-1 PAN length range).</li>
 * </ul>
 *
 * <h3>SQL invocation</h3>
 * <pre>{@code
 * CREATE FUNCTION tokenize_pan
 *     AS 'scalar_udf.TokenizePan'
 *     LANGUAGE JAVA;
 *
 * SELECT order_id,
 *        tokenize_pan(card_number)          AS card_token,
 *        SUBSTRING(tokenize_pan(card_number), 1, 6) AS bin,
 *        order_total
 *   FROM orders;
 * }</pre>
 */
public class TokenizePan extends ScalarFunction {

    private static final String ALGORITHM = "HmacSHA256";
    private static final String SECRET_BASE_NAME = "PAN_TOKENIZATION";

    private static final int BIN_LENGTH = 6;
    private static final int LAST4_LENGTH = 4;
    private static final int MIN_PAN_LENGTH = 13;
    private static final int MAX_PAN_LENGTH = 19;

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
     * Tokenizes a single PAN.
     *
     * <p>Flink discovers scalar UDF logic by reflecting on public {@code eval}
     * methods, so the method name and visibility must remain as declared.
     *
     * @param rawPan a PAN as it appears in the source system, optionally
     *               formatted with spaces or dashes (e.g.
     *               {@code "4111 1111 1111 1111"}); may be {@code null} to
     *               represent a SQL {@code NULL} value
     * @return a token of the same digit-length as the input PAN, with the
     *         middle replaced by HMAC-SHA256 hex characters; or {@code null}
     *         if the input is {@code null} or does not parse to a 13-19
     *         digit PAN
     */
    public String eval(String rawPan) {
        if (rawPan == null)
            return null;

        String pan = stripToDigits(rawPan);
        int len = pan.length();
        if (len < MIN_PAN_LENGTH || len > MAX_PAN_LENGTH)
            return null;

        String bin = pan.substring(0, BIN_LENGTH);
        String last4 = pan.substring(len - LAST4_LENGTH);
        int middleLen = len - BIN_LENGTH - LAST4_LENGTH;

        byte[] digest = mac.doFinal(pan.getBytes(StandardCharsets.UTF_8));
        String middle = toHex(digest).substring(0, middleLen);

        return bin + middle + last4;
    }

    private static String stripToDigits(String raw) {
        StringBuilder digits = new StringBuilder(raw.length());
        for (int i = 0; i < raw.length(); i++) {
            char c = raw.charAt(i);
            if (c >= '0' && c <= '9') {
                digits.append(c);
            }
        }
        return digits.toString();
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
