#!/bin/bash

#
# *** Script Syntax ***
# ./deploy-cp-ptf-udf-time-driven.sh <create | destroy> [--namespace=confluent]
#                                                        [--flink-cluster=flink-basic]
#
#

set -euo pipefail  # Stop on error, undefined variables, and pipeline errors

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NO_COLOR='\033[0m'

print_info() {
    echo -e "${GREEN}[INFO]${NO_COLOR} $1"
}

print_warn() {
    echo -e "${YELLOW}[WARN]${NO_COLOR} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NO_COLOR} $1"
}

print_step() {
    echo -e "${BLUE}[STEP]${NO_COLOR} $1"
}

# Resolve directories relative to script location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TIME_JAR_PATH="$PROJECT_DIR/examples/ptf_udf_time_driven/java/app/build/libs/app-1.0.0-SNAPSHOT.jar"
TIME_JAR_POD_PATH="/opt/flink/usrlib/session-timeout-detector.jar"

# Defaults (overridable via arguments)
NAMESPACE="confluent"
FLINK_CLUSTER_NAME="flink-basic"

# Check required command (create or destroy) was supplied
case "${1:-}" in
  create)
    CREATE_ACTION=true;;
  destroy)
    CREATE_ACTION=false;;
  *)
    echo
    print_error "You did not specify one of the commands: create | destroy."
    echo
    print_error "Usage: $(basename "$0") <create | destroy> [--namespace=confluent] [--flink-cluster=flink-basic]"
    echo
    exit 1
    ;;
esac

# Parse optional arguments
shift
for arg in "$@"; do
    case $arg in
        --namespace=*)
            NAMESPACE="${arg#*=}";;
        --flink-cluster=*)
            FLINK_CLUSTER_NAME="${arg#*=}";;
        *)
            print_error "Invalid argument: $arg"
            print_error "Usage: $(basename "$0") <create | destroy> [--namespace=confluent] [--flink-cluster=flink-basic]"
            exit 1
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Helper: find a JobManager pod for the Flink cluster
# ---------------------------------------------------------------------------
get_jobmanager_pod() {
    kubectl get pods -n "$NAMESPACE" -l component=jobmanager \
        --no-headers -o custom-columns=":metadata.name" 2>/dev/null | head -1
}

# ---------------------------------------------------------------------------
# Helper: execute SQL on the Flink cluster via sql-client.sh -f
#
# Usage: run_sql "label" "sql-statements"
#   All statements are executed in a single sql-client session so that
#   tables created by earlier statements are visible to later ones.
#   The SQL is piped via stdin to avoid temp-file races.
# ---------------------------------------------------------------------------
run_sql() {
    local label="$1"
    local sql="$2"
    local jm_pod
    jm_pod=$(get_jobmanager_pod)

    if [ -z "$jm_pod" ]; then
        print_error "No JobManager pod found for cluster '${FLINK_CLUSTER_NAME}'."
        exit 1
    fi

    print_step "Executing: ${label}"

    # Write SQL to a temp file in the pod and execute it
    local remote_sql="/tmp/deploy-sql-$$.sql"
    echo "$sql" | kubectl exec -n "$NAMESPACE" -i "$jm_pod" -- sh -c "cat > ${remote_sql}"

    local output
    output=$(kubectl exec -n "$NAMESPACE" "$jm_pod" -- \
        /opt/flink/bin/sql-client.sh embedded -f "$remote_sql" 2>&1)
    local rc=$?

    # Clean up temp file
    kubectl exec -n "$NAMESPACE" "$jm_pod" -- rm -f "$remote_sql" 2>/dev/null || true

    # Check for errors in the output (sql-client may return 0 even on SQL errors)
    if [ $rc -ne 0 ] || echo "$output" | python3 -c "
import sys
text = sys.stdin.read()
if '[ERROR]' in text or 'org.apache.flink.table.api.ValidationException' in text:
    sys.exit(1)
sys.exit(0)
" 2>/dev/null; [ $? -ne 0 ]; then
        print_error "SQL execution failed for: ${label}"
        echo "$output"
        exit 1
    fi

    print_info "OK: ${label}"
}

# ---------------------------------------------------------------------------
# Helper: copy the UDF JAR to all Flink pods (JobManager + TaskManagers).
# Uses cat + kubectl exec because kubectl cp requires tar in the container,
# which Confluent Flink images lack.
# Note: The Kafka SQL connector is loaded at pod startup via an initContainer
#       defined in the FlinkDeployment podTemplate.
# ---------------------------------------------------------------------------
copy_udf_jar_to_flink_pods() {
    print_step "Copying UDF JAR to Flink pods..."

    if [ ! -f "$TIME_JAR_PATH" ]; then
        print_error "Time-driven JAR not found at: ${TIME_JAR_PATH}"
        print_error "Run 'make build-ptf-udf-time-driven' first."
        exit 1
    fi

    # All Flink pods (JM + TM)
    local all_pods
    all_pods=$(kubectl get pods -n "$NAMESPACE" \
        -l "component in (jobmanager,taskmanager)" \
        --no-headers -o custom-columns=":metadata.name" 2>/dev/null)

    for pod in $all_pods; do
        print_info "Copying UDF JAR to pod: ${pod}"
        local dest_dir
        dest_dir=$(dirname "$TIME_JAR_POD_PATH")
        kubectl exec -n "$NAMESPACE" "$pod" -- mkdir -p "$dest_dir"
        cat "$TIME_JAR_PATH" | kubectl exec -n "$NAMESPACE" -i "$pod" -- sh -c "cat > ${TIME_JAR_POD_PATH}"
    done

    print_info "UDF JAR copied to all Flink pods."
}

# ===========================================================================
# CREATE action
# ===========================================================================
do_create() {
    print_info "Deploying time-driven PTF UDF via Flink SQL..."
    print_info "  Namespace:     ${NAMESPACE}"
    print_info "  Flink cluster: ${FLINK_CLUSTER_NAME}"

    # Step 0: Copy UDF JAR to Flink pods
    copy_udf_jar_to_flink_pods

    # Step 1: Pre-create Kafka topics (CFK broker has auto.create.topics.enable=false)
    print_step "Creating Kafka topics..."
    for topic in user_activity timeout_events; do
        kubectl exec -n "$NAMESPACE" kafka-0 -- \
            kafka-topics --bootstrap-server kafka:9071 \
                         --create --if-not-exists \
                         --topic "$topic" \
                         --partitions 1 \
                         --replication-factor 1 2>/dev/null \
            && print_info "Topic '${topic}' ready." \
            || print_warn "Topic '${topic}' may already exist."
    done

    # Step 2: Run all SQL in a single sql-client session so that tables
    #         created by earlier statements are visible to later ones
    #         (the default_catalog is in-memory and per-session).
    run_sql "Deploy time-driven PTF UDF pipeline (SessionTimeoutDetector)" \
        "-- ═══════════════════════════════════════════════════════════════════
-- Time-driven PTF: SessionTimeoutDetector (timer-based inactivity)
-- ═══════════════════════════════════════════════════════════════════

-- Source table with event-time watermark
DROP TABLE IF EXISTS user_activity;

CREATE TABLE user_activity (
    user_id    STRING,
    event_type STRING,
    payload    STRING,
    event_time TIMESTAMP_LTZ(3),
    WATERMARK FOR event_time AS event_time - INTERVAL '5' SECOND
) WITH (
    'connector'                    = 'kafka',
    'topic'                        = 'user_activity',
    'properties.bootstrap.servers' = 'kafka:9071',
    'format'                       = 'json',
    'scan.startup.mode'            = 'earliest-offset'
);

-- Sample data with event timestamps
INSERT INTO user_activity (user_id, event_type, payload, event_time)
VALUES
    ('alice',   'login',    'web',             TO_TIMESTAMP_LTZ(1000, 3)),
    ('bob',     'click',    'button-checkout', TO_TIMESTAMP_LTZ(2000, 3)),
    ('alice',   'click',    'button-home',     TO_TIMESTAMP_LTZ(30000, 3)),
    ('charlie', 'login',    'mobile',          TO_TIMESTAMP_LTZ(60000, 3)),
    ('alice',   'purchase', 'order-42',        TO_TIMESTAMP_LTZ(120000, 3)),
    ('bob',     'logout',   'session-end',     TO_TIMESTAMP_LTZ(180000, 3));

-- Sink table
DROP TABLE IF EXISTS timeout_events;

CREATE TABLE timeout_events (
    user_id     STRING,
    event_type  STRING,
    payload     STRING,
    event_count BIGINT,
    timed_out   BOOLEAN
) WITH (
    'connector'                    = 'kafka',
    'topic'                        = 'timeout_events',
    'properties.bootstrap.servers' = 'kafka:9071',
    'format'                       = 'json'
);

-- Register the time-driven UDF
CREATE FUNCTION IF NOT EXISTS session_timeout_detector
    AS 'ptf.SessionTimeoutDetector'
    USING JAR 'file://${TIME_JAR_POD_PATH}';

-- Start the time-driven timeout detection pipeline
INSERT INTO timeout_events
SELECT
    user_id,
    event_type,
    payload,
    event_count,
    timed_out
FROM TABLE(
    session_timeout_detector(
        input   => TABLE user_activity PARTITION BY user_id,
        on_time => DESCRIPTOR(event_time)
    )
);"

    print_info "All statements executed successfully."
    print_info "Run 'make flink-ui' to monitor the running timeout detection job."
}

# ===========================================================================
# DESTROY action
# ===========================================================================
do_destroy() {
    print_info "Tearing down time-driven PTF UDF via Flink SQL..."
    print_info "  Namespace:     ${NAMESPACE}"
    print_info "  Flink cluster: ${FLINK_CLUSTER_NAME}"

    # Cancel all running jobs via the Flink REST API
    print_step "Cancelling running Flink jobs..."
    local jm_pod
    jm_pod=$(get_jobmanager_pod)
    if [ -n "$jm_pod" ]; then
        local jobs_json
        jobs_json=$(kubectl exec -n "$NAMESPACE" "$jm_pod" -- \
            curl -s http://localhost:8081/jobs 2>/dev/null || echo '{"jobs":[]}')

        local running_ids
        running_ids=$(echo "$jobs_json" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    for job in data.get('jobs', []):
        if job.get('status') == 'RUNNING':
            print(job['id'])
except:
    pass
" 2>/dev/null)

        if [ -n "$running_ids" ]; then
            while IFS= read -r job_id; do
                print_info "Cancelling job: ${job_id}"
                kubectl exec -n "$NAMESPACE" "$jm_pod" -- \
                    curl -s -X PATCH "http://localhost:8081/jobs/${job_id}?mode=cancel" >/dev/null 2>&1 \
                    || print_warn "Could not cancel job ${job_id}"
            done <<< "$running_ids"
            sleep 5
        else
            print_info "No running jobs found."
        fi
    fi

    # Drop functions and tables in a single session
    run_sql "Drop UDF and tables" \
        "DROP FUNCTION IF EXISTS session_timeout_detector;
DROP TABLE IF EXISTS timeout_events;
DROP TABLE IF EXISTS user_activity;"

    print_info "Teardown complete."
}

# ===========================================================================
# Main
# ===========================================================================
if [ "$CREATE_ACTION" = true ]; then
    do_create
else
    do_destroy
fi
