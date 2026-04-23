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

# ============================================================================
# UDF 1: CelsiusToFahrenheit
# ============================================================================

resource "confluent_flink_statement" "drop_celsius_reading" {
  statement = "DROP TABLE IF EXISTS celsius_reading;"

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
    ignore_changes = [statement, compute_pool]
  }
}

resource "confluent_flink_statement" "celsius_reading_source" {
  statement = <<-EOT
    CREATE TABLE celsius_reading (
        sensor_id               BIGINT,
        celsius_temperature     DOUBLE
    );
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
    confluent_flink_statement.drop_celsius_reading,
    confluent_kafka_topic.celsius_reading
  ]
}

resource "confluent_flink_statement" "insert_celsius_reading" {
  statement = <<-EOT
    INSERT INTO celsius_reading (sensor_id, celsius_temperature)
    VALUES
        (1000, 18),
        (1001, 20),
        (1002, 22),
        (1003, 24),
        (1004, 26),
        (1005, 28);
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
    confluent_flink_statement.celsius_reading_source
  ]
}

resource "confluent_flink_statement" "drop_celsius_to_fahrenheit" {
  statement = "DROP TABLE IF EXISTS celsius_to_fahrenheit;"

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
    ignore_changes = [statement, compute_pool]
  }
}

resource "confluent_flink_statement" "celsius_to_fahrenheit_source" {
  statement = <<-EOT
    CREATE TABLE celsius_to_fahrenheit (
      sensor_id               BIGINT,
      celsius_temperature     DOUBLE,
      fahrenheit_temperature  DOUBLE
    );
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
    confluent_flink_statement.drop_celsius_to_fahrenheit,
    confluent_kafka_topic.celsius_to_fahrenheit
  ]
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
    confluent_flink_statement.celsius_to_fahrenheit_source
  ]
}

resource "confluent_flink_statement" "create_celsius_udf" {
  statement = <<-EOT
    CREATE FUNCTION celsius_to_fahrenheit
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

resource "confluent_flink_statement" "celsius_to_fahrenheit_sink" {
  statement = <<-EOT
    INSERT INTO celsius_to_fahrenheit (sensor_id, celsius_temperature, fahrenheit_temperature)
        SELECT 
            sensor_id, celsius_temperature, celsius_to_fahrenheit(celsius_temperature)
        FROM
            celsius_reading;
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
# UDF 2: FahrenheitToCelsius
# ============================================================================
resource "confluent_flink_statement" "drop_fahrenheit_reading" {
  statement = "DROP TABLE IF EXISTS fahrenheit_reading;"

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
    ignore_changes = [statement, compute_pool]
  }
}

resource "confluent_flink_statement" "fahrenheit_reading_source" {
  statement = <<-EOT
      CREATE TABLE fahrenheit_reading (
          sensor_id               BIGINT,
          fahrenheit_temperature  DOUBLE
      );
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
    confluent_flink_statement.drop_fahrenheit_reading,
    confluent_kafka_topic.fahrenheit_reading
  ]
}

resource "confluent_flink_statement" "insert_fahrenheit_reading" {
  statement = <<-EOT
    INSERT INTO fahrenheit_reading (sensor_id, fahrenheit_temperature)
    VALUES
        (2000, 64.4),
        (2001, 68),
        (2002, 71.6),
        (2003, 75.2),
        (2004, 78.8),
        (2005, 82.4);
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
    confluent_flink_statement.fahrenheit_reading_source
  ]
}

resource "confluent_flink_statement" "drop_fahrenheit_to_celsius" {
  statement = "DROP TABLE IF EXISTS fahrenheit_to_celsius;"

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
    ignore_changes = [statement, compute_pool]
  }
}

resource "confluent_flink_statement" "fahrenheit_to_celsius_source" {
  statement = <<-EOT
    CREATE TABLE fahrenheit_to_celsius (
        sensor_id               BIGINT,
        fahrenheit_temperature  DOUBLE,
        celsius_temperature     DOUBLE
    );
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
    confluent_flink_statement.drop_fahrenheit_to_celsius,
    confluent_kafka_topic.fahrenheit_to_celsius
  ]
}

resource "confluent_flink_statement" "create_fahrenheit_udf" {
  statement = <<-EOT
    CREATE FUNCTION fahrenheit_to_celsius
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

resource "confluent_flink_statement" "fahrenheit_to_celsius_sink" {
  statement = <<-EOT
    INSERT INTO fahrenheit_to_celsius (sensor_id, fahrenheit_temperature, celsius_temperature)
      SELECT
          sensor_id, fahrenheit_temperature, fahrenheit_to_celsius(fahrenheit_temperature)
      FROM
          fahrenheit_reading;
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
# Python UDFs (Confluent Cloud Early Access — requires the feature flag to be
# enabled on your org; see README §3.0).
#
# The Python path shares the source topics (celsius_reading, fahrenheit_reading)
# and source tables with the Java path, but writes to separate _py sink topics
# so the two language paths don't interleave rows. Function names are also
# suffixed with _py to keep them distinct from the Java UDFs in the same catalog.
# ============================================================================

# Upload the Python sdist (wrapped in a ZIP per CC's artifact format) as a
# Flink artifact. Built by `make build-scalar-udf-cc-python` from
# examples/scalar_udf/python_cc/, which pins apache-flink==2.0.0 as CC requires.
resource "confluent_flink_artifact" "scalar_udf_python" {
  display_name     = "ptf-udf-python"
  content_format   = "ZIP"
  runtime_language = "Python"
  cloud            = local.cloud
  region           = local.aws_region
  artifact_file    = "${path.module}/../python_cc/dist/scalar_udf_cc-0.1.0.zip"

  environment {
    id = confluent_environment.scalar_udf.id
  }

  depends_on = [
    confluent_flink_statement.fahrenheit_to_celsius_sink
  ]
}

# ─── Python UDF 1: celsius_to_fahrenheit_py ─────────────────────────────────

resource "confluent_flink_statement" "drop_celsius_to_fahrenheit_py" {
  statement = "DROP TABLE IF EXISTS celsius_to_fahrenheit_py;"

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
    ignore_changes = [statement, compute_pool]
  }
}

resource "confluent_flink_statement" "celsius_to_fahrenheit_py_source" {
  statement = <<-EOT
    CREATE TABLE celsius_to_fahrenheit_py (
      sensor_id               BIGINT,
      celsius_temperature     DOUBLE,
      fahrenheit_temperature  DOUBLE
    );
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
    confluent_flink_statement.drop_celsius_to_fahrenheit_py,
    confluent_kafka_topic.celsius_to_fahrenheit_py
  ]
}

resource "confluent_flink_statement" "create_celsius_udf_py" {
  # Function address is `<package>.<module>.<symbol>` per the CC Python UDF
  # examples repo (confluentinc/flink-udf-python-examples).
  statement = <<-EOT
    CREATE FUNCTION celsius_to_fahrenheit_py
      AS 'scalar_udf.celsius_to_fahrenheit.celsius_to_fahrenheit'
      LANGUAGE PYTHON
      USING JAR 'confluent-artifact://${confluent_flink_artifact.scalar_udf_python.id}';
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
    ignore_changes = [statement, compute_pool]
  }

  depends_on = [
    confluent_flink_artifact.scalar_udf_python,
    confluent_flink_statement.celsius_to_fahrenheit_py_source
  ]
}

resource "confluent_flink_statement" "celsius_to_fahrenheit_py_sink" {
  statement = <<-EOT
    INSERT INTO celsius_to_fahrenheit_py (sensor_id, celsius_temperature, fahrenheit_temperature)
        SELECT
            sensor_id, celsius_temperature, celsius_to_fahrenheit_py(celsius_temperature)
        FROM
            celsius_reading;
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
    confluent_flink_statement.create_celsius_udf_py
  ]
}

# ─── Python UDF 2: fahrenheit_to_celsius_py ─────────────────────────────────

resource "confluent_flink_statement" "drop_fahrenheit_to_celsius_py" {
  statement = "DROP TABLE IF EXISTS fahrenheit_to_celsius_py;"

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
    ignore_changes = [statement, compute_pool]
  }
}

resource "confluent_flink_statement" "fahrenheit_to_celsius_py_source" {
  statement = <<-EOT
    CREATE TABLE fahrenheit_to_celsius_py (
        sensor_id               BIGINT,
        fahrenheit_temperature  DOUBLE,
        celsius_temperature     DOUBLE
    );
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
    confluent_flink_statement.drop_fahrenheit_to_celsius_py,
    confluent_kafka_topic.fahrenheit_to_celsius_py
  ]
}

resource "confluent_flink_statement" "create_fahrenheit_udf_py" {
  statement = <<-EOT
    CREATE FUNCTION fahrenheit_to_celsius_py
      AS 'scalar_udf.fahrenheit_to_celsius.fahrenheit_to_celsius'
      LANGUAGE PYTHON
      USING JAR 'confluent-artifact://${confluent_flink_artifact.scalar_udf_python.id}';
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
    ignore_changes = [statement, compute_pool]
  }

  depends_on = [
    confluent_flink_artifact.scalar_udf_python,
    confluent_flink_statement.fahrenheit_to_celsius_py_source
  ]
}

resource "confluent_flink_statement" "fahrenheit_to_celsius_py_sink" {
  statement = <<-EOT
    INSERT INTO fahrenheit_to_celsius_py (sensor_id, fahrenheit_temperature, celsius_temperature)
      SELECT
          sensor_id, fahrenheit_temperature, fahrenheit_to_celsius_py(fahrenheit_temperature)
      FROM
          fahrenheit_reading;
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
    confluent_flink_statement.create_fahrenheit_udf_py
  ]
}