"""
Copyright (c) 2026 Jeffrey Jonathan Jennings

Author: Jeffrey Jonathan Jennings (J3)
"""
from typing import Optional

from pyflink.table.udf import ScalarFunction, udf
from pyflink.table import DataTypes


class FahrenheitToCelsius(ScalarFunction):
    """
    A Flink scalar user-defined function (UDF) that converts a temperature value
    from degrees Fahrenheit to degrees Celsius.

    Being a scalar UDF, it is invoked once per input row and returns exactly one
    value per invocation. The function is stateless and deterministic: the same
    input always produces the same output, which allows Flink's planner to
    safely cache, reorder, and replay calls during failure recovery.

    SQL invocation::

        t_env.create_temporary_system_function(
            "FahrenheitToCelsius",
            fahrenheit_to_celsius,
        )

        t_env.execute_sql('''
            SELECT temperature_in_fahrenheit,
                   FahrenheitToCelsius(temperature_in_fahrenheit) AS temperature_in_celsius
              FROM readings
        ''').print()
    """

    def eval(self, fahrenheit: Optional[float]) -> Optional[float]:
        """
        Convert a Fahrenheit temperature to its Celsius equivalent using the
        formula ``C = (F - 32) * 5/9``.

        PyFlink discovers scalar UDF logic by looking for an ``eval`` method on
        the ``ScalarFunction`` subclass, so the method name must remain as
        declared.

        :param fahrenheit: temperature in degrees Fahrenheit; may be ``None``
            to represent a SQL ``NULL`` value.
        :return: temperature in degrees Celsius, or ``None`` if the input was
            ``None`` (preserving SQL ``NULL`` semantics).
        """
        if fahrenheit is None:
            return None
        return (fahrenheit - 32.0) * 5.0 / 9.0


fahrenheit_to_celsius = udf(
    FahrenheitToCelsius(),
    input_types=[DataTypes.DOUBLE()],
    result_type=DataTypes.DOUBLE(),
)
