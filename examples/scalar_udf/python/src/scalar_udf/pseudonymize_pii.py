"""
Copyright (c) 2026 Jeffrey Jonathan Jennings

Author: Jeffrey Jonathan Jennings (J3)
"""
import hmac
from hashlib import sha256
from typing import Optional

from pyflink.table.udf import ScalarFunction, udf
from pyflink.table import DataTypes

from . import secrets_resolver


_SECRET_BASE_NAME = "PII_PSEUDONYM"
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

    The secret is loaded once per Python worker inside :meth:`open` via
    :mod:`secrets_resolver`: when ``PII_PSEUDONYM_SECRET_ID`` is set the value
    is fetched from AWS Secrets Manager (honoring
    ``AWS_ENDPOINT_URL_SECRETSMANAGER`` so LocalStack works in dev),
    otherwise the resolver falls back to the ``PII_PSEUDONYM_SECRET`` env var.
    Either way the secret never appears in query plans or logs.

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
        self._secret = secrets_resolver.resolve(_SECRET_BASE_NAME).encode("utf-8")

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
