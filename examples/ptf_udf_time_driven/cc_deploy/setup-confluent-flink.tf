# Service account to perform the task within Confluent Cloud to execute the Flink SQL statements
resource "confluent_service_account" "flink_sql_runner" {
  display_name = "ptf-udf-time-driven"
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
    crn_pattern = "${confluent_kafka_cluster.ptf_udf_time_driven.rbac_crn}/kafka=${confluent_kafka_cluster.ptf_udf_time_driven.id}/topic=*"

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
    crn_pattern = "${data.confluent_schema_registry_cluster.ptf_udf_time_driven.resource_name}/subject=*"

    depends_on = [
        confluent_role_binding.flink_sql_runner_as_assigner
    ]
}

resource "confluent_role_binding" "flink_sql_runner_as_resource_owner_transactional_access" {
    principal   = "User:${confluent_service_account.flink_sql_runner.id}"
    role_name   = "ResourceOwner"
    crn_pattern = "${confluent_kafka_cluster.ptf_udf_time_driven.rbac_crn}/kafka=${confluent_kafka_cluster.ptf_udf_time_driven.id}/transactional-id=*"

    depends_on = [
        confluent_role_binding.flink_sql_runner_schema_registry_access
    ]
}

resource "confluent_flink_compute_pool" "ptf_udf_time_driven" {
  display_name = "apache_flink_flink_statement_runner"
  cloud        = local.cloud
  region       = local.aws_region
  max_cfu      = 10
  environment {
    id = confluent_environment.ptf_udf_time_driven.id
  }
  depends_on = [
    confluent_role_binding.flink_sql_runner_as_resource_owner_transactional_access,
    confluent_api_key.flink_sql_runner_api_key,
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
        id          = data.confluent_flink_region.ptf_udf_time_driven.id
        api_version = data.confluent_flink_region.ptf_udf_time_driven.api_version
        kind        = data.confluent_flink_region.ptf_udf_time_driven.kind

        environment = {
            id = confluent_environment.ptf_udf_time_driven.id
        }
    }

    # Optional Input(s)
    key_display_name = "Confluent Schema Registry Cluster Service Account API Key - {date} - Managed by Terraform Cloud"
    number_of_api_keys_to_retain = var.number_of_api_keys_to_retain
    day_count = var.day_count
}

# Create the Flink-specific API key that will be used to submit statements.
resource "confluent_api_key" "flink_sql_runner_api_key" {
  display_name = "apache_flink_flink_statements_runner_api_key"
  description  = "Flink API Key that is owned by 'flink_sql_runner' service account"
  owner {
    id          = confluent_service_account.flink_sql_runner.id
    api_version = confluent_service_account.flink_sql_runner.api_version
    kind        = confluent_service_account.flink_sql_runner.kind
  }
  managed_resource {
    id          = data.confluent_flink_region.ptf_udf_time_driven.id
    api_version = data.confluent_flink_region.ptf_udf_time_driven.api_version
    kind        = data.confluent_flink_region.ptf_udf_time_driven.kind

    environment {
      id = confluent_environment.ptf_udf_time_driven.id
    }
  }

  depends_on = [
    confluent_environment.ptf_udf_time_driven,
    confluent_service_account.flink_sql_runner
  ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# Time-driven PTF: SessionTimeoutDetector (timer-based inactivity)
# ═══════════════════════════════════════════════════════════════════════════════

resource "confluent_flink_statement" "drop_user_activity" {
  statement = "DROP TABLE IF EXISTS user_activity;"

  properties = {
    "sql.current-catalog"  = confluent_environment.ptf_udf_time_driven.display_name
    "sql.current-database" = confluent_kafka_cluster.ptf_udf_time_driven.display_name
  }

  rest_endpoint = data.confluent_flink_region.ptf_udf_time_driven.rest_endpoint
  credentials {
    key    = module.flink_api_key_rotation.active_api_key.id
    secret = module.flink_api_key_rotation.active_api_key.secret
  }

  organization {
    id = data.confluent_organization.signalroom.id
  }

  environment {
    id = confluent_environment.ptf_udf_time_driven.id
  }

  principal {
    id = confluent_service_account.flink_sql_runner.id
  }

  compute_pool {
    id = confluent_flink_compute_pool.ptf_udf_time_driven.id
  }

  lifecycle {
    ignore_changes = [statement]
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
    "sql.current-catalog"  = confluent_environment.ptf_udf_time_driven.display_name
    "sql.current-database" = confluent_kafka_cluster.ptf_udf_time_driven.display_name
  }

  rest_endpoint = data.confluent_flink_region.ptf_udf_time_driven.rest_endpoint
  credentials {
    key    = module.flink_api_key_rotation.active_api_key.id
    secret = module.flink_api_key_rotation.active_api_key.secret
  }

  organization {
    id = data.confluent_organization.signalroom.id
  }

  environment {
    id = confluent_environment.ptf_udf_time_driven.id
  }

  principal {
    id = confluent_service_account.flink_sql_runner.id
  }

  compute_pool {
    id = confluent_flink_compute_pool.ptf_udf_time_driven.id
  }

  depends_on = [
    confluent_flink_statement.drop_user_activity
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
    "sql.current-catalog"  = confluent_environment.ptf_udf_time_driven.display_name
    "sql.current-database" = confluent_kafka_cluster.ptf_udf_time_driven.display_name
  }

  rest_endpoint = data.confluent_flink_region.ptf_udf_time_driven.rest_endpoint
  credentials {
    key    = module.flink_api_key_rotation.active_api_key.id
    secret = module.flink_api_key_rotation.active_api_key.secret
  }

  organization {
    id = data.confluent_organization.signalroom.id
  }

  environment {
    id = confluent_environment.ptf_udf_time_driven.id
  }

  principal {
    id = confluent_service_account.flink_sql_runner.id
  }

  compute_pool {
    id = confluent_flink_compute_pool.ptf_udf_time_driven.id
  }

  depends_on = [
    confluent_flink_statement.user_activity_source
  ]
}

resource "confluent_flink_statement" "drop_timeout_events" {
  statement = "DROP TABLE IF EXISTS timeout_events;"

  properties = {
    "sql.current-catalog"  = confluent_environment.ptf_udf_time_driven.display_name
    "sql.current-database" = confluent_kafka_cluster.ptf_udf_time_driven.display_name
  }

  rest_endpoint = data.confluent_flink_region.ptf_udf_time_driven.rest_endpoint
  credentials {
    key    = module.flink_api_key_rotation.active_api_key.id
    secret = module.flink_api_key_rotation.active_api_key.secret
  }

  organization {
    id = data.confluent_organization.signalroom.id
  }

  environment {
    id = confluent_environment.ptf_udf_time_driven.id
  }

  principal {
    id = confluent_service_account.flink_sql_runner.id
  }

  compute_pool {
    id = confluent_flink_compute_pool.ptf_udf_time_driven.id
  }

  lifecycle {
    ignore_changes = [statement]
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
    "sql.current-catalog"  = confluent_environment.ptf_udf_time_driven.display_name
    "sql.current-database" = confluent_kafka_cluster.ptf_udf_time_driven.display_name
  }

  rest_endpoint = data.confluent_flink_region.ptf_udf_time_driven.rest_endpoint
  credentials {
    key    = module.flink_api_key_rotation.active_api_key.id
    secret = module.flink_api_key_rotation.active_api_key.secret
  }

  organization {
    id = data.confluent_organization.signalroom.id
  }

  environment {
    id = confluent_environment.ptf_udf_time_driven.id
  }

  principal {
    id = confluent_service_account.flink_sql_runner.id
  }

  compute_pool {
    id = confluent_flink_compute_pool.ptf_udf_time_driven.id
  }

  depends_on = [
    confluent_flink_statement.insert_user_activity,
    confluent_flink_statement.drop_timeout_events
  ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# Upload the JAR as a Flink artifact
# ═══════════════════════════════════════════════════════════════════════════════

resource "confluent_flink_artifact" "ptf_udf_time_driven" {
  display_name     = "ptf-udf-time-driven"
  content_format   = "JAR"
  cloud            = local.cloud
  region           = local.aws_region
  artifact_file    = "${path.module}/../java/app/build/libs/app-1.0.0-SNAPSHOT.jar"

  environment {
    id = confluent_environment.ptf_udf_time_driven.id
  }

  depends_on = [
    confluent_flink_statement.insert_user_activity,
    confluent_flink_statement.timeout_events_sink,
  ]
}

# ── Time-driven UDF registration and pipeline ─────────────────────────────────

resource "confluent_flink_statement" "create_session_timeout_detector" {
  statement = <<-EOT
    CREATE FUNCTION IF NOT EXISTS session_timeout_detector
      AS 'ptf.SessionTimeoutDetector'
      USING JAR 'confluent-artifact://${confluent_flink_artifact.ptf_udf_time_driven.id}';
  EOT

  properties = {
    "sql.current-catalog"  = confluent_environment.ptf_udf_time_driven.display_name
    "sql.current-database" = confluent_kafka_cluster.ptf_udf_time_driven.display_name
  }

  rest_endpoint = data.confluent_flink_region.ptf_udf_time_driven.rest_endpoint
  credentials {
    key    = module.flink_api_key_rotation.active_api_key.id
    secret = module.flink_api_key_rotation.active_api_key.secret
  }

  organization {
    id = data.confluent_organization.signalroom.id
  }

  environment {
    id = confluent_environment.ptf_udf_time_driven.id
  }

  principal {
    id = confluent_service_account.flink_sql_runner.id
  }

  compute_pool {
    id = confluent_flink_compute_pool.ptf_udf_time_driven.id
  }

  lifecycle {
    ignore_changes = [statement]
  }

  depends_on = [
    confluent_flink_artifact.ptf_udf_time_driven
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
          on_time => DESCRIPTOR(event_time)
        )
      );
  EOT

  properties = {
    "sql.current-catalog"  = confluent_environment.ptf_udf_time_driven.display_name
    "sql.current-database" = confluent_kafka_cluster.ptf_udf_time_driven.display_name
  }

  rest_endpoint = data.confluent_flink_region.ptf_udf_time_driven.rest_endpoint
  credentials {
    key    = module.flink_api_key_rotation.active_api_key.id
    secret = module.flink_api_key_rotation.active_api_key.secret
  }

  organization {
    id = data.confluent_organization.signalroom.id
  }

  environment {
    id = confluent_environment.ptf_udf_time_driven.id
  }

  principal {
    id = confluent_service_account.flink_sql_runner.id
  }

  compute_pool {
    id = confluent_flink_compute_pool.ptf_udf_time_driven.id
  }

  depends_on = [
    confluent_flink_statement.create_session_timeout_detector
  ]
}
