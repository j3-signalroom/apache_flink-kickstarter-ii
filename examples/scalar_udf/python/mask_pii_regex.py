"""
Copyright (c) 2026 Jeffrey Jonathan Jennings

Author: Jeffrey Jonathan Jennings (J3)
"""
from typing import List, Optional

from presidio_analyzer.predefined_recognizers import (
    CreditCardRecognizer,
    EmailRecognizer,
    IpRecognizer,
    UsSsnRecognizer,
)
from presidio_anonymizer import AnonymizerEngine
from presidio_anonymizer.entities import OperatorConfig, RecognizerResult
from pyflink.table import DataTypes
from pyflink.table.udf import ScalarFunction, udf


_REPLACEMENT = "****"


class _ParityEmailRecognizer(EmailRecognizer):
    """Drop Presidio's tldextract-based validation so Python matches
    what the Java port sees (Java does not ship tldextract). The regex
    pattern and entity type are inherited unchanged.
    """

    def validate_result(self, pattern_text: str) -> bool:  # noqa: D401
        return True


class MaskPiiRegex(ScalarFunction):
    """
    A Flink scalar user-defined function (UDF) that masks Personally
    Identifiable Information (PII) in free-form text by detecting known
    entity types via Microsoft Presidio's regex-based recognizers, then
    replacing every matched span with ``****``.

    A sibling Java UDF ``MaskPiiRegex`` ports the same regex patterns
    and per-entity validation logic (Luhn for credit cards, blocklist /
    delimiter / zero-group checks for US SSNs). The two are exercised
    by a cross-language parity test so their outputs match byte-for-byte
    on the same input corpus.

    **Supported entity types**

    ============== ======== =============================================================
    Entity          Patterns Validation
    ============== ======== =============================================================
    EMAIL_ADDRESS   1        None (tldextract validation dropped for Java parity)
    IP_ADDRESS      5        None (regex only — IPv4, IPv6, mapped/embedded variants)
    US_SSN          5        Rejects mismatched delimiters, all-same-digit, zero groups,
                             and known sample SSNs (123456789, 078051120, etc.)
    CREDIT_CARD     1        Luhn checksum after stripping ``-`` / space
    ============== ======== =============================================================

    URLs, phone numbers, IBANs, crypto wallet addresses, and other
    country-specific identifiers are **deliberately out of scope for
    this first version**. URL detection in particular requires a
    ~5 KB alternation over every TLD; phone detection requires Google's
    ``libphonenumber`` on both sides for parity. Both are natural
    extensions if a real deployment needs them.

    **Why this UDF looks different from Confluent's ``pii_mask``**

    Confluent's reference example uses Presidio's ``AnalyzerEngine``
    with the full spaCy NER pipeline so it can also mask person names,
    organizations, and locations in free-form text. That detection is
    Python-only — there is no equivalent NER stack available to a Java
    UDF that produces matching output. This package takes a different
    trade-off: regex-based detection only, *byte-identical* output
    between Java and Python. If you need NER, pair this UDF with a
    Python-only ``mask_pii_ner`` (not shipped here yet) and document
    that rows going through that UDF are not Java-reproducible.

    **Overlap resolution**

    When two patterns (possibly from different entity types) match
    overlapping character ranges, the function applies a **longest-match
    wins** greedy resolution: candidate spans are sorted by length
    descending, then left-to-right; each span is kept unless it overlaps
    a previously-kept span. This is deterministic and trivially
    portable between languages — exactly what the Java / Python
    cross-check relies on. Presidio's own overlap resolution additionally
    weighs per-pattern confidence scores; we skip that to keep parity
    simple and auditable.

    **NULL semantics**

    ``None`` input ⇒ ``None`` output. Everything else is run through
    detection and anonymization even if the result is unchanged (i.e.,
    a PII-free string round-trips unchanged, not to ``None``).

    SQL invocation::

        t_env.create_temporary_system_function(
            "mask_pii_regex",
            mask_pii_regex,
        )

        t_env.execute_sql('''
            SELECT ticket_id,
                   mask_pii_regex(customer_message) AS redacted_message
              FROM support_tickets
        ''').print()
    """

    def __init__(self) -> None:
        super().__init__()
        self._recognizers: Optional[list] = None
        self._anonymizer = AnonymizerEngine()
        self._operators = {
            "DEFAULT": OperatorConfig("replace", {"new_value": _REPLACEMENT})
        }

    def open(self, function_context) -> None:
        """
        Initialize Presidio's regex recognizers once per Python worker.

        Presidio's stock ``EmailRecognizer`` uses ``tldextract`` to
        validate that a match has a real TLD, which by default fetches
        suffix lists over HTTPS. Confluent Cloud's UDF runtime has no
        network access, so ``tldextract`` is forced into snapshot-only
        mode here — matching the pattern from Confluent's own
        ``flink-udf-python-examples/pii_mask`` reference. In addition,
        ``_ParityEmailRecognizer`` below skips the tldextract check
        entirely, so Python output matches the Java port (which has no
        tldextract at all).
        """
        import tldextract

        tldextract.extract = tldextract.TLDExtract(  # type: ignore[assignment]
            suffix_list_urls=(),
            cache_dir=None,
            fallback_to_snapshot=True,
        )

        self._recognizers = [
            _ParityEmailRecognizer(),
            IpRecognizer(),
            UsSsnRecognizer(),
            CreditCardRecognizer(),
        ]

    def eval(self, text: Optional[str]) -> Optional[str]:
        """
        Mask every detected PII span in the input text with ``****``.

        PyFlink discovers scalar UDF logic by looking for an ``eval``
        method on the ``ScalarFunction`` subclass, so the method name
        must remain as declared.

        :param text: free-form input text; may be ``None`` (represents
            SQL ``NULL``).
        :return: the input with every detected PII span replaced by
            ``****``; or ``None`` if the input was ``None``.
        """
        if text is None:
            return None

        assert self._recognizers is not None

        candidates: List[RecognizerResult] = []
        for recognizer in self._recognizers:
            results = recognizer.analyze(
                text=text,
                entities=[recognizer.supported_entities[0]],
                nlp_artifacts=None,
            )
            if results:
                candidates.extend(results)

        candidates.sort(key=lambda r: (-(r.end - r.start), r.start))
        kept: List[RecognizerResult] = []
        covered = [False] * len(text)
        for result in candidates:
            if any(covered[i] for i in range(result.start, result.end)):
                continue
            kept.append(result)
            for i in range(result.start, result.end):
                covered[i] = True

        engine_result = self._anonymizer.anonymize(
            text=text,
            analyzer_results=kept,
            operators=self._operators,
        )
        return engine_result.text


mask_pii_regex = udf(
    MaskPiiRegex(),
    input_types=[DataTypes.STRING()],
    result_type=DataTypes.STRING(),
)
