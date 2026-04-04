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
 * A {@link ProcessTableFunction} that schedules an independent follow-up for
 * every incoming event using <strong>unnamed timers</strong>.
 *
 * <p>This PTF is <strong>timer-driven</strong> like the companion
 * {@code SessionTimeoutDetector}, but it uses <em>unnamed</em> timers instead
 * of <em>named</em> ones.  The difference is crucial:
 *
 * <ul>
 *   <li><strong>Named timers</strong> (the inactivity pattern) &mdash;
 *       re-registering a timer with the same name <em>replaces</em> the
 *       previous one.  Only the latest timer fires.</li>
 *   <li><strong>Unnamed timers</strong> (this example) &mdash; every call to
 *       {@code registerOnTime(time)} <em>adds</em> a new timer.  All timers
 *       fire independently.</li>
 * </ul>
 *
 * <h3>Behaviour</h3>
 * <ol>
 *   <li>On each incoming event the function records the event in state and
 *       registers an <strong>unnamed</strong> timer that fires after a
 *       configurable follow-up delay (default 2 minutes).</li>
 *   <li>If additional events arrive before earlier timers fire, each event
 *       gets its own independent timer &mdash; none are replaced.</li>
 *   <li>When each timer fires, the function emits a
 *       {@code "follow_up"} row carrying a snapshot of the current state.</li>
 * </ol>
 *
 * <h3>Output columns</h3>
 * <ul>
 *   <li>{@code event_type}     &ndash; original event type, or {@code "follow_up"}</li>
 *   <li>{@code payload}        &ndash; original payload, or last-seen payload on follow-up</li>
 *   <li>{@code event_count}    &ndash; total events seen so far</li>
 *   <li>{@code follow_up_count}&ndash; total follow-up events emitted so far</li>
 *   <li>{@code is_follow_up}   &ndash; {@code true} when emitted by a timer</li>
 * </ul>
 *
 * <p>The {@code user_id} column is automatically passed through by Flink
 * via {@code PARTITION BY}.
 *
 * <h3>SQL invocation</h3>
 * <pre>{@code
 * SELECT *
 * FROM TABLE(
 *     PerEventFollowUp(
 *         input   => TABLE user_actions PARTITION BY user_id,
 *         on_time => DESCRIPTOR(event_time)
 *     )
 * );
 * }</pre>
 *
 * @see ProcessTableFunction
 */
@FunctionHint(output = @DataTypeHint(
    "ROW<event_type STRING, payload STRING, " +
         "event_count BIGINT, follow_up_count BIGINT, is_follow_up BOOLEAN>"
))
public class PerEventFollowUp extends ProcessTableFunction<Row> {

    /** Delay after which each event's follow-up is emitted. */
    private static final Duration FOLLOW_UP_DELAY = Duration.ofMinutes(2);

    /**
     * Per-user state, scoped to each {@code PARTITION BY} key.
     *
     * <p>Flink manages one instance per partition key and persists it across
     * invocations via checkpointing. Fields must be {@code public} for Flink's
     * reflection-based POJO serializer.
     */
    public static class FollowUpState {
        /** Total events received for this partition key. */
        public long eventCount = 0L;

        /** Total follow-up events emitted for this partition key. */
        public long followUpCount = 0L;

        /** The {@code event_type} of the most recently processed row. */
        public String lastEventType = null;

        /** The {@code payload} of the most recently processed row. */
        public String lastPayload = null;
    }

    /**
     * Processes a single input row, updating per-user state and registering
     * an unnamed timer for the follow-up.
     *
     * @param ctx   the runtime context provided by Flink
     * @param state per-partition-key state managed by Flink; injected and
     *              persisted automatically via {@link StateHint}
     * @param input a row from the input table with set semantics; requires
     *              an {@code on_time} descriptor for timer support
     */
    public void eval(
            Context ctx,
            @StateHint FollowUpState state,
            @ArgumentHint(ArgumentTrait.SET_SEMANTIC_TABLE)
            Row input
    ) {
        String eventType = input.getFieldAs("event_type");
        String payload   = input.getFieldAs("payload");

        // -- Update state ---------------------------------------------------------
        state.eventCount++;
        state.lastEventType = eventType;
        state.lastPayload   = payload;

        // -- Register an unnamed timer --------------------------------------------
        // Unlike named timers, unnamed timers do NOT replace each other.
        // Every call adds a new, independent timer.  If three events arrive
        // within the follow-up window, all three timers will fire.
        TimeContext<Instant> timeCtx = ctx.timeContext(Instant.class);
        timeCtx.registerOnTime(timeCtx.time().plus(FOLLOW_UP_DELAY));

        // -- Emit the enriched row ------------------------------------------------
        // user_id is automatically passed through by Flink via PARTITION BY
        collect(Row.of(
                eventType,
                payload,
                state.eventCount,
                state.followUpCount,
                false               // not a follow-up -- regular event
        ));
    }

    /**
     * Fires independently for <em>every</em> previously registered unnamed
     * timer.  Emits a {@code "follow_up"} row with a snapshot of the current
     * state.
     *
     * @param onTimerCtx context identifying which timer fired
     * @param state      the same per-partition-key state available in
     *                   {@link #eval}
     */
    public void onTimer(OnTimerContext onTimerCtx, FollowUpState state) {
        // -- Increment follow-up counter ------------------------------------------
        state.followUpCount++;

        // -- Emit follow-up row ---------------------------------------------------
        collect(Row.of(
                "follow_up",
                state.lastPayload,      // carry forward last-known payload
                state.eventCount,       // total events at time of follow-up
                state.followUpCount,    // running follow-up count
                true                    // this IS a follow-up event
        ));
    }
}
