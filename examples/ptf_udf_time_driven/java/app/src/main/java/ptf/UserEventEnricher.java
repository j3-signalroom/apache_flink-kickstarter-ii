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
import org.apache.flink.table.annotation.StateHint;
import org.apache.flink.table.functions.ProcessTableFunction;
import org.apache.flink.types.Row;

/**
 * A {@link ProcessTableFunction} that enriches each event with a per-user
 * running count and a session ID.
 *
 * <p>A new session starts whenever the {@code event_type} is {@code "login"},
 * resetting the per-session event count. State is managed entirely by
 * row-driven transitions; no timers are used.
 *
 * <h3>Output columns</h3>
 * <ul>
 *   <li>{@code event_type}  – the original event type</li>
 *   <li>{@code payload}     – the original payload</li>
 *   <li>{@code session_id}  – monotonically increasing session identifier</li>
 *   <li>{@code event_count} – position of this event within the session</li>
 *   <li>{@code last_event}  – the most recently processed event type</li>
 * </ul>
 *
 * <p>The {@code user_id} column is automatically passed through by Flink
 * via {@code PARTITION BY}.
 *
 * <h3>SQL invocation</h3>
 * <pre>{@code
 * SELECT *
 * FROM TABLE(
 *     UserEventEnricher(
 *         input => TABLE user_events PARTITION BY user_id
 *     )
 * );
 * }</pre>
 *
 * @see ProcessTableFunction
 */
@FunctionHint(output = @DataTypeHint(
    "ROW<event_type STRING, payload STRING, " +
         "session_id BIGINT, event_count BIGINT, last_event STRING>"
))
public class UserEventEnricher extends ProcessTableFunction<Row> {

    /**
     * Per-user session state, scoped to each {@code PARTITION BY} key.
     *
     * <p>Flink manages one instance per partition key and persists it across
     * invocations via checkpointing. Fields must be {@code public} for Flink's
     * reflection-based POJO serializer.
     */
    public static class UserState {
        /** Running count of events within the current session. */
        public long eventCount  = 0L;

        /** Monotonically increasing session identifier; incremented on each login. */
        public long sessionId   = 0L;

        /** The {@code event_type} of the most recently processed row. */
        public String lastEvent = null;
    }

    /**
     * Processes a single input row, updating per-user session state and
     * emitting an enriched row.
     *
     * <p>A new session begins on every {@code "login"} event, resetting the
     * per-session event count.
     *
     * @param ctx   the runtime context provided by Flink
     * @param state per-partition-key state managed by Flink; injected and
     *              persisted automatically via {@link StateHint}
     * @param input a row from the input table with set semantics
     */
    public void eval(
            Context ctx,
            @StateHint UserState state,
            @ArgumentHint(ArgumentTrait.SET_SEMANTIC_TABLE)
            Row input
    ) {
        String eventType = input.getFieldAs("event_type");
        String payload   = input.getFieldAs("payload");

        // ── State transitions ─────────────────────────────────────────────────
        // New session on every "login" event
        if ("login".equalsIgnoreCase(eventType)) {
            state.sessionId++;
            state.eventCount = 0L;   // reset per-session count
        }

        state.eventCount++;
        state.lastEvent = eventType;

        // ── Emit enriched row ─────────────────────────────────────────────────
        // user_id is automatically passed through by Flink via PARTITION BY
        collect(Row.of(
                eventType,
                payload,
                state.sessionId,    // which session this event belongs to
                state.eventCount,   // position of this event within the session
                state.lastEvent     // redundant here but shows state read-back
        ));
    }
}