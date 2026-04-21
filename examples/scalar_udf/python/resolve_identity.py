"""
Copyright (c) 2026 Jeffrey Jonathan Jennings

Author: Jeffrey Jonathan Jennings (J3)
"""
from hashlib import sha256
from typing import Optional

from pyflink.table.udf import ScalarFunction, udf
from pyflink.table import DataTypes


_TYPE_SEPARATOR = b"\x1f"


class ResolveIdentity(ScalarFunction):
    """
    A Flink scalar user-defined function (UDF) that performs cross-system
    identity resolution by turning a raw identity signal into a stable,
    system-agnostic canonical identifier.

    Given an ``identity_type`` (e.g. ``"email"``, ``"phone"``, ``"user_id"``)
    and a ``raw_value`` as it appears in some source system, the function:

    1. **Normalizes** the value per type so that superficial formatting
       differences — ``"Alice@Example.com "`` vs ``"alice@example.com"``,
       or ``"(415) 555-0134"`` vs ``"+1-415-555-0134"`` — collapse to the
       same canonical form.
    2. **Hashes** ``normalized_type || 0x1F || normalized_value`` with
       SHA-256 and returns the lower-case hex digest.

    The resulting 64-character hex string is the *resolved identity key*:
    two rows from different source systems that refer to the same real-world
    entity produce the same key and can be joined without a shared primary
    key.

    **Keyed vs. un-keyed design choice**

    Unlike :class:`PseudonymizePii`, this UDF deliberately uses an
    **un-keyed** hash (plain SHA-256, no secret). Identity resolution is
    about *interoperability*: partner systems that do not share a secret
    must still derive the same key for the same underlying entity. The
    tradeoff is that the output is feasible to brute-force when the
    plaintext space is small (e.g. all valid US phone numbers), so a
    resolved identity key should be treated as a **linkage identifier**,
    not as a privacy-preserving pseudonym. When the value must be both
    join-stable *and* irreversible, use :class:`PseudonymizePii` instead.

    **Normalization rules**

    * ``"email"`` — trim, then lower-case the entire address.
    * ``"phone"`` — keep only ASCII digits ``0-9``; strip ``+``, spaces,
      parentheses, dashes, dots, and any non-digit character. Callers that
      need country-code prefixing should do so upstream before invoking
      the UDF.
    * any other ``identity_type`` — trim and lower-case.

    SQL invocation::

        t_env.create_temporary_system_function(
            "resolve_identity",
            resolve_identity,
        )

        t_env.execute_sql('''
            SELECT c.customer_id,
                   e.event_name,
                   e.event_ts
              FROM crm_customers    c
              JOIN analytics_events e
                ON resolve_identity('email', c.email_address)
                 = resolve_identity('email', e.user_email)
        ''').print()
    """

    def eval(
        self,
        identity_type: str,
        raw_value: Optional[str],
    ) -> Optional[str]:
        """
        Resolve a single identity signal to its canonical hex key.

        PyFlink discovers scalar UDF logic by looking for an ``eval`` method on
        the ``ScalarFunction`` subclass, so the method name must remain as
        declared.

        :param identity_type: short label identifying the kind of identifier
            (e.g. ``"email"``, ``"phone"``, ``"user_id"``); must not be
            ``None``. The type is lower-cased and trimmed before use, so
            ``"Email"`` and ``"email"`` are equivalent.
        :param raw_value: the raw identifier as it appears in the source
            system; may be ``None`` to represent a SQL ``NULL``.
        :return: a 64-character lower-case hex string representing the
            SHA-256 of ``normalized_type || 0x1F || normalized_value``; or
            ``None`` if ``raw_value`` is ``None`` or if normalization
            produces an empty string (preserving SQL ``NULL`` semantics
            for effectively-empty inputs).
        """
        if raw_value is None:
            return None
        if identity_type is None:
            raise ValueError("identity_type must not be None")

        normalized_type = identity_type.strip().lower()
        normalized_value = _normalize(normalized_type, raw_value)
        if not normalized_value:
            return None

        message = (
            normalized_type.encode("utf-8")
            + _TYPE_SEPARATOR
            + normalized_value.encode("utf-8")
        )
        return sha256(message).hexdigest()


def _normalize(normalized_type: str, raw_value: str) -> str:
    trimmed = raw_value.strip()
    if normalized_type == "email":
        return trimmed.lower()
    if normalized_type == "phone":
        return "".join(ch for ch in trimmed if "0" <= ch <= "9")
    return trimmed.lower()


resolve_identity = udf(
    ResolveIdentity(),
    input_types=[DataTypes.STRING(), DataTypes.STRING()],
    result_type=DataTypes.STRING(),
)
