"""
Copyright (c) 2026 Jeffrey Jonathan Jennings

Author: Jeffrey Jonathan Jennings (J3)
"""
from typing import Optional

from pyflink.table.udf import ScalarFunction, udf
from pyflink.table import DataTypes


# murmur2 constants, verbatim from
# org.apache.kafka.common.utils.Utils#murmur2(byte[])
_SEED = 0x9747B28C
_M = 0x5BD1E995
_R = 24
_MASK_32 = 0xFFFFFFFF


class ConsistentBucket(ScalarFunction):
    """
    A Flink scalar user-defined function (UDF) that maps a string key to a
    non-negative bucket index in the range ``[0, num_buckets)`` using the
    same hash function Kafka's default partitioner uses.

    "Consistent" here means **cross-system consistent**: given the same
    key and the same ``num_buckets``, this UDF produces the same bucket
    that Kafka's producer would have chosen for the same partition count,
    because both use the 32-bit ``murmur2`` variant from
    ``org.apache.kafka.common.utils.Utils#murmur2(byte[])``. That makes it
    the right tool whenever Flink output needs to land on the same Kafka
    partition, database shard, or cache slot as upstream or downstream
    systems that follow the Kafka convention.

    **When to use which hash**

    There is no universal "best" partition hash — pick the one that
    matches the system you need to co-partition with:

    * **Kafka producer / consumer**, most JVM streaming tools ⇒
      ``murmur2`` (this UDF).
    * Spark ``HashPartitioner`` ⇒ Java ``Object.hashCode()`` — *not*
      portable and biased on short sequential strings; avoid for
      cross-system work.
    * Some CDC / log-compaction consumers ⇒ ``murmur3`` 32-bit — similar
      name, different constants; the two are not interchangeable.
    * Cryptographic or security-sensitive bucketing (e.g. preventing
      adversarial hot-spotting) ⇒ HMAC-SHA256 truncated. Slower, not
      needed for ordinary partitioning.

    **Example use cases**

    * **Kafka co-partitioning** — keep Flink sinks aligned with the
      producer-side partition count so downstream joiners see paired
      events on the same partition without a repartition step.
    * **Database / cache sharding** — route keyed writes to shard
      ``consistent_bucket(customer_id, shard_count)`` so the same
      customer always lands on the same shard.
    * **Deterministic A/B cohort assignment** — bucket users into 100
      slots and treat ``< 10`` as the treatment arm; the assignment is
      stable across job restarts and across services.
    * **Streaming reservoir sampling at fixed rate** —
      ``WHERE consistent_bucket(event_id, 100) < 5`` keeps ~5% of events
      deterministically (same ``event_id`` is always sampled or always
      dropped).

    **Null semantics**

    * ``key = None`` ⇒ output is ``None``. Matches Kafka's behavior of
      round-robin-ing null-keyed records rather than assigning them a
      deterministic partition; callers who need a stable bucket for
      absent keys should substitute a sentinel upstream.
    * ``num_buckets = None`` ⇒ output is ``None``.
    * ``num_buckets <= 0`` ⇒ raises ``ValueError``; a configuration
      error, not a data error.

    SQL invocation::

        t_env.create_temporary_system_function(
            "consistent_bucket",
            consistent_bucket,
        )

        t_env.execute_sql('''
            SELECT *
              FROM clickstream
             WHERE consistent_bucket(user_id, 100) < 10
        ''').print()
    """

    def eval(
        self,
        key: Optional[str],
        num_buckets: Optional[int],
    ) -> Optional[int]:
        """
        Compute the bucket index for a key.

        PyFlink discovers scalar UDF logic by looking for an ``eval`` method
        on the ``ScalarFunction`` subclass, so the method name must remain
        as declared.

        :param key: the partitioning key; may be ``None`` to represent a
            SQL ``NULL`` value.
        :param num_buckets: the total number of buckets / partitions; must
            be positive. May be ``None`` to represent a SQL ``NULL``.
        :return: an integer in the range ``[0, num_buckets)``, or ``None``
            if either argument is ``None``.
        :raises ValueError: if ``num_buckets`` is zero or negative.
        """
        if key is None or num_buckets is None:
            return None
        return bucket(key, num_buckets)


def bucket(key: str, num_buckets: int) -> int:
    """
    Static entry point suitable for direct calls from non-Flink code
    (tests, batch tooling). Kept public so that parity with the Java port
    and with Kafka's partitioner can be verified outside the Flink
    runtime.
    """
    if num_buckets <= 0:
        raise ValueError(f"num_buckets must be positive, got {num_buckets}")
    h = murmur2(key.encode("utf-8"))
    # Kafka's Utils.toPositive: mask the sign bit rather than abs, because
    # abs(INT32_MIN) == INT32_MIN in 32-bit two's complement and would
    # yield a negative modulus.
    return (h & 0x7FFFFFFF) % num_buckets


def murmur2(data: bytes) -> int:
    """
    32-bit murmur2 hash, ported verbatim from
    ``org.apache.kafka.common.utils.Utils#murmur2(byte[])``. Returns the
    unsigned 32-bit hash value; callers that need the Java ``int``
    (signed) representation should apply the two's-complement adjustment.

    All arithmetic is masked to 32 bits to emulate Java's wrap-around
    ``int`` semantics, since Python ints are arbitrary precision.
    """
    length = len(data)
    h = (_SEED ^ length) & _MASK_32
    length4 = length // 4

    for i in range(length4):
        i4 = i * 4
        k = (
            (data[i4]     & 0xFF)
            | ((data[i4 + 1] & 0xFF) << 8)
            | ((data[i4 + 2] & 0xFF) << 16)
            | ((data[i4 + 3] & 0xFF) << 24)
        )
        k = (k * _M) & _MASK_32
        k ^= (k >> _R)
        k = (k * _M) & _MASK_32
        h = (h * _M) & _MASK_32
        h ^= k

    tail_base = length & ~3
    rem = length % 4
    if rem >= 3:
        h ^= (data[tail_base + 2] & 0xFF) << 16
    if rem >= 2:
        h ^= (data[tail_base + 1] & 0xFF) << 8
    if rem >= 1:
        h ^= (data[tail_base] & 0xFF)
        h = (h * _M) & _MASK_32

    h ^= (h >> 13)
    h = (h * _M) & _MASK_32
    h ^= (h >> 15)
    return h & _MASK_32


consistent_bucket = udf(
    ConsistentBucket(),
    input_types=[DataTypes.STRING(), DataTypes.INT()],
    result_type=DataTypes.INT(),
)
