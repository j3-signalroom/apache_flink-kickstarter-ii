"""
Copyright (c) 2026 Jeffrey Jonathan Jennings

Author: Jeffrey Jonathan Jennings (J3)
"""
import hmac
from hashlib import sha256
from typing import Optional

from pyflink.table.udf import ScalarFunction, udf
from pyflink.table import DataTypes

import secrets_resolver


_SECRET_BASE_NAME = "PAN_TOKENIZATION"
_BIN_LENGTH = 6
_LAST4_LENGTH = 4
_MIN_PAN_LENGTH = 13
_MAX_PAN_LENGTH = 19


class TokenizePan(ScalarFunction):
    """
    A Flink scalar user-defined function (UDF) that tokenizes a Primary
    Account Number (PAN) for PCI DSS scope reduction.

    For each input PAN the function emits a token of the form::

        <BIN (first 6 digits)> <HMAC hex middle> <last 4 digits>

    — same length as the input PAN, with the middle digits replaced by a
    keyed hex string. For a 16-digit PAN ``4111111111111111`` and a secret
    known only to the tokenization service, the output looks like
    ``411111a3c92b1111``.

    **What this achieves**

    * **Scope reduction** — downstream systems see only the token. Because
      the middle is a keyed one-way hash, the full PAN cannot be
      reconstructed from the token (nor from the token plus the BIN and
      last-4), so those systems fall out of PCI DSS scope. The original
      PAN remains only in the upstream "cardholder data environment" that
      holds the secret.
    * **Deterministic** — the same PAN always maps to the same token, so
      analytics joins, ``GROUP BY``, and ``COUNT DISTINCT`` on the token
      column behave exactly as they would on the PAN.
    * **PCI DSS 3.3-compatible display** — preserves first 6 (BIN) and
      last 4, which is the maximum PAN info PCI DSS permits to be
      displayed and is what customer-support UIs, fraud models, and
      statement reconciliation already rely on.
    * **Obviously not a PAN** — the hex middle contains characters
      ``a``–``f``, so the token cannot be mistaken for a real card number
      or accidentally submitted to a payment processor. A Luhn check on
      the token will almost always fail.

    **What this is NOT**

    * *Not reversible.* This is *irreversible* tokenization; there is no
      vault lookup to recover the PAN. If you need to charge the card
      later, tokenize against a vault service (e.g. a network token or
      your PSP's tokenization API) instead — those live outside a Flink
      scalar UDF because they require network I/O and state.
    * *Not a PCI DSS compliance attestation.* Using this UDF is a
      necessary but not sufficient step; your organization still needs to
      control access to the secret, rotate it on a schedule, and segment
      the network between the "has PAN" and "has only tokens" zones.

    **Input handling**

    The function is forgiving of common formatting: it strips any non-digit
    character (spaces, dashes, dots) before validating. It returns SQL
    ``NULL`` for:

    * ``None`` input,
    * an input that contains fewer than 13 or more than 19 digits after
      stripping (outside the ISO/IEC 7812-1 PAN length range).

    SQL invocation::

        t_env.create_temporary_system_function(
            "tokenize_pan",
            tokenize_pan,
        )

        t_env.execute_sql('''
            SELECT order_id,
                   tokenize_pan(card_number) AS card_token,
                   SUBSTRING(tokenize_pan(card_number), 1, 6) AS bin,
                   order_total
              FROM orders
        ''').print()
    """

    def __init__(self) -> None:
        super().__init__()
        self._secret: Optional[bytes] = None

    def open(self, function_context) -> None:
        """
        Load the HMAC secret once per Python worker. PyFlink calls ``open``
        before the first ``eval`` invocation on each parallel instance,
        which makes it the right place to load secrets and build objects
        that are expensive to construct but cheap to reuse.
        """
        self._secret = secrets_resolver.resolve(_SECRET_BASE_NAME).encode("utf-8")

    def eval(self, raw_pan: Optional[str]) -> Optional[str]:
        """
        Tokenize a single PAN.

        PyFlink discovers scalar UDF logic by looking for an ``eval`` method
        on the ``ScalarFunction`` subclass, so the method name must remain
        as declared.

        :param raw_pan: a PAN as it appears in the source system, optionally
            formatted with spaces or dashes (e.g. ``"4111 1111 1111 1111"``);
            may be ``None`` to represent a SQL ``NULL`` value.
        :return: a token of the same digit-length as the input PAN, with
            the middle replaced by HMAC-SHA256 hex characters; or ``None``
            if the input is ``None`` or does not parse to a 13-19 digit
            PAN.
        """
        if raw_pan is None:
            return None

        pan = _strip_to_digits(raw_pan)
        length = len(pan)
        if length < _MIN_PAN_LENGTH or length > _MAX_PAN_LENGTH:
            return None

        bin_ = pan[:_BIN_LENGTH]
        last4 = pan[-_LAST4_LENGTH:]
        middle_len = length - _BIN_LENGTH - _LAST4_LENGTH

        digest = hmac.new(self._secret, pan.encode("utf-8"), sha256).hexdigest()
        middle = digest[:middle_len]

        return bin_ + middle + last4


def _strip_to_digits(raw: str) -> str:
    return "".join(ch for ch in raw if "0" <= ch <= "9")


tokenize_pan = udf(
    TokenizePan(),
    input_types=[DataTypes.STRING()],
    result_type=DataTypes.STRING(),
)
