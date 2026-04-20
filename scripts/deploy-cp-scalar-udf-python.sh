#!/bin/bash

#
# *** Script Syntax ***
# ./deploy-cp-scalar-udf-python.sh <create | destroy> [--namespace=confluent]
#                                                     [--flink-cluster=flink-basic]
#
# Deploys the PyFlink scalar UDF examples (celsius_to_fahrenheit,
# fahrenheit_to_celsius) to a Confluent Platform Flink session cluster
# running in minikube.
#
# Prerequisite: the Flink cluster must use the cp-flink-python image
# (built via `make build-cp-flink-python-image`) so that Python 3.11,
# the apache-flink wheel, and the UDF source files are already present
# on every JM/TM pod at /opt/flink/python-udf/.
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

# In-pod locations (set by the cp-flink-python image).
UDF_POD_DIR="/opt/flink/python-udf"
PYTHON_EXECUTABLE="${UDF_POD_DIR}/.venv/bin/python"
UDF_FILES_POD="${UDF_POD_DIR}/celsius_to_fahrenheit.py,${UDF_POD_DIR}/fahrenheit_to_celsius.py"

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
# Helper: verify the cluster image has Python + UDF files baked in.
# ---------------------------------------------------------------------------
verify_python_image() {
    print_step "Verifying cp-flink-python image is in use..."
    local jm_pod
    jm_pod=$(get_jobmanager_pod)
    if [ -z "$jm_pod" ]; then
        print_error "No JobManager pod found for cluster '${FLINK_CLUSTER_NAME}'."
        exit 1
    fi

    if ! kubectl exec -n "$NAMESPACE" "$jm_pod" -- test -x "${PYTHON_EXECUTABLE}" 2>/dev/null; then
        print_error "Python executable not found at ${PYTHON_EXECUTABLE} on pod ${jm_pod}."
        print_error "The Flink cluster does not appear to be using the cp-flink-python image."
        print_error "Rebuild and redeploy with: make build-cp-flink-python-image flink-deploy"
        exit 1
    fi

    if ! kubectl exec -n "$NAMESPACE" "$jm_pod" -- test -f "${UDF_POD_DIR}/celsius_to_fahrenheit.py" 2>/dev/null; then
        print_error "UDF source files not found at ${UDF_POD_DIR} on pod ${jm_pod}."
        exit 1
    fi

    print_info "cp-flink-python image verified on cluster '${FLINK_CLUSTER_NAME}'."
}

# ---------------------------------------------------------------------------
# Helper: execute SQL on the Flink cluster via sql-client.sh -f
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

    local remote_sql="/tmp/deploy-sql-$$.sql"
    echo "$sql" | kubectl exec -n "$NAMESPACE" -i "$jm_pod" -- sh -c "cat > ${remote_sql}"

    local output
    output=$(kubectl exec -n "$NAMESPACE" "$jm_pod" -- \
        /opt/flink/bin/sql-client.sh embedded -f "$remote_sql" 2>&1)
    local rc=$?

    kubectl exec -n "$NAMESPACE" "$jm_pod" -- rm -f "$remote_sql" 2>/dev/null || true

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

# ===========================================================================
# CREATE action
# ===========================================================================
do_create() {
    print_info "Deploying Python Scalar UDF via Flink SQL..."
    print_info "  Namespace:     ${NAMESPACE}"
    print_info "  Flink cluster: ${FLINK_CLUSTER_NAME}"

    # Step 0: Verify the cluster image has Python + UDFs baked in
    verify_python_image

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

    # Step 2: Run all SQL in a single sql-client session
    run_sql "Deploy Python Scalar UDF pipeline" \
        "
-- Point PyFlink at the baked-in interpreter + UDF files.
SET 'python.executable' = '${PYTHON_EXECUTABLE}';
SET 'python.client.executable' = '${PYTHON_EXECUTABLE}';
SET 'python.files' = '${UDF_FILES_POD}';

-- ============================================================================
-- UDF 1: CelsiusToFahrenheit (Python)
-- ============================================================================

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

INSERT INTO celsius_reading (sensor_id, celsius_temperature)
VALUES
    (1000, 18),
    (1001, 20),
    (1002, 22),
    (1003, 24),
    (1004, 26),
    (1005, 28);

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

DROP FUNCTION IF EXISTS celsius_to_fahrenheit;

CREATE FUNCTION celsius_to_fahrenheit
    AS 'celsius_to_fahrenheit.celsius_to_fahrenheit'
    LANGUAGE PYTHON;

INSERT INTO celsius_to_fahrenheit (sensor_id, celsius_temperature, fahrenheit_temperature)
    SELECT
        sensor_id, celsius_temperature, celsius_to_fahrenheit(celsius_temperature)
    FROM
        celsius_reading;

-- ============================================================================
-- UDF 2: FahrenheitToCelsius (Python)
-- ============================================================================

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

INSERT INTO fahrenheit_reading (sensor_id, fahrenheit_temperature)
VALUES
    (2000, 64.4),
    (2001, 68),
    (2002, 71.6),
    (2003, 75.2),
    (2004, 78.8),
    (2005, 82.4);

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

DROP FUNCTION IF EXISTS fahrenheit_to_celsius;

CREATE FUNCTION fahrenheit_to_celsius
    AS 'fahrenheit_to_celsius.fahrenheit_to_celsius'
    LANGUAGE PYTHON;

INSERT INTO fahrenheit_to_celsius (sensor_id, fahrenheit_temperature, celsius_temperature)
    SELECT
        sensor_id, fahrenheit_temperature, fahrenheit_to_celsius(fahrenheit_temperature)
    FROM
        fahrenheit_reading;
"

    print_info "All statements executed successfully."
    print_info "Run 'make flink-ui' to monitor the running jobs."
}

# ===========================================================================
# DESTROY action
# ===========================================================================
do_destroy() {
    print_info "Tearing down Python Scalar UDF via Flink SQL..."
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

    run_sql "Drop UDFs, tables" \
        "DROP FUNCTION IF EXISTS celsius_to_fahrenheit;
DROP FUNCTION IF EXISTS fahrenheit_to_celsius;
DROP TABLE IF EXISTS celsius_reading;
DROP TABLE IF EXISTS celsius_to_fahrenheit;
DROP TABLE IF EXISTS fahrenheit_reading;
DROP TABLE IF EXISTS fahrenheit_to_celsius;"

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
