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
 * A {@link ProcessTableFunction} that monitors service-level agreement (SLA)
 * compliance by scheduling a deadline timer for each incoming request using
 * <strong>unnamed timers</strong>.
 *
 * <p>This PTF implements the <strong>scheduling pattern</strong>: each request
 * independently registers its own SLA deadline timer.  When the timer fires,
 * the function checks whether the request has been resolved.  If not, it emits
 * an SLA breach event.
 *
 * <h3>Behaviour</h3>
 * <ol>
 *   <li>When a request arrives with status {@code "opened"}, the function
 *       records it in state and registers an <strong>unnamed</strong> timer
 *       that fires after a configurable SLA window (default 10 minutes).</li>
 *   <li>When a request arrives with status {@code "resolved"}, the function
 *       marks the request as resolved in state.</li>
 *   <li>All other status updates (e.g., {@code "in_progress"}) are recorded
 *       in state and emitted as enriched rows.</li>
 *   <li>When the SLA deadline timer fires, the function checks the current
 *       state.  If the request is still not resolved, it emits an
 *       {@code "sla_breach"} event.</li>
 * </ol>
 *
 * <h3>Output columns</h3>
 * <ul>
 *   <li>{@code status}        &ndash; original status, or {@code "sla_breach"}</li>
 *   <li>{@code service_name}  &ndash; the service that owns this request</li>
 *   <li>{@code update_count}  &ndash; total status updates received</li>
 *   <li>{@code is_resolved}   &ndash; whether the request has been resolved</li>
 *   <li>{@code is_breach}     &ndash; {@code true} when emitted by the SLA timer</li>
 * </ul>
 *
 * <p>The {@code request_id} column is automatically passed through by Flink
 * via {@code PARTITION BY}.
 *
 * <h3>SQL invocation</h3>
 * <pre>{@code
 * SELECT *
 * FROM TABLE(
 *     SlaMonitor(
 *         input   => TABLE service_requests PARTITION BY request_id,
 *         on_time => DESCRIPTOR(event_time)
 *     )
 * );
 * }</pre>
 *
 * @see ProcessTableFunction
 */
@FunctionHint(output = @DataTypeHint(
    "ROW<status STRING, service_name STRING, " +
         "update_count BIGINT, is_resolved BOOLEAN, is_breach BOOLEAN>"
))
public class SlaMonitor extends ProcessTableFunction<Row> {

    /** SLA window after which a breach is emitted if the request is not resolved. */
    private static final Duration SLA_DEADLINE = Duration.ofMinutes(10);

    /**
     * Per-request state, scoped to each {@code PARTITION BY} key.
     *
     * <p>Flink manages one instance per partition key and persists it across
     * invocations via checkpointing. Fields must be {@code public} for Flink's
     * reflection-based POJO serializer.
     */
    public static class RequestState {
        /** Total status updates received for this request. */
        public long updateCount = 0L;

        /** Whether the request has been resolved. */
        public boolean resolved = false;

        /** The service that owns this request. */
        public String serviceName = null;

        /** The most recent status of the request. */
        public String lastStatus = null;
    }

    /**
     * Processes a single input row, updating per-request state and optionally
     * registering an SLA deadline timer.
     *
     * @param ctx   the runtime context provided by Flink
     * @param state per-partition-key state managed by Flink; injected and
     *              persisted automatically via {@link StateHint}
     * @param input a row from the input table with set semantics; requires
     *              an {@code on_time} descriptor for timer support
     */
    public void eval(
            Context ctx,
            @StateHint RequestState state,
            @ArgumentHint(ArgumentTrait.SET_SEMANTIC_TABLE)
            Row input
    ) {
        String status      = input.getFieldAs("status");
        String serviceName = input.getFieldAs("service_name");

        // -- Update state ---------------------------------------------------------
        state.updateCount++;
        state.serviceName = serviceName;
        state.lastStatus  = status;

        if ("resolved".equals(status)) {
            state.resolved = true;
        }

        // -- Register SLA deadline timer on "opened" -----------------------------
        // Each "opened" request gets its own unnamed timer.  The timer fires
        // regardless of later status updates — on fire we check if the request
        // was resolved in time.
        if ("opened".equals(status)) {
            TimeContext<Instant> timeCtx = ctx.timeContext(Instant.class);
            timeCtx.registerOnTime(timeCtx.time().plus(SLA_DEADLINE));
        }

        // -- Emit the enriched row ------------------------------------------------
        // request_id is automatically passed through by Flink via PARTITION BY
        collect(Row.of(
                status,
                serviceName,
                state.updateCount,
                state.resolved,
                false               // not a breach — regular status update
        ));
    }

    /**
     * Fires when the SLA deadline elapses.  If the request has not been
     * resolved, emits an {@code "sla_breach"} event.
     *
     * @param onTimerCtx context identifying which timer fired
     * @param state      the same per-partition-key state available in
     *                   {@link #eval}
     */
    public void onTimer(OnTimerContext onTimerCtx, RequestState state) {
        if (!state.resolved) {
            // -- Emit SLA breach row ----------------------------------------------
            collect(Row.of(
                    "sla_breach",
                    state.serviceName,
                    state.updateCount,
                    false,              // still not resolved
                    true                // this IS an SLA breach event
            ));
        }
    }
}
