"""
Copyright (c) 2026 Jeffrey Jonathan Jennings

Author: Jeffrey Jonathan Jennings (J3)
"""
from typing import Optional

from pyflink.table.udf import ScalarFunction, udf
from pyflink.table import DataTypes


class CelsiusToFahrenheit(ScalarFunction):
    """
    A Flink scalar user-defined function (UDF) that converts a temperature value
    from degrees Celsius to degrees Fahrenheit.

    Being a scalar UDF, it is invoked once per input row and returns exactly one
    value per invocation. The function is stateless and deterministic: the same
    input always produces the same output, which allows Flink's planner to
    safely cache, reorder, and replay calls during failure recovery.

    SQL invocation::

        t_env.create_temporary_system_function(
            "CelsiusToFahrenheit",
            celsius_to_fahrenheit,
        )

        t_env.execute_sql('''
            SELECT temperature_in_celsius,
                   CelsiusToFahrenheit(temperature_in_celsius) AS temperature_in_fahrenheit
              FROM readings
        ''').print()
    """

    def eval(self, celsius: Optional[float]) -> Optional[float]:
        """
        Convert a Celsius temperature to its Fahrenheit equivalent using the
        formula ``F = (C * 9/5) + 32``.

        PyFlink discovers scalar UDF logic by looking for an ``eval`` method on
        the ``ScalarFunction`` subclass, so the method name must remain as
        declared.

        :param celsius: temperature in degrees Celsius; may be ``None`` to
            represent a SQL ``NULL`` value.
        :return: temperature in degrees Fahrenheit, or ``None`` if the input
            was ``None`` (preserving SQL ``NULL`` semantics).
        """
        if celsius is None:
            return None
        return (celsius * 9.0 / 5.0) + 32.0


celsius_to_fahrenheit = udf(
    CelsiusToFahrenheit(),
    input_types=[DataTypes.DOUBLE()],
    result_type=DataTypes.DOUBLE(),
)
