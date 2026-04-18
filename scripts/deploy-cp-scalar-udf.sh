#!/bin/bash

#
# *** Script Syntax ***
# ./deploy-cp-scalar-udf.sh <create | destroy> [--namespace=confluent]
#                                              [--flink-cluster=flink-basic]
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
JAR_PATH="$PROJECT_DIR/examples/scalar_udf/java/app/build/libs/app-1.0.0-SNAPSHOT.jar"
JAR_POD_PATH="/opt/flink/usrlib/scalar-udf.jar"

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

    if [ ! -f "$JAR_PATH" ]; then
        print_error "JAR not found at: ${JAR_PATH}"
        print_error "Run 'make build-scalar-udf' first."
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
        dest_dir=$(dirname "$JAR_POD_PATH")
        kubectl exec -n "$NAMESPACE" "$pod" -- mkdir -p "$dest_dir"
        cat "$JAR_PATH" | kubectl exec -n "$NAMESPACE" -i "$pod" -- sh -c "cat > ${JAR_POD_PATH}"
    done

    print_info "UDF JAR copied to all Flink pods."
}

# ===========================================================================
# CREATE action
# ===========================================================================
do_create() {
    print_info "Deploying Scalar UDF via Flink SQL..."
    print_info "  Namespace:     ${NAMESPACE}"
    print_info "  Flink cluster: ${FLINK_CLUSTER_NAME}"

    # Step 0: Copy UDF JAR to Flink pods
    copy_udf_jar_to_flink_pods

    # Step 1: Pre-create Kafka topics (CFK broker has auto.create.topics.enable=false)
    print_step "Creating Kafka topics..."
    for topic in celsius_reading celsius_to_fahrenheit fahrenheit_reading fahrenheit_to_celsius; do
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
    run_sql "Deploy Scalar UDF pipeline" \
        "
-- ============================================================================
-- UDF 1: CelsiusToFahrenheit
-- ============================================================================

-- Source table
DROP TABLE IF EXISTS celsius_reading;

CREATE TABLE celsius_reading (
    sensor_id               BIGINT,
    celsius_temperature     DOUBLE
) WITH (
    'connector'                    = 'kafka',
    'topic'                        = 'celsius_reading',
    'properties.bootstrap.servers' = 'kafka:9071',
    'format'                       = 'json',
    'scan.startup.mode'            = 'earliest-offset'
);

-- Sample data (runs synchronously so topic exists before downstream reads)
INSERT INTO celsius_reading (sensor_id, celsius_temperature)
VALUES
    (1000, 18),
    (1001, 20),
    (1002, 22),
    (1003, 24),
    (1004, 26),
    (1005, 28);

-- Sink table
DROP TABLE IF EXISTS celsius_to_fahrenheit;

CREATE TABLE celsius_to_fahrenheit (
    sensor_id               BIGINT,
    celsius_temperature     DOUBLE,
    fahrenheit_temperature  DOUBLE
) WITH (
    'connector'                    = 'kafka',
    'topic'                        = 'celsius_to_fahrenheit',
    'properties.bootstrap.servers' = 'kafka:9071',
    'format'                       = 'json'
);

-- Register the UDF
CREATE FUNCTION celsius_to_fahrenheit
    AS 'scalar_udf.CelsiusToFahrenheit'
    USING JAR 'file://${JAR_POD_PATH}';

-- Sample data (runs synchronously so topic exists before downstream reads)
INSERT INTO celsius_to_fahrenheit (sensor_id, celsius_temperature, fahrenheit_temperature)
    SELECT 
        sensor_id, celsius_temperature, celsius_to_fahrenheit(celsius_temperature)
    FROM
        celsius_reading;

-- ============================================================================
-- UDF 2: FahrenheitToCelsius
-- ============================================================================

-- Source table
DROP TABLE IF EXISTS fahrenheit_reading;

CREATE TABLE fahrenheit_reading (
    sensor_id               BIGINT,
    fahrenheit_temperature  DOUBLE
) WITH (
    'connector'                    = 'kafka',
    'topic'                        = 'fahrenheit_reading',
    'properties.bootstrap.servers' = 'kafka:9071',
    'format'                       = 'json',
    'scan.startup.mode'            = 'earliest-offset'
);

-- Sample data (runs synchronously so topic exists before downstream reads)
INSERT INTO fahrenheit_reading (sensor_id, fahrenheit_temperature)
VALUES
    (2000, 64.4),
    (2001, 68),
    (2002, 71.6),
    (2003, 75.2),
    (2004, 78.8),
    (2005, 82.4);

-- Sink table
DROP TABLE IF EXISTS fahrenheit_to_celsius;

CREATE TABLE fahrenheit_to_celsius (
    sensor_id               BIGINT,
    fahrenheit_temperature  DOUBLE,
    celsius_temperature     DOUBLE
) WITH (
    'connector'                    = 'kafka',
    'topic'                        = 'fahrenheit_to_celsius',
    'properties.bootstrap.servers' = 'kafka:9071',
    'format'                       = 'json'
);

-- Register the UDF
CREATE FUNCTION fahrenheit_to_celsius
    AS 'scalar_udf.FahrenheitToCelsius'
    USING JAR 'file://${JAR_POD_PATH}';

-- Sample data (runs synchronously so topic exists before downstream reads)
INSERT INTO fahrenheit_to_celsius (sensor_id, fahrenheit_temperature, celsius_temperature)
    SELECT 
        sensor_id, fahrenheit_temperature, fahrenheit_to_celsius(fahrenheit_temperature)
    FROM
        fahrenheit_reading;
"

    print_info "All statements executed successfully."
    print_info "Run 'make flink-ui' to monitor the running select job."
}

# ===========================================================================
# DESTROY action
# ===========================================================================
do_destroy() {
    print_info "Tearing down Scalar UDF via Flink SQL..."
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
    run_sql "Drop UDFs, tables" \
        "DROP FUNCTION IF EXISTS celsius_to_fahrenheit;
DROP FUNCTION IF EXISTS fahrenheit_to_celsius;
DROP TABLE IF EXISTS celsius_reading;
DROP TABLE IF EXISTS celsius_to_fahrenheit;
DROP TABLE IF EXISTS fahrenheit_reading;
DROP TABLE IF EXISTS fahrenheit_to_celsius;"

    # Delete the associated Kafka topics
    print_step "Deleting Kafka topics..."
    for topic in celsius_reading celsius_to_fahrenheit fahrenheit_reading fahrenheit_to_celsius; do
        kubectl exec -n "$NAMESPACE" kafka-0 -- \
            kafka-topics --bootstrap-server kafka:9071 \
                         --delete --if-exists \
                         --topic "$topic" 2>/dev/null \
            && print_info "Topic '${topic}' deleted." \
            || print_warn "Topic '${topic}' may not exist."
    done

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
