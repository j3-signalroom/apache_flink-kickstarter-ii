/**
 * Copyright (c) 2026 Jeffrey Jonathan Jennings
 *
 * @author Jeffrey Jonathan Jennings (J3)
 *
 *
 */
package scalar_udf;

import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import org.apache.flink.table.functions.FunctionContext;
import org.apache.flink.table.functions.ScalarFunction;

/**
 * A Flink scalar user-defined function (UDF) that masks Personally
 * Identifiable Information (PII) in free-form text by detecting known
 * entity types via regular expressions and replacing every matched span
 * with {@code ****}.
 *
 * <p>The detection patterns and per-entity validation logic are ported
 * verbatim from Microsoft Presidio's
 * <a href="https://github.com/microsoft/presidio/tree/main/presidio-analyzer/presidio_analyzer/predefined_recognizers">
 * predefined regex recognizers</a>. A sibling Python UDF
 * {@code mask_pii_regex} wraps the same patterns via Presidio's
 * {@code AnalyzerEngine} configured with only the regex-based
 * recognizers (no spaCy NER), so both languages produce the same
 * detection output for the same input.
 *
 * <h3>Supported entity types</h3>
 * <table>
 *   <caption>Detection coverage</caption>
 *   <tr><th>Entity</th><th>Patterns</th><th>Validation</th></tr>
 *   <tr><td>{@code EMAIL_ADDRESS}</td><td>1</td><td>None (regex only)</td></tr>
 *   <tr><td>{@code IP_ADDRESS}</td><td>5 (IPv4, IPv6, IPv4-mapped, IPv4-embedded, IPv6-unspecified)</td><td>None (regex only)</td></tr>
 *   <tr><td>{@code US_SSN}</td><td>5</td><td>Rejects mismatched delimiters, all-same-digit, zero groups, known sample SSNs</td></tr>
 *   <tr><td>{@code CREDIT_CARD}</td><td>1</td><td>Luhn checksum after stripping {@code -} / {@code ' '}</td></tr>
 * </table>
 *
 * <p>URLs, phone numbers, IBANs, crypto wallet addresses, and other
 * country-specific identifiers are <b>deliberately out of scope for
 * this first version</b>. URL detection in particular requires a
 * ~5 KB alternation over every TLD and adds significant complexity
 * with little tutorial value; phone detection requires Google's
 * {@code libphonenumber} library on both sides for parity. Both are
 * natural extensions if a real deployment needs them.
 *
 * <h3>Overlap resolution</h3>
 * When two patterns (possibly from different entity types) match
 * overlapping character ranges, the function applies a <b>longest-match
 * wins</b> greedy resolution: candidate spans are sorted by length
 * descending, then left-to-right; each span is kept unless it overlaps
 * a previously-kept span. This is deterministic and trivially
 * portable between languages, which is exactly what the Java / Python
 * cross-check relies on.
 *
 * <p>Note that Presidio's own overlap resolution also considers per-
 * pattern confidence scores. Output from this UDF will match Presidio's
 * stock output in the vast majority of cases but may differ on
 * contrived inputs where a shorter, higher-scored match would win over
 * a longer, lower-scored one. The trade-off buys simple, auditable
 * cross-language parity.
 *
 * <h3>NULL semantics</h3>
 * {@code NULL} input ⇒ {@code NULL} output. A {@code NULL} is
 * meaningfully different from an empty or PII-free string: this UDF
 * preserves that distinction through the pipeline.
 *
 * <h3>SQL invocation</h3>
 * <pre>{@code
 * CREATE FUNCTION mask_pii_regex
 *     AS 'scalar_udf.MaskPiiRegex'
 *     LANGUAGE JAVA;
 *
 * SELECT ticket_id,
 *        mask_pii_regex(customer_message) AS redacted_message
 *   FROM support_tickets;
 * }</pre>
 */
public class MaskPiiRegex extends ScalarFunction {

    private static final String REPLACEMENT = "****";

    // ─── Regex patterns ported verbatim from Presidio ─────────────────────
    // presidio-analyzer/presidio_analyzer/predefined_recognizers/generic/email_recognizer.py
    private static final String EMAIL_PATTERN =
        "\\b((([!#$%&'*+\\-/=?^_`{|}~\\w])|([!#$%&'*+\\-/=?^_`{|}~\\w]"
      + "[!#$%&'*+\\-/=?^_`{|}~\\.\\w]{0,}[!#$%&'*+\\-/=?^_`{|}~\\w]))"
      + "[@]\\w+([-.]\\w+)*\\.\\w+([-.]\\w+)*)\\b";

    // presidio-analyzer/presidio_analyzer/predefined_recognizers/generic/ip_recognizer.py
    // Patterns ported from the PyPI release that this package pins against
    // (presidio-analyzer==2.2.359). The GitHub main branch currently contains
    // a different, larger pattern set; aligning here with what PyPI ships
    // guarantees byte-identical output with the sibling Python UDF.
    private static final String[] IP_PATTERNS = new String[] {
        // IPv4
        "\\b(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)"
      + "\\.(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)"
      + "\\.(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)"
      + "\\.(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\\b",
        // IPv6 (big alternation — handles full / compressed / IPv4-mapped forms)
        "\\b(([0-9a-fA-F]{1,4}:){7,7}[0-9a-fA-F]{1,4}"
      + "|([0-9a-fA-F]{1,4}:){1,7}:"
      + "|([0-9a-fA-F]{1,4}:){1,6}:[0-9a-fA-F]{1,4}"
      + "|([0-9a-fA-F]{1,4}:){1,5}(:[0-9a-fA-F]{1,4}){1,2}"
      + "|([0-9a-fA-F]{1,4}:){1,4}(:[0-9a-fA-F]{1,4}){1,3}"
      + "|([0-9a-fA-F]{1,4}:){1,3}(:[0-9a-fA-F]{1,4}){1,4}"
      + "|([0-9a-fA-F]{1,4}:){1,2}(:[0-9a-fA-F]{1,4}){1,5}"
      + "|[0-9a-fA-F]{1,4}:((:[0-9a-fA-F]{1,4}){1,6})"
      + "|:((:[0-9a-fA-F]{1,4}){1,7}|:)"
      + "|fe80:(:[0-9a-fA-F]{0,4}){0,4}%[0-9a-zA-Z]{1,}"
      + "|::(ffff(:0{1,4}){0,1}:){0,1}"
      + "((25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])\\.){3,3}"
      + "(25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])"
      + "|([0-9a-fA-F]{1,4}:){1,4}:"
      + "((25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])\\.){3,3}"
      + "(25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9]))\\b",
        // IPv6 (literal "::") — Presidio ships this as a separate pattern
        "::",
    };

    // presidio-analyzer/presidio_analyzer/predefined_recognizers/country_specific/us/us_ssn_recognizer.py
    private static final String[] SSN_PATTERNS = new String[] {
        "\\b([0-9]{5})-([0-9]{4})\\b",
        "\\b([0-9]{3})-([0-9]{6})\\b",
        "\\b(([0-9]{3})-([0-9]{2})-([0-9]{4}))\\b",
        "\\b[0-9]{9}\\b",
        "\\b([0-9]{3})[- .]([0-9]{2})[- .]([0-9]{4})\\b",
    };

    // presidio-analyzer/presidio_analyzer/predefined_recognizers/generic/credit_card_recognizer.py
    private static final String CREDIT_CARD_PATTERN =
        "\\b(?!1\\d{12}(?!\\d))((4\\d{3})|(5[0-5]\\d{2})|(6\\d{3})|(1\\d{3})|(3\\d{3}))"
      + "[- ]?(\\d{3,4})[- ]?(\\d{3,4})[- ]?(\\d{3,5})\\b";

    private enum EntityType { EMAIL_ADDRESS, IP_ADDRESS, US_SSN, CREDIT_CARD }

    private record CompiledPattern(EntityType entity, Pattern regex) {}
    private record Span(int start, int end, EntityType entity) {
        int length() { return end - start; }
    }

    private transient List<CompiledPattern> patterns;

    /**
     * Compiles every regex once per task slot. Flink calls {@code open}
     * before the first {@code eval} invocation on each parallel instance,
     * which amortizes pattern compilation across the lifetime of the
     * subtask rather than paying it per row.
     */
    @Override
    public void open(FunctionContext context) {
        patterns = new ArrayList<>();
        patterns.add(new CompiledPattern(EntityType.EMAIL_ADDRESS, Pattern.compile(EMAIL_PATTERN, Pattern.UNICODE_CHARACTER_CLASS)));
        for (String p : IP_PATTERNS) {
            patterns.add(new CompiledPattern(EntityType.IP_ADDRESS, Pattern.compile(p, Pattern.UNICODE_CHARACTER_CLASS)));
        }
        for (String p : SSN_PATTERNS) {
            patterns.add(new CompiledPattern(EntityType.US_SSN, Pattern.compile(p, Pattern.UNICODE_CHARACTER_CLASS)));
        }
        patterns.add(new CompiledPattern(EntityType.CREDIT_CARD,
            Pattern.compile(CREDIT_CARD_PATTERN, Pattern.UNICODE_CHARACTER_CLASS)));
    }

    /**
     * Masks every detected PII span in the input text with {@code ****}.
     *
     * @param text free-form input text; may be {@code null} (represents
     *             SQL {@code NULL})
     * @return the input with every detected PII span replaced by
     *         {@code ****}; or {@code null} if the input was {@code null}
     */
    public String eval(String text) {
        if (text == null) return null;

        List<Span> candidates = new ArrayList<>();
        for (CompiledPattern cp : patterns) {
            Matcher m = cp.regex.matcher(text);
            while (m.find()) {
                String matched = text.substring(m.start(), m.end());
                if (cp.entity == EntityType.CREDIT_CARD && !luhnValid(matched)) continue;
                if (cp.entity == EntityType.US_SSN && ssnInvalid(matched)) continue;
                candidates.add(new Span(m.start(), m.end(), cp.entity));
            }
        }

        // Longest-match-wins greedy resolution: sort by length DESC, then start ASC
        candidates.sort(
            Comparator.comparingInt((Span s) -> s.length()).reversed()
                      .thenComparingInt(s -> s.start));

        List<Span> kept = new ArrayList<>();
        boolean[] covered = new boolean[text.length()];
        for (Span s : candidates) {
            boolean overlap = false;
            for (int i = s.start; i < s.end; i++) {
                if (covered[i]) { overlap = true; break; }
            }
            if (!overlap) {
                kept.add(s);
                for (int i = s.start; i < s.end; i++) covered[i] = true;
            }
        }

        // Apply replacements right-to-left so earlier spans' offsets stay valid
        kept.sort(Comparator.comparingInt((Span s) -> s.start).reversed());
        StringBuilder sb = new StringBuilder(text);
        for (Span s : kept) {
            sb.replace(s.start, s.end, REPLACEMENT);
        }
        return sb.toString();
    }

    /**
     * Luhn checksum port of Presidio's {@code __luhn_checksum}. Strips
     * {@code -} and space characters before checking (matches Presidio's
     * default {@code replacement_pairs}).
     */
    private static boolean luhnValid(String matched) {
        StringBuilder digits = new StringBuilder(matched.length());
        for (int i = 0; i < matched.length(); i++) {
            char c = matched.charAt(i);
            if (c >= '0' && c <= '9') digits.append(c);
            else if (c == '-' || c == ' ') continue;
            else return false;
        }
        String d = digits.toString();
        if (d.length() < 2) return false;

        int sum = 0;
        // Rightmost digit is "odd" position (index from end, 0-based)
        for (int i = d.length() - 1, pos = 0; i >= 0; i--, pos++) {
            int digit = d.charAt(i) - '0';
            if (pos % 2 == 1) {
                digit *= 2;
                if (digit > 9) digit -= 9;
            }
            sum += digit;
        }
        return sum % 10 == 0;
    }

    /**
     * SSN invalidation port of Presidio's {@code invalidate_result}.
     * Returns {@code true} when the match should be rejected as NOT a
     * valid SSN.
     */
    private static boolean ssnInvalid(String matched) {
        // 1. Mismatched delimiters (e.g., "123-45 6789")
        int dots = 0, dashes = 0, spaces = 0;
        for (int i = 0; i < matched.length(); i++) {
            char c = matched.charAt(i);
            if (c == '.') dots++;
            else if (c == '-') dashes++;
            else if (c == ' ') spaces++;
        }
        int distinct = (dots > 0 ? 1 : 0) + (dashes > 0 ? 1 : 0) + (spaces > 0 ? 1 : 0);
        if (distinct > 1) return true;

        // Extract digits only
        StringBuilder db = new StringBuilder(matched.length());
        for (int i = 0; i < matched.length(); i++) {
            char c = matched.charAt(i);
            if (c >= '0' && c <= '9') db.append(c);
        }
        String d = db.toString();
        if (d.isEmpty()) return true;

        // 2. All the same digit (e.g., 111-11-1111)
        char first = d.charAt(0);
        boolean allSame = true;
        for (int i = 1; i < d.length(); i++) {
            if (d.charAt(i) != first) { allSame = false; break; }
        }
        if (allSame) return true;

        // 3. Area-serial zero-group check (Presidio: only_digits[3:5] / only_digits[5:])
        if (d.length() >= 5 && d.substring(3, 5).equals("00")) return true;
        if (d.length() > 5 && d.substring(5).equals("0000")) return true;

        // 4. Known sample / invalid SSNs
        String[] blocked = {"000", "666", "123456789", "98765432", "078051120"};
        for (String b : blocked) {
            if (d.startsWith(b)) return true;
        }

        return false;
    }
}
