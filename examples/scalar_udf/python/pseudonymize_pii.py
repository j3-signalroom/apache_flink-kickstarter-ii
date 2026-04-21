"""
Copyright (c) 2026 Jeffrey Jonathan Jennings

Author: Jeffrey Jonathan Jennings (J3)
"""
import hmac
import os
from hashlib import sha256
from typing import Optional

from pyflink.table.udf import ScalarFunction, udf
from pyflink.table import DataTypes


_SECRET_ENV_VAR = "PII_PSEUDONYM_SECRET"
_NAMESPACE_SEPARATOR = b"\x1f"


class PseudonymizePii(ScalarFunction):
    """
    A Flink scalar user-defined function (UDF) that pseudonymizes a personally
    identifiable information (PII) value into a stable, keyed hash suitable for
    downstream analytics.

    The function computes ``HMAC-SHA256(secret, namespace || 0x1F || value)``
    and returns the result as a lower-case hexadecimal string. Because
    HMAC-SHA256 is a keyed one-way function:

    * **Deterministic** — the same ``(namespace, value)`` pair always produces
      the same pseudonym, so joins, ``GROUP BY``s, and ``DISTINCT`` counts
      continue to work on the pseudonymized column.
    * **Irreversible without the secret** — an analyst who sees only the
      output column cannot recover the original PII, even if they know the
      value space (e.g. all US phone numbers), provided the secret stays
      confidential.
    * **Domain-separated** — the ``namespace`` argument prevents a
      pseudonymized email from colliding with a pseudonymized phone number
      that happened to share string bytes, which would otherwise let an
      analyst link records across columns they should not be able to link.

    The secret is loaded once per Python worker from the
    ``PII_PSEUDONYM_SECRET`` environment variable inside :meth:`open`, so it
    never has to be passed at the SQL call site and never appears in query
    plans or logs.

    SQL invocation::

        t_env.create_temporary_system_function(
            "pseudonymize_pii",
            pseudonymize_pii,
        )

        t_env.execute_sql('''
            SELECT pseudonymize_pii('email', email_address) AS email_pseudonym,
                   pseudonymize_pii('phone', phone_number)  AS phone_pseudonym,
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
        before the first ``eval`` invocation on each parallel instance, which
        makes it the right place to load secrets and build objects that are
        expensive to construct but cheap to reuse.
        """
        secret = os.environ.get(_SECRET_ENV_VAR)
        if not secret:
            raise RuntimeError(
                f"Environment variable {_SECRET_ENV_VAR} must be set to a non-empty "
                "secret so that PseudonymizePii can compute keyed hashes. Treat this "
                "value as a production secret: losing it breaks re-pseudonymization, "
                "leaking it breaks the irreversibility guarantee."
            )
        self._secret = secret.encode("utf-8")

    def eval(self, namespace: str, value: Optional[str]) -> Optional[str]:
        """
        Pseudonymize a single PII value within the given namespace.

        PyFlink discovers scalar UDF logic by looking for an ``eval`` method on
        the ``ScalarFunction`` subclass, so the method name must remain as
        declared.

        :param namespace: short label identifying the PII domain (e.g.
            ``"email"``, ``"phone"``, ``"ssn"``); must not be ``None``. Using
            distinct namespaces per column prevents cross-column linkability.
        :param value: the raw PII value to pseudonymize; may be ``None`` to
            represent a SQL ``NULL`` value.
        :return: a 64-character lower-case hex string representing the
            HMAC-SHA256 of ``namespace || 0x1F || value``, or ``None`` if
            ``value`` was ``None`` (preserving SQL ``NULL`` semantics).
        """
        if value is None:
            return None
        if namespace is None:
            raise ValueError("namespace must not be None")

        message = namespace.encode("utf-8") + _NAMESPACE_SEPARATOR + value.encode("utf-8")
        return hmac.new(self._secret, message, sha256).hexdigest()


pseudonymize_pii = udf(
    PseudonymizePii(),
    input_types=[DataTypes.STRING(), DataTypes.STRING()],
    result_type=DataTypes.STRING(),
)
