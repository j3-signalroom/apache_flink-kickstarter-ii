#!/bin/bash

#
# *** Script Syntax ***
# ./deploy-cp-ptf-udf.sh <create | destroy>
#     [--namespace=confluent]
#     [--cmf-env=dev-local]
#     [--flink-cluster=flink-basic]
#     [--cmf-url=http://localhost:18080]
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
JAR_PATH="$PROJECT_DIR/examples/ptf_udf/java/app/build/libs/app-1.0.0-SNAPSHOT.jar"
JAR_POD_PATH="/opt/flink/usrlib/user-event-enricher.jar"

# CMF port-forward details (ephemeral, avoids conflict with user's `make cmf-open` on 8080)
CMF_LOCAL_PORT=18080
CMF_URL="http://localhost:${CMF_LOCAL_PORT}"
PF_PID=""

# Defaults (overridable via arguments)
NAMESPACE="confluent"
CMF_ENV_NAME="dev-local"
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
    print_error "Usage: $(basename "$0") <create | destroy> [--namespace=confluent] [--cmf-env=dev-local] [--flink-cluster=flink-basic] [--cmf-url=http://localhost:18080]"
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
        --cmf-env=*)
            CMF_ENV_NAME="${arg#*=}";;
        --flink-cluster=*)
            FLINK_CLUSTER_NAME="${arg#*=}";;
        --cmf-url=*)
            CMF_URL="${arg#*=}";;
        *)
            print_error "Invalid argument: $arg"
            print_error "Usage: $(basename "$0") <create | destroy> [--namespace=confluent] [--cmf-env=dev-local] [--flink-cluster=flink-basic] [--cmf-url=http://localhost:18080]"
            exit 1
            ;;
    esac
done

# Common flags passed to every `confluent flink` command
CMF_FLAGS="--environment ${CMF_ENV_NAME} --url ${CMF_URL}"

# ---------------------------------------------------------------------------
# Helper: clean up port-forward on exit
# ---------------------------------------------------------------------------
cleanup() {
    if [ -n "$PF_PID" ]; then
        kill "$PF_PID" 2>/dev/null || true
        wait "$PF_PID" 2>/dev/null || true
        PF_PID=""
    fi
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Helper: start port-forward to CMF and wait until it responds
# ---------------------------------------------------------------------------
start_cmf_port_forward() {
    print_step "Starting port-forward to CMF service..."
    kubectl port-forward -n "$NAMESPACE" svc/cmf-service "${CMF_LOCAL_PORT}:80" >/dev/null 2>&1 &
    PF_PID=$!

    for i in 1 2 3 4 5 6 7 8 9 10; do
        sleep 2
        if confluent flink environment list --url "$CMF_URL" >/dev/null 2>&1; then
            print_info "CMF is reachable at ${CMF_URL}"
            return 0
        fi
        if [ "$i" -eq 10 ]; then
            print_error "CMF port-forward failed to start after 20s."
            exit 1
        fi
    done
}

# ---------------------------------------------------------------------------
# Helper: submit a SQL statement via the confluent CLI and return the
# statement name
# ---------------------------------------------------------------------------
submit_statement() {
    local label="$1"
    local sql="$2"

    print_step "Submitting: ${label}"

    local output
    output=$(confluent flink statement create --sql "$sql" \
        $CMF_FLAGS \
        --output json 2>&1)

    if [ $? -ne 0 ]; then
        print_error "Statement submission failed:"
        echo "$output"
        exit 1
    fi

    local stmt_name
    stmt_name=$(echo "$output" | python3 -c "import sys,json; print(json.load(sys.stdin)['metadata']['name'])" 2>/dev/null \
        || echo "$output" | python3 -c "import sys,json; print(json.load(sys.stdin)['name'])" 2>/dev/null \
        || echo "")

    if [ -z "$stmt_name" ]; then
        print_error "Could not extract statement name from response:"
        echo "$output"
        exit 1
    fi

    print_info "Statement accepted: ${stmt_name}"
    echo "$stmt_name"
}

# ---------------------------------------------------------------------------
# Helper: wait for a statement to reach an expected phase
# ---------------------------------------------------------------------------
wait_for_statement() {
    local stmt_name="$1"
    local expected_phase="$2"
    local timeout="${3:-120}"

    local elapsed=0
    local poll_interval=5
    local phase="UNKNOWN"

    while [ "$elapsed" -lt "$timeout" ]; do
        local output
        output=$(confluent flink statement describe "$stmt_name" \
            $CMF_FLAGS \
            --output json 2>/dev/null || echo "{}")

        phase=$(echo "$output" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    # Handle both possible response shapes
    phase = data.get('status', {}).get('phase', '') or data.get('phase', '') or 'UNKNOWN'
    print(phase)
except:
    print('UNKNOWN')
" 2>/dev/null)

        if [ "$phase" = "$expected_phase" ]; then
            print_info "Statement ${stmt_name} reached phase: ${phase}"
            return 0
        elif [ "$phase" = "FAILED" ]; then
            print_error "Statement ${stmt_name} FAILED:"
            echo "$output" | python3 -m json.tool 2>/dev/null || echo "$output"
            exit 1
        fi

        sleep "$poll_interval"
        elapsed=$((elapsed + poll_interval))
    done

    print_error "Timeout (${timeout}s) waiting for ${stmt_name} to reach ${expected_phase} (last phase: ${phase})"
    exit 1
}

# ---------------------------------------------------------------------------
# Helper: submit a statement and wait for its expected phase
# ---------------------------------------------------------------------------
submit_and_wait() {
    local label="$1"
    local sql="$2"
    local expected_phase="$3"
    local timeout="${4:-120}"

    local stmt_name
    stmt_name=$(submit_statement "$label" "$sql")
    wait_for_statement "$stmt_name" "$expected_phase" "$timeout"
}

# ---------------------------------------------------------------------------
# Helper: copy the UDF JAR to all Flink pods (JobManager + TaskManagers)
# ---------------------------------------------------------------------------
copy_jar_to_flink_pods() {
    print_step "Copying UDF JAR to Flink pods..."

    if [ ! -f "$JAR_PATH" ]; then
        print_error "JAR not found at: ${JAR_PATH}"
        print_error "Run 'make build-ptf-udf' first."
        exit 1
    fi

    # JobManager pods
    local jm_pods
    jm_pods=$(kubectl get pods -n "$NAMESPACE" -l component=jobmanager --no-headers -o custom-columns=":metadata.name" 2>/dev/null)
    for pod in $jm_pods; do
        print_info "Copying JAR to JobManager pod: ${pod}"
        kubectl cp "$JAR_PATH" "${NAMESPACE}/${pod}:${JAR_POD_PATH}"
    done

    # TaskManager pods
    local tm_pods
    tm_pods=$(kubectl get pods -n "$NAMESPACE" -l component=taskmanager --no-headers -o custom-columns=":metadata.name" 2>/dev/null)
    for pod in $tm_pods; do
        print_info "Copying JAR to TaskManager pod: ${pod}"
        kubectl cp "$JAR_PATH" "${NAMESPACE}/${pod}:${JAR_POD_PATH}"
    done

    print_info "JAR copied to all Flink pods."
}

# ===========================================================================
# CREATE action
# ===========================================================================
do_create() {
    print_info "Deploying PTF UDF via CMF SQL statements..."
    print_info "  Namespace:     ${NAMESPACE}"
    print_info "  CMF env:       ${CMF_ENV_NAME}"
    print_info "  CMF URL:       ${CMF_URL}"
    print_info "  Flink cluster: ${FLINK_CLUSTER_NAME}"

    # Step 0: Copy UDF JAR to Flink pods
    copy_jar_to_flink_pods

    # Step 1: Start CMF port-forward
    start_cmf_port_forward

    # Step 2: Drop and create source table
    submit_and_wait "DROP TABLE IF EXISTS user_events" \
        "DROP TABLE IF EXISTS user_events;" \
        "COMPLETED"

    submit_and_wait "CREATE TABLE user_events" \
        "CREATE TABLE user_events (
            user_id    STRING,
            event_type STRING,
            payload    STRING
        ) WITH (
            'connector'                    = 'kafka',
            'topic'                        = 'user_events',
            'properties.bootstrap.servers' = 'kafka:9071',
            'format'                       = 'json',
            'scan.startup.mode'            = 'latest-offset'
        );" \
        "COMPLETED"

    # Step 3: Insert sample data
    submit_and_wait "INSERT sample user_events" \
        "INSERT INTO user_events (user_id, event_type, payload)
        VALUES
            ('alice',   'login',    'web'),
            ('bob',     'click',    'button-checkout'),
            ('alice',   'purchase', 'order-1234'),
            ('charlie', 'login',    'mobile'),
            ('bob',     'logout',   'session-end'),
            ('alice',   'click',    'button-settings');" \
        "COMPLETED" \
        180

    # Step 4: Drop and create sink table
    submit_and_wait "DROP TABLE IF EXISTS enriched_events" \
        "DROP TABLE IF EXISTS enriched_events;" \
        "COMPLETED"

    submit_and_wait "CREATE TABLE enriched_events" \
        "CREATE TABLE enriched_events (
            user_id     STRING,
            event_type  STRING,
            payload     STRING,
            session_id  BIGINT,
            event_count BIGINT,
            last_event  STRING
        ) WITH (
            'connector'                    = 'kafka',
            'topic'                        = 'enriched_events',
            'properties.bootstrap.servers' = 'kafka:9071',
            'format'                       = 'json'
        );" \
        "COMPLETED"

    # Step 5: Register the UDF
    submit_and_wait "CREATE FUNCTION user_event_enricher" \
        "CREATE FUNCTION IF NOT EXISTS user_event_enricher
            AS 'ptf.UserEventEnricher'
            USING JAR 'file://${JAR_POD_PATH}';" \
        "COMPLETED"

    # Step 6: Start the enrichment pipeline (long-running)
    submit_and_wait "INSERT INTO enriched_events (enrichment pipeline)" \
        "INSERT INTO enriched_events
        SELECT
            user_id,
            event_type,
            payload,
            session_id,
            event_count,
            last_event
        FROM TABLE(
            user_event_enricher(
                input => TABLE user_events PARTITION BY user_id
            )
        );" \
        "RUNNING" \
        180

    print_info "All statements submitted successfully."
    print_info "Run 'make flink-ui' to monitor the running enrichment job."
}

# ===========================================================================
# DESTROY action
# ===========================================================================
do_destroy() {
    print_info "Tearing down PTF UDF SQL statements via CMF..."
    print_info "  Namespace: ${NAMESPACE}"
    print_info "  CMF env:   ${CMF_ENV_NAME}"
    print_info "  CMF URL:   ${CMF_URL}"

    start_cmf_port_forward

    # Step 1: List and cancel all RUNNING statements
    print_step "Listing running statements..."
    local statements_json
    statements_json=$(confluent flink statement list \
        $CMF_FLAGS \
        --output json 2>/dev/null || echo "[]")

    local running_names
    running_names=$(echo "$statements_json" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    items = data if isinstance(data, list) else data.get('data', [])
    for item in items:
        phase = item.get('status', {}).get('phase', '') or item.get('phase', '')
        name = item.get('metadata', {}).get('name', '') or item.get('name', '')
        if phase == 'RUNNING' and name:
            print(name)
except:
    pass
" 2>/dev/null)

    if [ -n "$running_names" ]; then
        while IFS= read -r stmt_name; do
            print_step "Deleting statement: ${stmt_name}"
            confluent flink statement delete "$stmt_name" \
                $CMF_FLAGS \
                --force 2>/dev/null \
                || print_warn "Could not delete ${stmt_name} (may already be stopped)"
        done <<< "$running_names"
        # Give Flink a moment to stop jobs
        sleep 5
    else
        print_info "No running statements found."
    fi

    # Step 2: Drop function and tables
    submit_and_wait "DROP FUNCTION IF EXISTS user_event_enricher" \
        "DROP FUNCTION IF EXISTS user_event_enricher;" \
        "COMPLETED"

    submit_and_wait "DROP TABLE IF EXISTS enriched_events" \
        "DROP TABLE IF EXISTS enriched_events;" \
        "COMPLETED"

    submit_and_wait "DROP TABLE IF EXISTS user_events" \
        "DROP TABLE IF EXISTS user_events;" \
        "COMPLETED"

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
