"""
Copyright (c) 2026 Jeffrey Jonathan Jennings

Author: Jeffrey Jonathan Jennings (J3)
"""
import struct
from hashlib import sha256
from typing import List, Optional

from pyflink.table.udf import ScalarFunction, udf
from pyflink.table import DataTypes


_NULL_LENGTH_MARKER = -1


class DedupKey(ScalarFunction):
    """
    A Flink scalar user-defined function (UDF) that computes a stable
    **deduplication key** (a.k.a. idempotency key) from the business-level
    fields of an event.

    Streaming pipelines deliver duplicate records constantly — at-least-once
    Kafka delivery, source replay after job restart, client-side retries
    that did not de-duplicate themselves, upstream systems that re-emit on
    recovery. An *idempotency key* is a deterministic fingerprint of the
    logical event (not its transport envelope) so that a downstream
    operator can ask "have I already processed this?" and safely skip on a
    yes. The classic Flink pattern uses
    ``ROW_NUMBER() OVER (PARTITION BY dedup_key …)`` or keyed-state
    membership checks against such a key.

    **What the key must guarantee**

    * **Stable across retries** — the same logical event produces the
      same key, even if delivered via a different partition, offset, or
      broker.
    * **Distinct across different events** — two events that differ in
      *any* of their business fields must produce different keys.
    * **Computed from payload, not from transport metadata** — Kafka
      offsets, ingestion timestamps, and partition numbers differ on
      retry and must be excluded from the key.

    **Encoding**

    The function hashes each field with a **4-byte big-endian length
    prefix** followed by the UTF-8 bytes of the field, then emits the
    SHA-256 hex digest. A ``None`` field is encoded as the prefix
    ``0xFFFFFFFF`` (``-1``) with no following bytes, making it distinct
    from the empty string (prefix ``0x00000000`` with zero following
    bytes).

    The length-prefix scheme is chosen deliberately over a naive separator
    (e.g. joining fields with ``0x1F``) because a separator-based scheme
    collides when a field *contains* the separator byte::

        ["a|b", "c"]  →  "a|b|c"   # with separator '|'
        ["a", "b|c"]  →  "a|b|c"   # same hash — COLLISION

    Length-prefix encoding is unambiguous no matter what bytes appear
    inside the fields, so two different field lists can never hash to the
    same key.

    **Input handling**

    * ``None`` array ⇒ ``None`` output.
    * Empty array ⇒ ``None`` output. A dedup key derived from zero fields
      would be a single global constant, almost certainly a bug.
    * Array containing some ``None`` elements ⇒ those elements are
      encoded distinctly from empty strings and participate in the hash.
    * Field values are **not** normalized (no trim, no case-folding). If
      two source systems emit ``"ORDER-123"`` and ``"order-123"`` for the
      same logical event, that is a data-contract concern to fix
      upstream; canonicalize before calling this UDF if loose matching is
      intended.

    SQL invocation::

        t_env.create_temporary_system_function("dedup_key", dedup_key)

        t_env.execute_sql('''
            INSERT INTO orders_clean
            SELECT *
              FROM (
                SELECT dedup_key(ARRAY[
                         source_system,
                         event_type,
                         CAST(business_id AS STRING),
                         CAST(occurred_at AS STRING)
                       ]) AS idempotency_key,
                       *,
                       ROW_NUMBER() OVER (
                         PARTITION BY dedup_key(ARRAY[
                           source_system, event_type,
                           CAST(business_id AS STRING),
                           CAST(occurred_at AS STRING)
                         ])
                         ORDER BY event_ts
                       ) AS rn
                  FROM orders_raw
              )
             WHERE rn = 1
        ''').print()
    """

    def eval(self, fields: Optional[List[Optional[str]]]) -> Optional[str]:
        """
        Compute the deduplication key for a list of business-level fields.

        PyFlink discovers scalar UDF logic by looking for an ``eval`` method
        on the ``ScalarFunction`` subclass, so the method name must remain
        as declared.

        :param fields: the business fields that uniquely identify the
            logical event; may be ``None`` to represent a SQL ``NULL``
            ``ARRAY`` value, and individual elements may be ``None``.
        :return: a 64-character lower-case hex string representing the
            SHA-256 of the length-prefix-encoded field sequence; or
            ``None`` if ``fields`` is ``None`` or empty.
        """
        if fields is None or len(fields) == 0:
            return None

        h = sha256()
        for field in fields:
            if field is None:
                h.update(struct.pack(">i", _NULL_LENGTH_MARKER))
            else:
                encoded = field.encode("utf-8")
                h.update(struct.pack(">i", len(encoded)))
                h.update(encoded)
        return h.hexdigest()


dedup_key = udf(
    DedupKey(),
    input_types=[DataTypes.ARRAY(DataTypes.STRING())],
    result_type=DataTypes.STRING(),
)
