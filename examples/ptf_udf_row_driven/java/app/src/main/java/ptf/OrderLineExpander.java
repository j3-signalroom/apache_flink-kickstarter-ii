/**
 * Copyright (c) 2026 Jeffrey Jonathan Jennings
 *
 * @author Jeffrey Jonathan Jennings (J3)
 *
 *
 */
package ptf;

import org.apache.flink.table.annotation.ArgumentHint;
import org.apache.flink.table.annotation.ArgumentTrait;
import org.apache.flink.table.annotation.DataTypeHint;
import org.apache.flink.table.annotation.FunctionHint;
import org.apache.flink.table.functions.ProcessTableFunction;
import org.apache.flink.types.Row;

/**
 * A {@link ProcessTableFunction} that expands a single order row into multiple
 * line-item rows by splitting a comma-separated {@code items} field.
 *
 * <p>This PTF uses <strong>row semantics</strong>
 * ({@code ArgumentTrait.ROW_SEMANTIC_TABLE}), meaning each input row is
 * processed independently with no state and no {@code PARTITION BY}. The
 * framework is free to distribute rows across virtual processors in any order.
 *
 * <h3>Input columns</h3>
 * <ul>
 *   <li>{@code order_id}    – unique order identifier</li>
 *   <li>{@code customer}    – customer name</li>
 *   <li>{@code items}       – comma-separated list of item names
 *                             (e.g. {@code "widget,gadget,gizmo"})</li>
 *   <li>{@code quantities}  – comma-separated list of quantities, positionally
 *                             aligned with {@code items}
 *                             (e.g. {@code "2,1,5"})</li>
 * </ul>
 *
 * <h3>Output columns</h3>
 * <ul>
 *   <li>{@code order_id}     – passed through from the input</li>
 *   <li>{@code customer}     – passed through from the input</li>
 *   <li>{@code item_name}    – a single item extracted from {@code items}</li>
 *   <li>{@code quantity}     – the corresponding quantity from {@code quantities}</li>
 *   <li>{@code line_number}  – 1-based position of this item in the order</li>
 * </ul>
 *
 * <h3>SQL invocation</h3>
 * <pre>{@code
 * SELECT *
 * FROM TABLE(
 *     OrderLineExpander(
 *         input => TABLE orders
 *     )
 * );
 * }</pre>
 *
 * @see ProcessTableFunction
 */
@FunctionHint(output = @DataTypeHint(
    "ROW<order_id STRING, customer STRING, " +
         "item_name STRING, quantity INT, line_number INT>"
))
public class OrderLineExpander extends ProcessTableFunction<Row> {

    /**
     * Processes a single order row, emitting one output row per item in the
     * comma-separated {@code items} field.
     *
     * <p>If the {@code items} or {@code quantities} fields are {@code null} or
     * empty, no rows are emitted for that order. If {@code quantities} has fewer
     * entries than {@code items}, missing quantities default to {@code 1}.
     *
     * @param input a single order row with row semantics (no partitioning,
     *              no state)
     */
    public void eval(
            @ArgumentHint(ArgumentTrait.ROW_SEMANTIC_TABLE)
            Row input
    ) {
        String orderId    = input.getFieldAs("order_id");
        String customer   = input.getFieldAs("customer");
        String items      = input.getFieldAs("items");
        String quantities = input.getFieldAs("quantities");

        // ── Guard: nothing to expand ──────────────────────────────────────────
        if (items == null || items.isEmpty()) {
            return;
        }

        String[] itemParts     = items.split(",", -1);
        String[] quantityParts = (quantities != null && !quantities.isEmpty())
                ? quantities.split(",", -1)
                : new String[0];

        // ── Expand each item into its own row ─────────────────────────────────
        for (int lineNumber = 0; lineNumber < itemParts.length; lineNumber++) {
            String itemName = itemParts[lineNumber].trim();
            int quantity = 1; // default quantity when not specified
            if (lineNumber < quantityParts.length) {
                try {
                    quantity = Integer.parseInt(quantityParts[lineNumber].trim());
                } catch (NumberFormatException ignored) {
                    // keep default of 1
                }
            }

            collect(Row.of(
                    orderId,
                    customer,
                    itemName,
                    quantity,
                    lineNumber + 1   // 1-based line number
            ));
        }
    }
}
