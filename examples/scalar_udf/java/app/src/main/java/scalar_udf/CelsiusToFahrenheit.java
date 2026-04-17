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
 * from degrees Celsius to degrees Fahrenheit.
 *
 * <p>Being a scalar UDF, it is invoked once per input row and returns exactly
 * one value per invocation. The function is stateless and deterministic: the
 * same input will always produce the same output, which allows Flink's planner
 * to safely cache, reorder, and replay calls during failure recovery.
 *
 * <h3>SQL invocation</h3>
 * <pre>{@code
 * CREATE FUNCTION CelsiusToFahrenheit
 *     AS 'scalar_udf.CelsiusToFahrenheit'
 *     LANGUAGE JAVA;
 *
 * SELECT temperature_in_celsius,
 *        CelsiusToFahrenheit(temperature_in_celsius) AS temperature_in_fahrenheit
 *   FROM readings;
 * }</pre>
 */
public class CelsiusToFahrenheit extends ScalarFunction {

    /**
     * Converts a Celsius temperature to its Fahrenheit equivalent using the
     * formula {@code F = (C * 9/5) + 32}.
     *
     * <p>Flink discovers scalar UDF logic by reflecting on public {@code eval}
     * methods, so the method name and visibility must remain as declared.
     *
     * @param celsius the temperature in degrees Celsius; may be {@code null}
     *                to represent a SQL {@code NULL} value
     * @return the temperature in degrees Fahrenheit, or {@code null} if the
     *         input was {@code null} (preserving SQL {@code NULL} semantics)
     */
    public Double eval(Double celsius) {
        if (celsius == null)
            return null;
        return (celsius * 9.0 / 5.0) + 32.0;
    }
}