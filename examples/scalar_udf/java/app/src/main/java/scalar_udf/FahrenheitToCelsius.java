/**
 * Copyright (c) 2026 Jeffrey Jonathan Jennings
 *
 * @author Jeffrey Jonathan Jennings (J3)
 *
 *
 */
package scalar_udf;

import org.apache.flink.table.functions.ScalarFunction;

/**
 * A Flink scalar user-defined function (UDF) that converts a temperature value
 * from degrees Fahrenheit to degrees Celsius.
 *
 * <p>Being a scalar UDF, it is invoked once per input row and returns exactly
 * one value per invocation. The function is stateless and deterministic: the
 * same input will always produce the same output, which allows Flink's planner
 * to safely cache, reorder, and replay calls during failure recovery.
 *
 * <h3>SQL invocation</h3>
 * <pre>{@code
 * CREATE FUNCTION FahrenheitToCelsius
 *     AS 'scalar_udf.FahrenheitToCelsius'
 *     LANGUAGE JAVA;
 *
 * SELECT temperature_in_fahrenheit,
 *        FahrenheitToCelsius(temperature_in_fahrenheit) AS temperature_in_celsius
 *   FROM readings;
 * }</pre>
 */
public class FahrenheitToCelsius extends ScalarFunction {

    /**
     * Converts a Fahrenheit temperature to its Celsius equivalent using the
     * formula {@code C = (F - 32) * 5/9}.
     *
     * <p>Flink discovers scalar UDF logic by reflecting on public {@code eval}
     * methods, so the method name and visibility must remain as declared.
     *
     * @param fahrenheit the temperature in degrees Fahrenheit; may be {@code null}
     *                to represent a SQL {@code NULL} value
     * @return the temperature in degrees Fahrenheit, or {@code null} if the
     *         input was {@code null} (preserving SQL {@code NULL} semantics)
     */
    public Double eval(Double fahrenheit) {
        if (fahrenheit == null)
            return null;
        return (fahrenheit - 32) * 5.0 / 9.0;
    }
}