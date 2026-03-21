# Service account to perform the task within Confluent Cloud to execute the Flink SQL statements
resource "confluent_service_account" "flink_sql_runner" {
  display_name = "ptf_udf_cc_java"
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
    crn_pattern = "${confluent_kafka_cluster.kafka_cluster.rbac_crn}/kafka=${confluent_kafka_cluster.kafka_cluster.id}/topic=*"

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
    crn_pattern = "${data.confluent_schema_registry_cluster.ptf_udf_cc_java.resource_name}/subject=*"
    
    depends_on = [
        confluent_role_binding.flink_sql_runner_as_assigner
    ]
}

resource "confluent_role_binding" "flink_sql_runner_as_resource_owner_transactional_access" {
    principal   = "User:${confluent_service_account.flink_sql_runner.id}"
    role_name   = "ResourceOwner"
    crn_pattern = "${confluent_kafka_cluster.kafka_cluster.rbac_crn}/kafka=${confluent_kafka_cluster.kafka_cluster.id}/transactional-id=*"

    depends_on = [
        confluent_role_binding.flink_sql_runner_schema_registry_access
    ]
}

resource "confluent_flink_compute_pool" "ptf_udf_cc_java" {
  display_name = "apache_flink_flink_statement_runner"
  cloud        = local.cloud
  region       = local.aws_region
  max_cfu      = 10
  environment {
    id = confluent_environment.ptf_udf_cc_java.id
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
        id          = data.confluent_flink_region.ptf_udf_cc_java.id
        api_version = data.confluent_flink_region.ptf_udf_cc_java.api_version
        kind        = data.confluent_flink_region.ptf_udf_cc_java.kind

        environment = {
            id = confluent_environment.ptf_udf_cc_java.id
        }
    }

    # Optional Input(s)
    key_display_name = "Confluent Schema Registry Cluster Service Account API Key - {date} - Managed by Terraform Cloud"
    number_of_api_keys_to_retain = var.number_of_api_keys_to_retain
    day_count = var.day_count
}

data "confluent_flink_region" "ptf_udf_cc_java" {
  cloud        = local.cloud
  region       = local.aws_region
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
    id          = data.confluent_flink_region.ptf_udf_cc_java.id
    api_version = data.confluent_flink_region.ptf_udf_cc_java.api_version
    kind        = data.confluent_flink_region.ptf_udf_cc_java.kind
    
    environment {
      id = confluent_environment.ptf_udf_cc_java.id
    }
  }

  depends_on = [
    confluent_environment.ptf_udf_cc_java,
    confluent_service_account.flink_sql_runner
  ]
}

# Upload the JAR as a Flink artifact
resource "confluent_flink_artifact" "ptf_udf_cc_java" {
  display_name     = "ptf_udf_cc_java"
  content_format   = "JAR"
  cloud            = local.cloud
  region           = local.aws_region
  artifact_file    = "${path.module}/examples/ptf_udf/cc_java/app/build/libs/app-1.0.0-SNAPSHOT.jar"

  environment {
    id = confluent_environment.ptf_udf_cc_java.id
  }
}

resource "confluent_flink_statement" "create_udf" {
  statement = <<-EOT
    CREATE FUNCTION IF NOT EXISTS user_event_enricher
      AS 'ptf.UserEventEnricher'
      USING JAR 'confluent-artifact://${confluent_flink_artifact.ptf_udf_cc_java.id}';
  EOT

  properties = {
    "sql.current-catalog"  = confluent_environment.ptf_udf_cc_java.display_name
    "sql.current-database" = confluent_kafka_cluster.ptf_udf_cc_java.display_name
  }

  rest_endpoint = data.confluent_flink_region.ptf_udf_cc_java.rest_endpoint
  credentials {
    key    = module.flink_api_key_rotation.current_api_key.key
    secret = module.flink_api_key_rotation.current_api_key.secret
  }

  environment {
    id = confluent_environment.ptf_udf_cc_java.id
  }

  compute_pool {
    id = confluent_flink_compute_pool.ptf_udf_cc_java.id
  }

  # Prevent recreation on every apply — CREATE FUNCTION IF NOT EXISTS handles idempotency
  lifecycle {
    ignore_changes = [statement]
  }
}