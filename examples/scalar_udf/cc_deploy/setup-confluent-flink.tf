# Service account to perform the task within Confluent Cloud to execute the Flink SQL statements
resource "confluent_service_account" "flink_sql_runner" {
  display_name = "ptf-udf"
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
  crn_pattern = "${confluent_kafka_cluster.scalar_udf.rbac_crn}/kafka=${confluent_kafka_cluster.scalar_udf.id}/topic=*"

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
  crn_pattern = "${data.confluent_schema_registry_cluster.scalar_udf.resource_name}/subject=*"

  depends_on = [
    confluent_role_binding.flink_sql_runner_as_assigner
  ]
}

resource "confluent_role_binding" "flink_sql_runner_as_resource_owner_transactional_access" {
  principal   = "User:${confluent_service_account.flink_sql_runner.id}"
  role_name   = "ResourceOwner"
  crn_pattern = "${confluent_kafka_cluster.scalar_udf.rbac_crn}/kafka=${confluent_kafka_cluster.scalar_udf.id}/transactional-id=*"

  depends_on = [
    confluent_role_binding.flink_sql_runner_schema_registry_access
  ]
}

resource "confluent_flink_compute_pool" "scalar_udf" {
  display_name = "apache_flink_flink_statement_runner"
  cloud        = local.cloud
  region       = local.aws_region
  max_cfu      = 10
  environment {
    id = confluent_environment.scalar_udf.id
  }
  depends_on = [
    confluent_role_binding.flink_sql_runner_as_resource_owner_transactional_access
  ]
}

# Create the Environment API Key Pairs, rotate them in accordance to a time schedule, and provide the current
# acitve API Key Pair to use
module "flink_api_key_rotation" {
  source = "github.com/j3-signalroom/iac-confluent-api_key_rotation-tf_module"

  # Required Input(s)
  owner = {
    id          = confluent_service_account.flink_sql_runner.id
    api_version = confluent_service_account.flink_sql_runner.api_version
    kind        = confluent_service_account.flink_sql_runner.kind
  }

  resource = {
    id          = data.confluent_flink_region.scalar_udf.id
    api_version = data.confluent_flink_region.scalar_udf.api_version
    kind        = data.confluent_flink_region.scalar_udf.kind

    environment = {
      id = confluent_environment.scalar_udf.id
    }
  }

  # Optional Input(s)
  key_display_name             = "Flink Service Account API Key - {date} - Managed by Terraform Cloud"
  number_of_api_keys_to_retain = var.number_of_api_keys_to_retain
  day_count                    = var.day_count
}

# Upload the JAR as a Flink artifact
resource "confluent_flink_artifact" "scalar_udf" {
  display_name   = "ptf-udf"
  content_format = "JAR"
  cloud          = local.cloud
  region         = local.aws_region
  artifact_file  = "${path.module}/../java/app/build/libs/app-1.0.0-SNAPSHOT.jar"

  environment {
    id = confluent_environment.scalar_udf.id
  }

  depends_on = [
    confluent_flink_statement.insert_user_events,
    confluent_flink_statement.enriched_events_sink,
    confluent_flink_statement.insert_orders,
    confluent_flink_statement.orders_expanded_sink,
  ]
}

# ============================================================================
# UDF 1: CelsiusToFahrenheit — select example
# ============================================================================

resource "confluent_flink_statement" "create_celsius_udf" {
  statement = <<-EOT
    CREATE FUNCTION CelsiusToFahrenheit
      AS 'scalar_udf.CelsiusToFahrenheit'
      USING JAR 'confluent-artifact://${confluent_flink_artifact.scalar_udf.id}';
  EOT

  properties = {
    "sql.current-catalog"  = confluent_environment.scalar_udf.display_name
    "sql.current-database" = confluent_kafka_cluster.scalar_udf.display_name
  }

  rest_endpoint = data.confluent_flink_region.scalar_udf.rest_endpoint
  credentials {
    key    = module.flink_api_key_rotation.active_api_key.id
    secret = module.flink_api_key_rotation.active_api_key.secret
  }

  organization {
    id = data.confluent_organization.signalroom.id
  }

  environment {
    id = confluent_environment.scalar_udf.id
  }

  principal {
    id = confluent_service_account.flink_sql_runner.id
  }

  compute_pool {
    id = confluent_flink_compute_pool.scalar_udf.id
  }

  # Prevent recreation on every apply — CREATE FUNCTION IF NOT EXISTS handles idempotency
  lifecycle {
    ignore_changes = [statement, compute_pool]
  }

  depends_on = [
    confluent_flink_artifact.scalar_udf
  ]
}

resource "confluent_flink_statement" "celsius_udf_example" {
  statement = <<-EOT
    SELECT 
      20 temperature_in_celsius, CelsiusToFahrenheit(temperature_in_celsius) AS temperature_in_fahrenheit;
  EOT

  properties = {
    "sql.current-catalog"  = confluent_environment.scalar_udf.display_name
    "sql.current-database" = confluent_kafka_cluster.scalar_udf.display_name
  }

  rest_endpoint = data.confluent_flink_region.scalar_udf.rest_endpoint
  credentials {
    key    = module.flink_api_key_rotation.active_api_key.id
    secret = module.flink_api_key_rotation.active_api_key.secret
  }

  organization {
    id = data.confluent_organization.signalroom.id
  }

  environment {
    id = confluent_environment.scalar_udf.id
  }

  principal {
    id = confluent_service_account.flink_sql_runner.id
  }

  compute_pool {
    id = confluent_flink_compute_pool.scalar_udf.id
  }

  lifecycle {
    ignore_changes = [compute_pool]
  }

  depends_on = [
    confluent_flink_statement.create_celsius_udf
  ]
}

# ============================================================================
# UDF 2: FahrenheitToCelsius — select example
# ============================================================================

resource "confluent_flink_statement" "create_fahrenheit_udf" {
  statement = <<-EOT
    CREATE FUNCTION FahrenheitToCelsius
      AS 'scalar_udf.FahrenheitToCelsius'
      USING JAR 'confluent-artifact://${confluent_flink_artifact.scalar_udf.id}';
  EOT

  properties = {
    "sql.current-catalog"  = confluent_environment.scalar_udf.display_name
    "sql.current-database" = confluent_kafka_cluster.scalar_udf.display_name
  }

  rest_endpoint = data.confluent_flink_region.scalar_udf.rest_endpoint
  credentials {
    key    = module.flink_api_key_rotation.active_api_key.id
    secret = module.flink_api_key_rotation.active_api_key.secret
  }

  organization {
    id = data.confluent_organization.signalroom.id
  }

  environment {
    id = confluent_environment.scalar_udf.id
  }

  principal {
    id = confluent_service_account.flink_sql_runner.id
  }

  compute_pool {
    id = confluent_flink_compute_pool.scalar_udf.id
  }

  # Prevent recreation on every apply — CREATE FUNCTION IF NOT EXISTS handles idempotency
  lifecycle {
    ignore_changes = [statement, compute_pool]
  }

  depends_on = [
    confluent_flink_artifact.scalar_udf
  ]
}

resource "confluent_flink_statement" "fahrenheit_udf_example" {
  statement = <<-EOT
    SELECT 
      70 temperature_in_fahrenheit, FahrenheitToCelsius(temperature_in_fahrenheit) AS temperature_in_celsius;
  EOT

  properties = {
    "sql.current-catalog"  = confluent_environment.scalar_udf.display_name
    "sql.current-database" = confluent_kafka_cluster.scalar_udf.display_name
  }

  rest_endpoint = data.confluent_flink_region.scalar_udf.rest_endpoint
  credentials {
    key    = module.flink_api_key_rotation.active_api_key.id
    secret = module.flink_api_key_rotation.active_api_key.secret
  }

  organization {
    id = data.confluent_organization.signalroom.id
  }

  environment {
    id = confluent_environment.scalar_udf.id
  }

  principal {
    id = confluent_service_account.flink_sql_runner.id
  }

  compute_pool {
    id = confluent_flink_compute_pool.scalar_udf.id
  }

  lifecycle {
    ignore_changes = [compute_pool]
  }

  depends_on = [
    confluent_flink_statement.create_fahrenheit_udf
  ]
}
