package ptf;

import org.apache.flink.table.annotation.ArgumentHint;
import org.apache.flink.table.annotation.ArgumentTrait;
import org.apache.flink.table.annotation.DataTypeHint;
import org.apache.flink.table.annotation.FunctionHint;
import org.apache.flink.table.annotation.StateHint;
import org.apache.flink.table.functions.ProcessTableFunction;
import org.apache.flink.types.Row;

/**
 * Enriches each event with a per-user running count and a session ID.
 * A new session starts whenever the event_type is "login".
 *
 * No timers. State is managed entirely by row-driven transitions.
 *
 * SQL invocation:
 *
 *   SELECT *
 *   FROM TABLE(
 *       UserEventEnricher(
 *           input => TABLE events PARTITION BY user_id
 *       )
 *   );
 */
@FunctionHint(output = @DataTypeHint(
    "ROW<event_type STRING, payload STRING, " +
         "session_id BIGINT, event_count BIGINT, last_event STRING>"
))
public class UserEventEnricher extends ProcessTableFunction<Row> {

    // ── State POJO ────────────────────────────────────────────────────────────
    // One instance per PARTITION BY key (i.e. per user_id).
    // Fields must be public for Flink's reflection-based serialization.
    public static class UserState {
        public long eventCount  = 0L;
        public long sessionId   = 0L;
        public String lastEvent = null;
    }

    // ── eval ──────────────────────────────────────────────────────────────────

    public void eval(
            Context ctx,

            // Flink injects and persists this POJO per partition key.
            @StateHint UserState state,

            // TABLE_AS_SET → keyed, stateful virtual processor.
            // No REQUIRE_ON_TIME since we don't use timers or event-time here.
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