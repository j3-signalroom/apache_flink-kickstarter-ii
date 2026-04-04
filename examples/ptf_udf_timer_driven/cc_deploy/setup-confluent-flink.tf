# Service account to perform the task within Confluent Cloud to execute the Flink SQL statements
resource "confluent_service_account" "flink_sql_runner" {
  display_name = "ptf-udf-timer-driven"
  description  = "Service account for running Flink SQL Statements in the Kafka cluster"
}

resource "confluent_role_binding" "flink_sql_runner_as_flink_developer" {
    principal   = "User:${confluent_service_account.flink_sql_runner.id}"
    role_name   = "FlinkDeveloper"
    crn_pattern = data.confluent_organization.signalroom.resource_name

    depends_on = [
        confluent_service_account.flink_sql_runner
    ]
}

resource "confluent_role_binding" "flink_sql_runner_as_resource_owner_topic_access" {
    principal   = "User:${confluent_service_account.flink_sql_runner.id}"
    role_name   = "ResourceOwner"
    crn_pattern = "${confluent_kafka_cluster.ptf_udf_timer_driven.rbac_crn}/kafka=${confluent_kafka_cluster.ptf_udf_timer_driven.id}/topic=*"

    depends_on = [
        confluent_role_binding.flink_sql_runner_as_flink_developer
    ]
}

resource "confluent_role_binding" "flink_sql_runner_as_assigner" {
    principal   = "User:${confluent_service_account.flink_sql_runner.id}"
    role_name   = "Assigner"
    crn_pattern = "${data.confluent_organization.signalroom.resource_name}/service-account=${confluent_service_account.flink_sql_runner.id}"

    depends_on = [
        confluent_role_binding.flink_sql_runner_as_resource_owner_topic_access
    ]
}

resource "confluent_role_binding" "flink_sql_runner_schema_registry_access" {
    principal   = "User:${confluent_service_account.flink_sql_runner.id}"
    role_name   = "ResourceOwner"
    crn_pattern = "${data.confluent_schema_registry_cluster.ptf_udf_timer_driven.resource_name}/subject=*"

    depends_on = [
        confluent_role_binding.flink_sql_runner_as_assigner
    ]
}

resource "confluent_role_binding" "flink_sql_runner_as_resource_owner_transactional_access" {
    principal   = "User:${confluent_service_account.flink_sql_runner.id}"
    role_name   = "ResourceOwner"
    crn_pattern = "${confluent_kafka_cluster.ptf_udf_timer_driven.rbac_crn}/kafka=${confluent_kafka_cluster.ptf_udf_timer_driven.id}/transactional-id=*"

    depends_on = [
        confluent_role_binding.flink_sql_runner_schema_registry_access
    ]
}

resource "confluent_flink_compute_pool" "ptf_udf_timer_driven" {
  display_name = "apache_flink_flink_statement_runner"
  cloud        = local.cloud
  region       = local.aws_region
  max_cfu      = 10
  environment {
    id = confluent_environment.ptf_udf_timer_driven.id
  }
  depends_on = [
    confluent_role_binding.flink_sql_runner_as_resource_owner_transactional_access
  ]
}

# Create the Environment API Key Pairs, rotate them in accordance to a time schedule, and provide the current
# acitve API Key Pair to use
module "flink_api_key_rotation" {
    source  = "github.com/j3-signalroom/iac-confluent-api_key_rotation-tf_module"

    # Required Input(s)
    owner = {
        id          = confluent_service_account.flink_sql_runner.id
        api_version = confluent_service_account.flink_sql_runner.api_version
        kind        = confluent_service_account.flink_sql_runner.kind
    }

    resource = {
        id          = data.confluent_flink_region.ptf_udf_timer_driven.id
        api_version = data.confluent_flink_region.ptf_udf_timer_driven.api_version
        kind        = data.confluent_flink_region.ptf_udf_timer_driven.kind

        environment = {
            id = confluent_environment.ptf_udf_timer_driven.id
        }
    }

    # Optional Input(s)
    key_display_name = "Flink Service Account API Key - {date} - Managed by Terraform Cloud"
    number_of_api_keys_to_retain = var.number_of_api_keys_to_retain
    day_count = var.day_count
}

# ═══════════════════════════════════════════════════════════════════════════════
# Timer-driven PTF: SessionTimeoutDetector (timer-based inactivity)
# ═══════════════════════════════════════════════════════════════════════════════

resource "confluent_flink_statement" "drop_user_activity" {
  statement = "DROP TABLE IF EXISTS user_activity;"

  properties = {
    "sql.current-catalog"  = confluent_environment.ptf_udf_timer_driven.display_name
    "sql.current-database" = confluent_kafka_cluster.ptf_udf_timer_driven.display_name
  }

  rest_endpoint = data.confluent_flink_region.ptf_udf_timer_driven.rest_endpoint
  credentials {
    key    = module.flink_api_key_rotation.active_api_key.id
    secret = module.flink_api_key_rotation.active_api_key.secret
  }

  organization {
    id = data.confluent_organization.signalroom.id
  }

  environment {
    id = confluent_environment.ptf_udf_timer_driven.id
  }

  principal {
    id = confluent_service_account.flink_sql_runner.id
  }

  compute_pool {
    id = confluent_flink_compute_pool.ptf_udf_timer_driven.id
  }

  lifecycle {
    ignore_changes = [statement, compute_pool]
  }
}

resource "confluent_flink_statement" "user_activity_source" {
  statement = <<-EOT
    CREATE TABLE user_activity (
                user_id    STRING,
                event_type STRING,
                payload    STRING,
                event_time TIMESTAMP_LTZ(3),
                WATERMARK FOR event_time AS event_time - INTERVAL '5' SECOND
            );
  EOT

  properties = {
    "sql.current-catalog"  = confluent_environment.ptf_udf_timer_driven.display_name
    "sql.current-database" = confluent_kafka_cluster.ptf_udf_timer_driven.display_name
  }

  rest_endpoint = data.confluent_flink_region.ptf_udf_timer_driven.rest_endpoint
  credentials {
    key    = module.flink_api_key_rotation.active_api_key.id
    secret = module.flink_api_key_rotation.active_api_key.secret
  }

  organization {
    id = data.confluent_organization.signalroom.id
  }

  environment {
    id = confluent_environment.ptf_udf_timer_driven.id
  }

  principal {
    id = confluent_service_account.flink_sql_runner.id
  }

  compute_pool {
    id = confluent_flink_compute_pool.ptf_udf_timer_driven.id
  }

  lifecycle {
    ignore_changes = [compute_pool]
  }

  depends_on = [
    confluent_flink_statement.drop_user_activity,
    confluent_kafka_topic.user_activity
  ]
}

resource "confluent_flink_statement" "insert_user_activity" {
  statement = <<-EOT
    INSERT INTO user_activity (user_id, event_type, payload, event_time)
    VALUES
      ('alice',   'login',    'web',              TO_TIMESTAMP_LTZ(1000, 3)),
      ('bob',     'click',    'button-checkout',  TO_TIMESTAMP_LTZ(2000, 3)),
      ('alice',   'click',    'button-home',      TO_TIMESTAMP_LTZ(30000, 3)),
      ('charlie', 'login',    'mobile',           TO_TIMESTAMP_LTZ(60000, 3)),
      ('alice',   'purchase', 'order-42',         TO_TIMESTAMP_LTZ(120000, 3)),
      ('bob',     'logout',   'session-end',      TO_TIMESTAMP_LTZ(180000, 3));
  EOT

  properties = {
    "sql.current-catalog"  = confluent_environment.ptf_udf_timer_driven.display_name
    "sql.current-database" = confluent_kafka_cluster.ptf_udf_timer_driven.display_name
  }

  rest_endpoint = data.confluent_flink_region.ptf_udf_timer_driven.rest_endpoint
  credentials {
    key    = module.flink_api_key_rotation.active_api_key.id
    secret = module.flink_api_key_rotation.active_api_key.secret
  }

  organization {
    id = data.confluent_organization.signalroom.id
  }

  environment {
    id = confluent_environment.ptf_udf_timer_driven.id
  }

  principal {
    id = confluent_service_account.flink_sql_runner.id
  }

  compute_pool {
    id = confluent_flink_compute_pool.ptf_udf_timer_driven.id
  }

  lifecycle {
    ignore_changes = [compute_pool]
  }

  depends_on = [
    confluent_flink_statement.user_activity_source
  ]
}

resource "confluent_flink_statement" "drop_timeout_events" {
  statement = "DROP TABLE IF EXISTS timeout_events;"

  properties = {
    "sql.current-catalog"  = confluent_environment.ptf_udf_timer_driven.display_name
    "sql.current-database" = confluent_kafka_cluster.ptf_udf_timer_driven.display_name
  }

  rest_endpoint = data.confluent_flink_region.ptf_udf_timer_driven.rest_endpoint
  credentials {
    key    = module.flink_api_key_rotation.active_api_key.id
    secret = module.flink_api_key_rotation.active_api_key.secret
  }

  organization {
    id = data.confluent_organization.signalroom.id
  }

  environment {
    id = confluent_environment.ptf_udf_timer_driven.id
  }

  principal {
    id = confluent_service_account.flink_sql_runner.id
  }

  compute_pool {
    id = confluent_flink_compute_pool.ptf_udf_timer_driven.id
  }

  lifecycle {
    ignore_changes = [statement, compute_pool]
  }
}

resource "confluent_flink_statement" "timeout_events_sink" {
  statement = <<-EOT
    CREATE TABLE timeout_events (
                user_id     STRING,
                event_type  STRING,
                payload     STRING,
                event_count BIGINT,
                timed_out   BOOLEAN
            );
  EOT

  properties = {
    "sql.current-catalog"  = confluent_environment.ptf_udf_timer_driven.display_name
    "sql.current-database" = confluent_kafka_cluster.ptf_udf_timer_driven.display_name
  }

  rest_endpoint = data.confluent_flink_region.ptf_udf_timer_driven.rest_endpoint
  credentials {
    key    = module.flink_api_key_rotation.active_api_key.id
    secret = module.flink_api_key_rotation.active_api_key.secret
  }

  organization {
    id = data.confluent_organization.signalroom.id
  }

  environment {
    id = confluent_environment.ptf_udf_timer_driven.id
  }

  principal {
    id = confluent_service_account.flink_sql_runner.id
  }

  compute_pool {
    id = confluent_flink_compute_pool.ptf_udf_timer_driven.id
  }

  lifecycle {
    ignore_changes = [compute_pool]
  }

  depends_on = [
    confluent_flink_statement.insert_user_activity,
    confluent_flink_statement.drop_timeout_events,
    confluent_kafka_topic.timeout_events
  ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# Upload the JAR as a Flink artifact
# ═══════════════════════════════════════════════════════════════════════════════

locals {
  ptf_jar_path = "${path.module}/../java/app/build/libs/app-1.0.0-SNAPSHOT.jar"
}

resource "confluent_flink_artifact" "ptf_udf_timer_driven" {
  display_name     = "ptf-udf-timer-driven"
  content_format   = "JAR"
  cloud            = local.cloud
  region           = local.aws_region
  artifact_file    = local.ptf_jar_path

  environment {
    id = confluent_environment.ptf_udf_timer_driven.id
  }

  depends_on = [
    confluent_flink_statement.insert_user_activity,
    confluent_flink_statement.timeout_events_sink,
    confluent_flink_statement.insert_user_actions,
    confluent_flink_statement.follow_up_events_sink,
    confluent_flink_statement.insert_service_requests,
    confluent_flink_statement.sla_events_sink,
    confluent_flink_statement.insert_cart_events,
    confluent_flink_statement.abandoned_cart_events_sink,
  ]

  lifecycle {
    replace_triggered_by = [terraform_data.ptf_jar_hash.output]
  }
}

resource "terraform_data" "ptf_jar_hash" {
  input = filesha256(local.ptf_jar_path)
}

# ── Timer-driven UDF registration and pipeline ─────────────────────────────────

resource "confluent_flink_statement" "create_session_timeout_detector" {
  statement = <<-EOT
    CREATE FUNCTION IF NOT EXISTS session_timeout_detector
      AS 'ptf.SessionTimeoutDetector'
      USING JAR 'confluent-artifact://${confluent_flink_artifact.ptf_udf_timer_driven.id}';
  EOT

  properties = {
    "sql.current-catalog"  = confluent_environment.ptf_udf_timer_driven.display_name
    "sql.current-database" = confluent_kafka_cluster.ptf_udf_timer_driven.display_name
  }

  rest_endpoint = data.confluent_flink_region.ptf_udf_timer_driven.rest_endpoint
  credentials {
    key    = module.flink_api_key_rotation.active_api_key.id
    secret = module.flink_api_key_rotation.active_api_key.secret
  }

  organization {
    id = data.confluent_organization.signalroom.id
  }

  environment {
    id = confluent_environment.ptf_udf_timer_driven.id
  }

  principal {
    id = confluent_service_account.flink_sql_runner.id
  }

  compute_pool {
    id = confluent_flink_compute_pool.ptf_udf_timer_driven.id
  }

  lifecycle {
    ignore_changes = [statement, compute_pool]
  }

  depends_on = [
    confluent_flink_artifact.ptf_udf_timer_driven
  ]
}

resource "confluent_flink_statement" "insert_timeout_events" {
  statement = <<-EOT
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
          on_time => DESCRIPTOR(event_time),
          uid     => 'timeout-events-v1'
        )
      );
  EOT

  properties = {
    "sql.current-catalog"  = confluent_environment.ptf_udf_timer_driven.display_name
    "sql.current-database" = confluent_kafka_cluster.ptf_udf_timer_driven.display_name
  }

  rest_endpoint = data.confluent_flink_region.ptf_udf_timer_driven.rest_endpoint
  credentials {
    key    = module.flink_api_key_rotation.active_api_key.id
    secret = module.flink_api_key_rotation.active_api_key.secret
  }

  organization {
    id = data.confluent_organization.signalroom.id
  }

  environment {
    id = confluent_environment.ptf_udf_timer_driven.id
  }

  principal {
    id = confluent_service_account.flink_sql_runner.id
  }

  compute_pool {
    id = confluent_flink_compute_pool.ptf_udf_timer_driven.id
  }

  lifecycle {
    ignore_changes = [compute_pool]
  }

  depends_on = [
    confluent_flink_statement.create_session_timeout_detector
  ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# Unnamed timer-driven PTF: PerEventFollowUp (per-event follow-up)
# ═══════════════════════════════════════════════════════════════════════════════

resource "confluent_flink_statement" "drop_user_actions" {
  statement = "DROP TABLE IF EXISTS user_actions;"

  properties = {
    "sql.current-catalog"  = confluent_environment.ptf_udf_timer_driven.display_name
    "sql.current-database" = confluent_kafka_cluster.ptf_udf_timer_driven.display_name
  }

  rest_endpoint = data.confluent_flink_region.ptf_udf_timer_driven.rest_endpoint
  credentials {
    key    = module.flink_api_key_rotation.active_api_key.id
    secret = module.flink_api_key_rotation.active_api_key.secret
  }

  organization {
    id = data.confluent_organization.signalroom.id
  }

  environment {
    id = confluent_environment.ptf_udf_timer_driven.id
  }

  principal {
    id = confluent_service_account.flink_sql_runner.id
  }

  compute_pool {
    id = confluent_flink_compute_pool.ptf_udf_timer_driven.id
  }

  depends_on = [
    confluent_kafka_topic.user_actions
  ]

  lifecycle {
    ignore_changes = [statement, compute_pool]
  }
}

resource "confluent_flink_statement" "user_actions_source" {
  statement = <<-EOT
    CREATE TABLE user_actions (
                user_id    STRING,
                event_type STRING,
                payload    STRING,
                event_time TIMESTAMP_LTZ(3),
                WATERMARK FOR event_time AS event_time - INTERVAL '5' SECOND
            );
  EOT

  properties = {
    "sql.current-catalog"  = confluent_environment.ptf_udf_timer_driven.display_name
    "sql.current-database" = confluent_kafka_cluster.ptf_udf_timer_driven.display_name
  }

  rest_endpoint = data.confluent_flink_region.ptf_udf_timer_driven.rest_endpoint
  credentials {
    key    = module.flink_api_key_rotation.active_api_key.id
    secret = module.flink_api_key_rotation.active_api_key.secret
  }

  organization {
    id = data.confluent_organization.signalroom.id
  }

  environment {
    id = confluent_environment.ptf_udf_timer_driven.id
  }

  principal {
    id = confluent_service_account.flink_sql_runner.id
  }

  compute_pool {
    id = confluent_flink_compute_pool.ptf_udf_timer_driven.id
  }

  lifecycle {
    ignore_changes = [compute_pool]
  }

  depends_on = [
    confluent_flink_statement.drop_user_actions,
    confluent_kafka_topic.user_actions
  ]
}

resource "confluent_flink_statement" "insert_user_actions" {
  statement = <<-EOT
    INSERT INTO user_actions (user_id, event_type, payload, event_time)
    VALUES
      ('alice',   'login',    'web',              TO_TIMESTAMP_LTZ(1000, 3)),
      ('bob',     'click',    'button-checkout',  TO_TIMESTAMP_LTZ(2000, 3)),
      ('alice',   'click',    'button-home',      TO_TIMESTAMP_LTZ(30000, 3)),
      ('charlie', 'login',    'mobile',           TO_TIMESTAMP_LTZ(60000, 3)),
      ('alice',   'purchase', 'order-42',         TO_TIMESTAMP_LTZ(120000, 3)),
      ('bob',     'logout',   'session-end',      TO_TIMESTAMP_LTZ(180000, 3));
  EOT

  properties = {
    "sql.current-catalog"  = confluent_environment.ptf_udf_timer_driven.display_name
    "sql.current-database" = confluent_kafka_cluster.ptf_udf_timer_driven.display_name
  }

  rest_endpoint = data.confluent_flink_region.ptf_udf_timer_driven.rest_endpoint
  credentials {
    key    = module.flink_api_key_rotation.active_api_key.id
    secret = module.flink_api_key_rotation.active_api_key.secret
  }

  organization {
    id = data.confluent_organization.signalroom.id
  }

  environment {
    id = confluent_environment.ptf_udf_timer_driven.id
  }

  principal {
    id = confluent_service_account.flink_sql_runner.id
  }

  compute_pool {
    id = confluent_flink_compute_pool.ptf_udf_timer_driven.id
  }

  lifecycle {
    ignore_changes = [compute_pool]
  }

  depends_on = [
    confluent_flink_statement.user_actions_source
  ]
}

resource "confluent_flink_statement" "drop_follow_up_events" {
  statement = "DROP TABLE IF EXISTS follow_up_events;"

  properties = {
    "sql.current-catalog"  = confluent_environment.ptf_udf_timer_driven.display_name
    "sql.current-database" = confluent_kafka_cluster.ptf_udf_timer_driven.display_name
  }

  rest_endpoint = data.confluent_flink_region.ptf_udf_timer_driven.rest_endpoint
  credentials {
    key    = module.flink_api_key_rotation.active_api_key.id
    secret = module.flink_api_key_rotation.active_api_key.secret
  }

  organization {
    id = data.confluent_organization.signalroom.id
  }

  environment {
    id = confluent_environment.ptf_udf_timer_driven.id
  }

  principal {
    id = confluent_service_account.flink_sql_runner.id
  }

  compute_pool {
    id = confluent_flink_compute_pool.ptf_udf_timer_driven.id
  }

  depends_on = [
    confluent_kafka_topic.follow_up_events
  ]

  lifecycle {
    ignore_changes = [statement, compute_pool]
  }
}

resource "confluent_flink_statement" "follow_up_events_sink" {
  statement = <<-EOT
    CREATE TABLE follow_up_events (
                user_id          STRING,
                event_type       STRING,
                payload          STRING,
                event_count      BIGINT,
                follow_up_count  BIGINT,
                is_follow_up     BOOLEAN
            );
  EOT

  properties = {
    "sql.current-catalog"  = confluent_environment.ptf_udf_timer_driven.display_name
    "sql.current-database" = confluent_kafka_cluster.ptf_udf_timer_driven.display_name
  }

  rest_endpoint = data.confluent_flink_region.ptf_udf_timer_driven.rest_endpoint
  credentials {
    key    = module.flink_api_key_rotation.active_api_key.id
    secret = module.flink_api_key_rotation.active_api_key.secret
  }

  organization {
    id = data.confluent_organization.signalroom.id
  }

  environment {
    id = confluent_environment.ptf_udf_timer_driven.id
  }

  principal {
    id = confluent_service_account.flink_sql_runner.id
  }

  compute_pool {
    id = confluent_flink_compute_pool.ptf_udf_timer_driven.id
  }

  lifecycle {
    ignore_changes = [compute_pool]
  }

  depends_on = [
    confluent_flink_statement.insert_user_actions,
    confluent_flink_statement.drop_follow_up_events,
    confluent_kafka_topic.follow_up_events
  ]
}

# ── Unnamed timer-driven UDF registration and pipeline ──────────────────────

resource "confluent_flink_statement" "create_per_event_follow_up" {
  statement = <<-EOT
    CREATE FUNCTION IF NOT EXISTS per_event_follow_up
      AS 'ptf.PerEventFollowUp'
      USING JAR 'confluent-artifact://${confluent_flink_artifact.ptf_udf_timer_driven.id}';
  EOT

  properties = {
    "sql.current-catalog"  = confluent_environment.ptf_udf_timer_driven.display_name
    "sql.current-database" = confluent_kafka_cluster.ptf_udf_timer_driven.display_name
  }

  rest_endpoint = data.confluent_flink_region.ptf_udf_timer_driven.rest_endpoint
  credentials {
    key    = module.flink_api_key_rotation.active_api_key.id
    secret = module.flink_api_key_rotation.active_api_key.secret
  }

  organization {
    id = data.confluent_organization.signalroom.id
  }

  environment {
    id = confluent_environment.ptf_udf_timer_driven.id
  }

  principal {
    id = confluent_service_account.flink_sql_runner.id
  }

  compute_pool {
    id = confluent_flink_compute_pool.ptf_udf_timer_driven.id
  }

  lifecycle {
    ignore_changes = [statement, compute_pool]
  }

  depends_on = [
    confluent_flink_artifact.ptf_udf_timer_driven
  ]
}

resource "confluent_flink_statement" "insert_follow_up_events" {
  statement = <<-EOT
    INSERT INTO follow_up_events
      SELECT
        user_id,
        event_type,
        payload,
        event_count,
        follow_up_count,
        is_follow_up
      FROM TABLE(
        per_event_follow_up(
          input   => TABLE user_actions PARTITION BY user_id,
          on_time => DESCRIPTOR(event_time),
          uid     => 'follow-up-events-v1'
        )
      );
  EOT

  properties = {
    "sql.current-catalog"  = confluent_environment.ptf_udf_timer_driven.display_name
    "sql.current-database" = confluent_kafka_cluster.ptf_udf_timer_driven.display_name
  }

  rest_endpoint = data.confluent_flink_region.ptf_udf_timer_driven.rest_endpoint
  credentials {
    key    = module.flink_api_key_rotation.active_api_key.id
    secret = module.flink_api_key_rotation.active_api_key.secret
  }

  organization {
    id = data.confluent_organization.signalroom.id
  }

  environment {
    id = confluent_environment.ptf_udf_timer_driven.id
  }

  principal {
    id = confluent_service_account.flink_sql_runner.id
  }

  compute_pool {
    id = confluent_flink_compute_pool.ptf_udf_timer_driven.id
  }

  lifecycle {
    ignore_changes = [compute_pool]
  }

  depends_on = [
    confluent_flink_statement.create_per_event_follow_up
  ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# Unnamed timer-driven PTF: SlaMonitor (SLA deadline enforcement)
# ═══════════════════════════════════════════════════════════════════════════════

resource "confluent_flink_statement" "drop_service_requests" {
  statement = "DROP TABLE IF EXISTS service_requests;"

  properties = {
    "sql.current-catalog"  = confluent_environment.ptf_udf_timer_driven.display_name
    "sql.current-database" = confluent_kafka_cluster.ptf_udf_timer_driven.display_name
  }

  rest_endpoint = data.confluent_flink_region.ptf_udf_timer_driven.rest_endpoint
  credentials {
    key    = module.flink_api_key_rotation.active_api_key.id
    secret = module.flink_api_key_rotation.active_api_key.secret
  }

  organization {
    id = data.confluent_organization.signalroom.id
  }

  environment {
    id = confluent_environment.ptf_udf_timer_driven.id
  }

  principal {
    id = confluent_service_account.flink_sql_runner.id
  }

  compute_pool {
    id = confluent_flink_compute_pool.ptf_udf_timer_driven.id
  }

  depends_on = [
    confluent_kafka_topic.service_requests
  ]

  lifecycle {
    ignore_changes = [statement, compute_pool]
  }
}

resource "confluent_flink_statement" "service_requests_source" {
  statement = <<-EOT
    CREATE TABLE service_requests (
                request_id   STRING,
                status       STRING,
                service_name STRING,
                event_time   TIMESTAMP_LTZ(3),
                WATERMARK FOR event_time AS event_time - INTERVAL '5' SECOND
            );
  EOT

  properties = {
    "sql.current-catalog"  = confluent_environment.ptf_udf_timer_driven.display_name
    "sql.current-database" = confluent_kafka_cluster.ptf_udf_timer_driven.display_name
  }

  rest_endpoint = data.confluent_flink_region.ptf_udf_timer_driven.rest_endpoint
  credentials {
    key    = module.flink_api_key_rotation.active_api_key.id
    secret = module.flink_api_key_rotation.active_api_key.secret
  }

  organization {
    id = data.confluent_organization.signalroom.id
  }

  environment {
    id = confluent_environment.ptf_udf_timer_driven.id
  }

  principal {
    id = confluent_service_account.flink_sql_runner.id
  }

  compute_pool {
    id = confluent_flink_compute_pool.ptf_udf_timer_driven.id
  }

  lifecycle {
    ignore_changes = [compute_pool]
  }

  depends_on = [
    confluent_flink_statement.drop_service_requests,
    confluent_kafka_topic.service_requests
  ]
}

resource "confluent_flink_statement" "insert_service_requests" {
  statement = <<-EOT
    INSERT INTO service_requests (request_id, status, service_name, event_time)
    VALUES
      ('REQ-001', 'opened',      'billing',  TO_TIMESTAMP_LTZ(1000, 3)),
      ('REQ-002', 'opened',      'payments', TO_TIMESTAMP_LTZ(2000, 3)),
      ('REQ-001', 'in_progress', 'billing',  TO_TIMESTAMP_LTZ(120000, 3)),
      ('REQ-003', 'opened',      'support',  TO_TIMESTAMP_LTZ(180000, 3)),
      ('REQ-002', 'resolved',    'payments', TO_TIMESTAMP_LTZ(300000, 3));
  EOT

  properties = {
    "sql.current-catalog"  = confluent_environment.ptf_udf_timer_driven.display_name
    "sql.current-database" = confluent_kafka_cluster.ptf_udf_timer_driven.display_name
  }

  rest_endpoint = data.confluent_flink_region.ptf_udf_timer_driven.rest_endpoint
  credentials {
    key    = module.flink_api_key_rotation.active_api_key.id
    secret = module.flink_api_key_rotation.active_api_key.secret
  }

  organization {
    id = data.confluent_organization.signalroom.id
  }

  environment {
    id = confluent_environment.ptf_udf_timer_driven.id
  }

  principal {
    id = confluent_service_account.flink_sql_runner.id
  }

  compute_pool {
    id = confluent_flink_compute_pool.ptf_udf_timer_driven.id
  }

  lifecycle {
    ignore_changes = [compute_pool]
  }

  depends_on = [
    confluent_flink_statement.service_requests_source
  ]
}

resource "confluent_flink_statement" "drop_sla_events" {
  statement = "DROP TABLE IF EXISTS sla_events;"

  properties = {
    "sql.current-catalog"  = confluent_environment.ptf_udf_timer_driven.display_name
    "sql.current-database" = confluent_kafka_cluster.ptf_udf_timer_driven.display_name
  }

  rest_endpoint = data.confluent_flink_region.ptf_udf_timer_driven.rest_endpoint
  credentials {
    key    = module.flink_api_key_rotation.active_api_key.id
    secret = module.flink_api_key_rotation.active_api_key.secret
  }

  organization {
    id = data.confluent_organization.signalroom.id
  }

  environment {
    id = confluent_environment.ptf_udf_timer_driven.id
  }

  principal {
    id = confluent_service_account.flink_sql_runner.id
  }

  compute_pool {
    id = confluent_flink_compute_pool.ptf_udf_timer_driven.id
  }

  depends_on = [
    confluent_kafka_topic.sla_events
  ]

  lifecycle {
    ignore_changes = [statement, compute_pool]
  }
}

resource "confluent_flink_statement" "sla_events_sink" {
  statement = <<-EOT
    CREATE TABLE sla_events (
                request_id   STRING,
                status       STRING,
                service_name STRING,
                update_count BIGINT,
                is_resolved  BOOLEAN,
                is_breach    BOOLEAN
            );
  EOT

  properties = {
    "sql.current-catalog"  = confluent_environment.ptf_udf_timer_driven.display_name
    "sql.current-database" = confluent_kafka_cluster.ptf_udf_timer_driven.display_name
  }

  rest_endpoint = data.confluent_flink_region.ptf_udf_timer_driven.rest_endpoint
  credentials {
    key    = module.flink_api_key_rotation.active_api_key.id
    secret = module.flink_api_key_rotation.active_api_key.secret
  }

  organization {
    id = data.confluent_organization.signalroom.id
  }

  environment {
    id = confluent_environment.ptf_udf_timer_driven.id
  }

  principal {
    id = confluent_service_account.flink_sql_runner.id
  }

  compute_pool {
    id = confluent_flink_compute_pool.ptf_udf_timer_driven.id
  }

  lifecycle {
    ignore_changes = [compute_pool]
  }

  depends_on = [
    confluent_flink_statement.insert_service_requests,
    confluent_flink_statement.drop_sla_events,
    confluent_kafka_topic.sla_events
  ]
}

# ── SLA monitoring UDF registration and pipeline ────────────────────────────

resource "confluent_flink_statement" "create_sla_monitor" {
  statement = <<-EOT
    CREATE FUNCTION IF NOT EXISTS sla_monitor
      AS 'ptf.SlaMonitor'
      USING JAR 'confluent-artifact://${confluent_flink_artifact.ptf_udf_timer_driven.id}';
  EOT

  properties = {
    "sql.current-catalog"  = confluent_environment.ptf_udf_timer_driven.display_name
    "sql.current-database" = confluent_kafka_cluster.ptf_udf_timer_driven.display_name
  }

  rest_endpoint = data.confluent_flink_region.ptf_udf_timer_driven.rest_endpoint
  credentials {
    key    = module.flink_api_key_rotation.active_api_key.id
    secret = module.flink_api_key_rotation.active_api_key.secret
  }

  organization {
    id = data.confluent_organization.signalroom.id
  }

  environment {
    id = confluent_environment.ptf_udf_timer_driven.id
  }

  principal {
    id = confluent_service_account.flink_sql_runner.id
  }

  compute_pool {
    id = confluent_flink_compute_pool.ptf_udf_timer_driven.id
  }

  lifecycle {
    ignore_changes = [statement, compute_pool]
  }

  depends_on = [
    confluent_flink_artifact.ptf_udf_timer_driven
  ]
}

resource "confluent_flink_statement" "insert_sla_events" {
  statement = <<-EOT
    INSERT INTO sla_events
      SELECT
        request_id,
        status,
        service_name,
        update_count,
        is_resolved,
        is_breach
      FROM TABLE(
        sla_monitor(
          input   => TABLE service_requests PARTITION BY request_id,
          on_time => DESCRIPTOR(event_time),
          uid     => 'sla-events-v1'
        )
      );
  EOT

  properties = {
    "sql.current-catalog"  = confluent_environment.ptf_udf_timer_driven.display_name
    "sql.current-database" = confluent_kafka_cluster.ptf_udf_timer_driven.display_name
  }

  rest_endpoint = data.confluent_flink_region.ptf_udf_timer_driven.rest_endpoint
  credentials {
    key    = module.flink_api_key_rotation.active_api_key.id
    secret = module.flink_api_key_rotation.active_api_key.secret
  }

  organization {
    id = data.confluent_organization.signalroom.id
  }

  environment {
    id = confluent_environment.ptf_udf_timer_driven.id
  }

  principal {
    id = confluent_service_account.flink_sql_runner.id
  }

  compute_pool {
    id = confluent_flink_compute_pool.ptf_udf_timer_driven.id
  }

  lifecycle {
    ignore_changes = [compute_pool]
  }

  depends_on = [
    confluent_flink_statement.create_sla_monitor
  ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# Named timer-driven PTF: AbandonedCartDetector (cart abandonment)
# ═══════════════════════════════════════════════════════════════════════════════

resource "confluent_flink_statement" "drop_cart_events" {
  statement = "DROP TABLE IF EXISTS cart_events;"

  properties = {
    "sql.current-catalog"  = confluent_environment.ptf_udf_timer_driven.display_name
    "sql.current-database" = confluent_kafka_cluster.ptf_udf_timer_driven.display_name
  }

  rest_endpoint = data.confluent_flink_region.ptf_udf_timer_driven.rest_endpoint
  credentials {
    key    = module.flink_api_key_rotation.active_api_key.id
    secret = module.flink_api_key_rotation.active_api_key.secret
  }

  organization {
    id = data.confluent_organization.signalroom.id
  }

  environment {
    id = confluent_environment.ptf_udf_timer_driven.id
  }

  principal {
    id = confluent_service_account.flink_sql_runner.id
  }

  compute_pool {
    id = confluent_flink_compute_pool.ptf_udf_timer_driven.id
  }

  depends_on = [
    confluent_kafka_topic.cart_events
  ]

  lifecycle {
    ignore_changes = [statement, compute_pool]
  }
}

resource "confluent_flink_statement" "cart_events_source" {
  statement = <<-EOT
    CREATE TABLE cart_events (
                cart_id    STRING,
                action     STRING,
                item       STRING,
                item_value DOUBLE,
                event_time TIMESTAMP_LTZ(3),
                WATERMARK FOR event_time AS event_time - INTERVAL '5' SECOND
            );
  EOT

  properties = {
    "sql.current-catalog"  = confluent_environment.ptf_udf_timer_driven.display_name
    "sql.current-database" = confluent_kafka_cluster.ptf_udf_timer_driven.display_name
  }

  rest_endpoint = data.confluent_flink_region.ptf_udf_timer_driven.rest_endpoint
  credentials {
    key    = module.flink_api_key_rotation.active_api_key.id
    secret = module.flink_api_key_rotation.active_api_key.secret
  }

  organization {
    id = data.confluent_organization.signalroom.id
  }

  environment {
    id = confluent_environment.ptf_udf_timer_driven.id
  }

  principal {
    id = confluent_service_account.flink_sql_runner.id
  }

  compute_pool {
    id = confluent_flink_compute_pool.ptf_udf_timer_driven.id
  }

  lifecycle {
    ignore_changes = [compute_pool]
  }

  depends_on = [
    confluent_flink_statement.drop_cart_events,
    confluent_kafka_topic.cart_events
  ]
}

resource "confluent_flink_statement" "insert_cart_events" {
  statement = <<-EOT
    INSERT INTO cart_events (cart_id, action, item, item_value, event_time)
    VALUES
      ('CART-001', 'add',      'shoes',  89.99,  TO_TIMESTAMP_LTZ(0, 3)),
      ('CART-002', 'add',      'laptop', 999.00, TO_TIMESTAMP_LTZ(1000, 3)),
      ('CART-001', 'add',      'socks',  12.99,  TO_TIMESTAMP_LTZ(3600000, 3)),
      ('CART-002', 'checkout', 'laptop', 999.00, TO_TIMESTAMP_LTZ(7200000, 3)),
      ('CART-003', 'add',      'book',   24.99,  TO_TIMESTAMP_LTZ(10800000, 3)),
      ('CART-001', 'remove',   'socks',  12.99,  TO_TIMESTAMP_LTZ(14400000, 3)),
      ('CART-999', 'add',      'marker', 1.00,   TO_TIMESTAMP_LTZ(108000000, 3));
  EOT

  properties = {
    "sql.current-catalog"  = confluent_environment.ptf_udf_timer_driven.display_name
    "sql.current-database" = confluent_kafka_cluster.ptf_udf_timer_driven.display_name
  }

  rest_endpoint = data.confluent_flink_region.ptf_udf_timer_driven.rest_endpoint
  credentials {
    key    = module.flink_api_key_rotation.active_api_key.id
    secret = module.flink_api_key_rotation.active_api_key.secret
  }

  organization {
    id = data.confluent_organization.signalroom.id
  }

  environment {
    id = confluent_environment.ptf_udf_timer_driven.id
  }

  principal {
    id = confluent_service_account.flink_sql_runner.id
  }

  compute_pool {
    id = confluent_flink_compute_pool.ptf_udf_timer_driven.id
  }

  lifecycle {
    ignore_changes = [compute_pool]
  }

  depends_on = [
    confluent_flink_statement.cart_events_source
  ]
}

resource "confluent_flink_statement" "drop_abandoned_cart_events" {
  statement = "DROP TABLE IF EXISTS abandoned_cart_events;"

  properties = {
    "sql.current-catalog"  = confluent_environment.ptf_udf_timer_driven.display_name
    "sql.current-database" = confluent_kafka_cluster.ptf_udf_timer_driven.display_name
  }

  rest_endpoint = data.confluent_flink_region.ptf_udf_timer_driven.rest_endpoint
  credentials {
    key    = module.flink_api_key_rotation.active_api_key.id
    secret = module.flink_api_key_rotation.active_api_key.secret
  }

  organization {
    id = data.confluent_organization.signalroom.id
  }

  environment {
    id = confluent_environment.ptf_udf_timer_driven.id
  }

  principal {
    id = confluent_service_account.flink_sql_runner.id
  }

  compute_pool {
    id = confluent_flink_compute_pool.ptf_udf_timer_driven.id
  }

  depends_on = [
    confluent_kafka_topic.abandoned_cart_events
  ]

  lifecycle {
    ignore_changes = [statement, compute_pool]
  }
}

resource "confluent_flink_statement" "abandoned_cart_events_sink" {
  statement = <<-EOT
    CREATE TABLE abandoned_cart_events (
                cart_id      STRING,
                action       STRING,
                item         STRING,
                cart_value   DOUBLE,
                item_count   BIGINT,
                is_abandoned BOOLEAN
            );
  EOT

  properties = {
    "sql.current-catalog"  = confluent_environment.ptf_udf_timer_driven.display_name
    "sql.current-database" = confluent_kafka_cluster.ptf_udf_timer_driven.display_name
  }

  rest_endpoint = data.confluent_flink_region.ptf_udf_timer_driven.rest_endpoint
  credentials {
    key    = module.flink_api_key_rotation.active_api_key.id
    secret = module.flink_api_key_rotation.active_api_key.secret
  }

  organization {
    id = data.confluent_organization.signalroom.id
  }

  environment {
    id = confluent_environment.ptf_udf_timer_driven.id
  }

  principal {
    id = confluent_service_account.flink_sql_runner.id
  }

  compute_pool {
    id = confluent_flink_compute_pool.ptf_udf_timer_driven.id
  }

  lifecycle {
    ignore_changes = [compute_pool]
  }

  depends_on = [
    confluent_flink_statement.insert_cart_events,
    confluent_flink_statement.drop_abandoned_cart_events,
    confluent_kafka_topic.abandoned_cart_events
  ]
}

# ── Abandoned cart UDF registration and pipeline ────────────────────────────

resource "confluent_flink_statement" "create_abandoned_cart_detector" {
  statement = <<-EOT
    CREATE FUNCTION IF NOT EXISTS abandoned_cart_detector
      AS 'ptf.AbandonedCartDetector'
      USING JAR 'confluent-artifact://${confluent_flink_artifact.ptf_udf_timer_driven.id}';
  EOT

  properties = {
    "sql.current-catalog"  = confluent_environment.ptf_udf_timer_driven.display_name
    "sql.current-database" = confluent_kafka_cluster.ptf_udf_timer_driven.display_name
  }

  rest_endpoint = data.confluent_flink_region.ptf_udf_timer_driven.rest_endpoint
  credentials {
    key    = module.flink_api_key_rotation.active_api_key.id
    secret = module.flink_api_key_rotation.active_api_key.secret
  }

  organization {
    id = data.confluent_organization.signalroom.id
  }

  environment {
    id = confluent_environment.ptf_udf_timer_driven.id
  }

  principal {
    id = confluent_service_account.flink_sql_runner.id
  }

  compute_pool {
    id = confluent_flink_compute_pool.ptf_udf_timer_driven.id
  }

  lifecycle {
    ignore_changes = [statement, compute_pool]
  }

  depends_on = [
    confluent_flink_artifact.ptf_udf_timer_driven
  ]
}

resource "confluent_flink_statement" "insert_abandoned_cart_events" {
  statement = <<-EOT
    INSERT INTO abandoned_cart_events
      SELECT
        cart_id,
        action,
        item,
        cart_value,
        item_count,
        is_abandoned
      FROM TABLE(
        abandoned_cart_detector(
          input   => TABLE cart_events PARTITION BY cart_id,
          on_time => DESCRIPTOR(event_time),
          uid     => 'abandoned-cart-events-v1'
        )
      );
  EOT

  properties = {
    "sql.current-catalog"  = confluent_environment.ptf_udf_timer_driven.display_name
    "sql.current-database" = confluent_kafka_cluster.ptf_udf_timer_driven.display_name
  }

  rest_endpoint = data.confluent_flink_region.ptf_udf_timer_driven.rest_endpoint
  credentials {
    key    = module.flink_api_key_rotation.active_api_key.id
    secret = module.flink_api_key_rotation.active_api_key.secret
  }

  organization {
    id = data.confluent_organization.signalroom.id
  }

  environment {
    id = confluent_environment.ptf_udf_timer_driven.id
  }

  principal {
    id = confluent_service_account.flink_sql_runner.id
  }

  compute_pool {
    id = confluent_flink_compute_pool.ptf_udf_timer_driven.id
  }

  lifecycle {
    ignore_changes = [compute_pool]
  }

  depends_on = [
    confluent_flink_statement.create_abandoned_cart_detector
  ]
}
