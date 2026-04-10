/**
 * Copyright (c) 2026 Jeffrey Jonathan Jennings
 *
 * @author Jeffrey Jonathan Jennings (J3)
 *
 *
 */
package ptf;

import java.time.Duration;
import java.time.Instant;

import org.apache.flink.table.annotation.ArgumentHint;
import org.apache.flink.table.annotation.ArgumentTrait;
import org.apache.flink.table.annotation.DataTypeHint;
import org.apache.flink.table.annotation.FunctionHint;
import org.apache.flink.table.annotation.StateHint;
import org.apache.flink.table.functions.ProcessTableFunction;
import org.apache.flink.types.Row;


/**
 * A {@link ProcessTableFunction} that detects abandoned shopping carts using
 * <strong>named timers</strong> and the <strong>inactivity pattern</strong>.
 *
 * <p>This PTF is structurally similar to {@link SessionTimeoutDetector} but
 * targets a different domain: e-commerce cart abandonment.  On every cart
 * event (add, remove, update) the function re-registers a named timer
 * {@code "cart_idle"}.  If no further activity occurs before the timer fires,
 * the cart is declared abandoned.
 *
 * <h3>Behaviour</h3>
 * <ol>
 *   <li>On each incoming cart event the function records the event in state
 *       and (re-)registers a named timer {@code "cart_idle"} that fires after
 *       a configurable idle window (default 24 hours).</li>
 *   <li>If another cart event arrives before the timer fires, the timer is
 *       replaced (same name), effectively resetting the idle clock.</li>
 *   <li>When a {@code "checkout"} event arrives, the cart is marked as
 *       checked out in state.  If the idle timer later fires, no abandonment
 *       event is emitted.</li>
 *   <li>When the timer fires and the cart has <em>not</em> been checked out,
 *       the function emits an {@code "abandoned_cart"} row and clears all
 *       state.</li>
 * </ol>
 *
 * <h3>Output columns</h3>
 * <ul>
 *   <li>{@code action}       &ndash; original action, or {@code "abandoned_cart"}</li>
 *   <li>{@code item}         &ndash; last item added/modified, or last-known item on abandonment</li>
 *   <li>{@code cart_value}   &ndash; running total cart value</li>
 *   <li>{@code item_count}   &ndash; number of distinct cart actions</li>
 *   <li>{@code is_abandoned} &ndash; {@code true} when emitted by the idle timer</li>
 * </ul>
 *
 * <p>The {@code cart_id} column is automatically passed through by Flink
 * via {@code PARTITION BY}.
 *
 * <h3>SQL invocation</h3>
 * <pre>{@code
 * SELECT *
 * FROM TABLE(
 *     AbandonedCartDetector(
 *         input   => TABLE cart_events PARTITION BY cart_id,
 *         on_time => DESCRIPTOR(event_time)
 *     )
 * );
 * }</pre>
 *
 * @see ProcessTableFunction
 */
@FunctionHint(output = @DataTypeHint(
    "ROW<action STRING, item STRING, " +
         "cart_value DOUBLE, item_count BIGINT, is_abandoned BOOLEAN>"
))
public class AbandonedCartDetector extends ProcessTableFunction<Row> {

    /** Idle window after which a cart is declared abandoned. */
    private static final Duration CART_IDLE_TIMEOUT = Duration.ofHours(24);

    /** Timer name — re-registering with the same name replaces the timer. */
    private static final String TIMER_NAME = "cart_idle";

    /**
     * Per-cart state, scoped to each {@code PARTITION BY} key.
     *
     * <p>Flink manages one instance per partition key and persists it across
     * invocations via checkpointing. Fields must be {@code public} for Flink's
     * reflection-based POJO serializer.
     */
    public static class CartState {
        /** Number of cart actions received. */
        public long itemCount = 0L;

        /** Running total value of the cart. */
        public double cartValue = 0.0;

        /** The most recently added or modified item. */
        public String lastItem = null;

        /** Whether the cart has been checked out. */
        public boolean checkedOut = false;
    }

    /**
     * Processes a single input row, updating per-cart state and (re-)setting
     * the idle timer.
     *
     * @param ctx   the runtime context provided by Flink
     * @param state per-partition-key state managed by Flink; injected and
     *              persisted automatically via {@link StateHint}
     * @param input a row from the input table with set semantics; requires
     *              an {@code on_time} descriptor for timer support
     */
    public void eval(
            Context ctx,
            @StateHint CartState state,
            @ArgumentHint({ArgumentTrait.SET_SEMANTIC_TABLE,
                           ArgumentTrait.REQUIRE_ON_TIME})
            Row input
    ) {
        String action   = input.getFieldAs("action");
        String item     = input.getFieldAs("item");
        Double itemValue = input.getFieldAs("item_value");

        // -- Update state ---------------------------------------------------------
        state.itemCount++;
        state.lastItem = item;

        if (itemValue != null) {
            if ("add".equals(action)) {
                state.cartValue += itemValue;
            } else if ("remove".equals(action)) {
                state.cartValue = Math.max(0.0, state.cartValue - itemValue);
            }
        }

        if ("checkout".equals(action)) {
            state.checkedOut = true;
        }

        // -- (Re-)register the idle timer -----------------------------------------
        // Registering a timer with the same name replaces the previous one,
        // effectively resetting the idle clock on every cart event.
        TimeContext<Instant> timeCtx = ctx.timeContext(Instant.class);
        timeCtx.registerOnTime(TIMER_NAME,
                timeCtx.time().plus(CART_IDLE_TIMEOUT));

        // -- Emit the enriched row ------------------------------------------------
        // cart_id is automatically passed through by Flink via PARTITION BY
        collect(Row.of(
                action,
                item,
                state.cartValue,
                state.itemCount,
                false               // not abandoned — regular cart event
        ));
    }

    /**
     * Fires when the idle timer elapses without being replaced by a new cart
     * event.  If the cart has not been checked out, emits an
     * {@code "abandoned_cart"} row and clears all state.
     *
     * @param onTimerCtx context identifying which timer fired
     * @param state      the same per-partition-key state available in
     *                   {@link #eval}
     */
    public void onTimer(OnTimerContext onTimerCtx, CartState state) {
        if (!state.checkedOut) {
            // -- Emit abandoned cart row -------------------------------------------
            collect(Row.of(
                    "abandoned_cart",
                    state.lastItem,     // carry forward last-known item
                    state.cartValue,    // cart value at time of abandonment
                    state.itemCount,    // total actions before abandonment
                    true                // this IS an abandonment event
            ));
        }

        // -- Clear state for this partition key -----------------------------------
        // Prevents stale state from accumulating for idle carts.
        state.itemCount  = 0L;
        state.cartValue  = 0.0;
        state.lastItem   = null;
        state.checkedOut = false;
    }
}
