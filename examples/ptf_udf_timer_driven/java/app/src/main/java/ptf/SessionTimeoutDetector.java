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
 * A {@link ProcessTableFunction} that detects user session timeouts using
 * event-time timers.
 *
 * <p>This PTF is <strong>timer-driven</strong>: it registers a timer on every
 * event and emits a {@code "session_timeout"} row when the timer fires
 * without a subsequent event.
 *
 * <h3>Behaviour</h3>
 * <ol>
 *   <li>On each incoming event the function records the event in state and
 *       (re-)registers a named timer {@code "inactivity"} that fires after
 *       a configurable inactivity window (default 5 minutes).</li>
 *   <li>If another event arrives before the timer fires, the timer is
 *       replaced (same name), effectively resetting the inactivity clock.</li>
 *   <li>When the timer fires (no new event within the window), the function
 *       emits a {@code "session_timeout"} row and clears all state.</li>
 * </ol>
 *
 * <h3>Output columns</h3>
 * <ul>
 *   <li>{@code event_type}   – original event type, or {@code "session_timeout"}</li>
 *   <li>{@code payload}      – original payload, or last-seen payload on timeout</li>
 *   <li>{@code event_count}  – total events seen in the session so far</li>
 *   <li>{@code timed_out}    – {@code true} when emitted by the timer</li>
 * </ul>
 *
 * <p>The {@code user_id} column is automatically passed through by Flink
 * via {@code PARTITION BY}.
 *
 * <h3>SQL invocation</h3>
 * <pre>{@code
 * SELECT *
 * FROM TABLE(
 *     SessionTimeoutDetector(
 *         input   => TABLE user_activity PARTITION BY user_id,
 *         on_time => DESCRIPTOR(event_time)
 *     )
 * );
 * }</pre>
 *
 * @see ProcessTableFunction
 */
@FunctionHint(output = @DataTypeHint(
    "ROW<event_type STRING, payload STRING, " +
         "event_count BIGINT, timed_out BOOLEAN>"
))
public class SessionTimeoutDetector extends ProcessTableFunction<Row> {

    /** Inactivity window after which a timeout is emitted. */
    private static final Duration INACTIVITY_TIMEOUT = Duration.ofMinutes(5);

    /** Timer name — re-registering with the same name replaces the timer. */
    private static final String TIMER_NAME = "inactivity";

    /**
     * Per-user session state, scoped to each {@code PARTITION BY} key.
     *
     * <p>Flink manages one instance per partition key and persists it across
     * invocations via checkpointing. Fields must be {@code public} for Flink's
     * reflection-based POJO serializer.
     */
    public static class SessionState {
        /** Total events received within the current session. */
        public long eventCount = 0L;

        /** The {@code event_type} of the most recently processed row. */
        public String lastEventType = null;

        /** The {@code payload} of the most recently processed row. */
        public String lastPayload = null;
    }

    /**
     * Processes a single input row, updating per-user state and (re-)setting
     * the inactivity timer.
     *
     * @param ctx   the runtime context provided by Flink
     * @param state per-partition-key state managed by Flink; injected and
     *              persisted automatically via {@link StateHint}
     * @param input a row from the input table with set semantics; requires
     *              an {@code on_time} descriptor for timer support
     */
    public void eval(
            Context ctx,
            @StateHint SessionState state,
            @ArgumentHint(ArgumentTrait.SET_SEMANTIC_TABLE)
            Row input
    ) {
        String eventType = input.getFieldAs("event_type");
        String payload   = input.getFieldAs("payload");

        // ── Update state ──────────────────────────────────────────────────
        state.eventCount++;
        state.lastEventType = eventType;
        state.lastPayload   = payload;

        // ── (Re-)register the inactivity timer ────────────────────────────
        // Registering a timer with the same name replaces the previous one,
        // effectively resetting the inactivity clock on every event.
        TimeContext<Instant> timeCtx = ctx.timeContext(Instant.class);
        timeCtx.registerOnTime(TIMER_NAME,
                timeCtx.time().plus(INACTIVITY_TIMEOUT));

        // ── Emit the enriched row ─────────────────────────────────────────
        // user_id is automatically passed through by Flink via PARTITION BY
        collect(Row.of(
                eventType,
                payload,
                state.eventCount,
                false               // not a timeout — regular event
        ));
    }

    /**
     * Fires when the inactivity timer elapses without being replaced by a
     * new event. Emits a {@code "session_timeout"} row and clears all state
     * for this partition key.
     *
     * @param onTimerCtx context identifying which timer fired
     * @param state      the same per-partition-key state available in
     *                   {@link #eval}
     */
    public void onTimer(OnTimerContext onTimerCtx, SessionState state) {
        // ── Emit timeout row ──────────────────────────────────────────────
        collect(Row.of(
                "session_timeout",
                state.lastPayload,  // carry forward last-known payload
                state.eventCount,   // total events before timeout
                true                // this IS a timeout event
        ));

        // ── Clear state for this partition key ────────────────────────────
        // Prevents stale state from accumulating for inactive users.
        state.eventCount    = 0L;
        state.lastEventType = null;
        state.lastPayload   = null;
    }
}
