"""
Copyright (c) 2026 Jeffrey Jonathan Jennings

Author: Jeffrey Jonathan Jennings (J3)

Driver that registers the Celsius/Fahrenheit scalar UDFs and runs a sample
pipeline against them.

Local run (embedded mini-cluster, no Flink/Kafka required)::

    uv run run_job.py

Cluster run (PyFlink job submitted to a Confluent Flink session cluster)::

    uv run flink run \\
        --python run_job.py \\
        --pyFiles celsius_to_fahrenheit.py,fahrenheit_to_celsius.py

When deployed via ``scripts/deploy-cp-scalar-udf-python.sh``, the UDFs are
registered directly via SQL ``CREATE FUNCTION ... LANGUAGE PYTHON`` against
Kafka source/sink tables, and this driver is not used.
"""
from pyflink.table import EnvironmentSettings, TableEnvironment

from celsius_to_fahrenheit import celsius_to_fahrenheit
from fahrenheit_to_celsius import fahrenheit_to_celsius


def main() -> None:
    t_env = TableEnvironment.create(EnvironmentSettings.in_streaming_mode())

    t_env.create_temporary_system_function("celsius_to_fahrenheit", celsius_to_fahrenheit)
    t_env.create_temporary_system_function("fahrenheit_to_celsius", fahrenheit_to_celsius)

    t_env.execute_sql(
        """
        CREATE TEMPORARY VIEW celsius_reading AS
        SELECT * FROM (VALUES
            (CAST(1000 AS BIGINT), CAST(  0.0 AS DOUBLE)),
            (CAST(1001 AS BIGINT), CAST( 20.0 AS DOUBLE)),
            (CAST(1002 AS BIGINT), CAST(100.0 AS DOUBLE)),
            (CAST(1003 AS BIGINT), CAST(-40.0 AS DOUBLE)),
            (CAST(1004 AS BIGINT), CAST(NULL  AS DOUBLE))
        ) AS t(sensor_id, celsius_temperature)
        """
    )

    t_env.execute_sql(
        """
        CREATE TEMPORARY VIEW fahrenheit_reading AS
        SELECT * FROM (VALUES
            (CAST(2000 AS BIGINT), CAST( 32.0 AS DOUBLE)),
            (CAST(2001 AS BIGINT), CAST( 68.0 AS DOUBLE)),
            (CAST(2002 AS BIGINT), CAST(212.0 AS DOUBLE)),
            (CAST(2003 AS BIGINT), CAST(-40.0 AS DOUBLE)),
            (CAST(2004 AS BIGINT), CAST(NULL  AS DOUBLE))
        ) AS t(sensor_id, fahrenheit_temperature)
        """
    )

    print("\n--- celsius_to_fahrenheit ---")
    t_env.execute_sql(
        """
        SELECT sensor_id,
               celsius_temperature,
               celsius_to_fahrenheit(celsius_temperature) AS fahrenheit_temperature
          FROM celsius_reading
        """
    ).print()

    print("\n--- fahrenheit_to_celsius ---")
    t_env.execute_sql(
        """
        SELECT sensor_id,
               fahrenheit_temperature,
               fahrenheit_to_celsius(fahrenheit_temperature) AS celsius_temperature
          FROM fahrenheit_reading
        """
    ).print()


if __name__ == "__main__":
    main()
