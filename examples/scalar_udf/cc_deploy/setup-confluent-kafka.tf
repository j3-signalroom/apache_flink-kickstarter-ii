resource "confluent_kafka_cluster" "scalar_udf" {
  display_name = "scalar-udf"
  availability = "SINGLE_ZONE"
  cloud        = local.cloud
  region       = local.aws_region
  standard {}

  environment {
    id = confluent_environment.scalar_udf.id
  }
}

# Create the Environment API Key Pairs, rotate them in accordance to a time schedule, and provide the current
# acitve API Key Pair to use
module "kafka_api_key_rotation" {
  source = "github.com/j3-signalroom/iac-confluent-api_key_rotation-tf_module"

  # Required Input(s)
  owner = {
    id          = confluent_service_account.flink_sql_runner.id
    api_version = confluent_service_account.flink_sql_runner.api_version
    kind        = confluent_service_account.flink_sql_runner.kind
  }

  resource = {
    id          = confluent_kafka_cluster.scalar_udf.id
    api_version = confluent_kafka_cluster.scalar_udf.api_version
    kind        = confluent_kafka_cluster.scalar_udf.kind

    environment = {
      id = confluent_environment.scalar_udf.id
    }
  }

  # Optional Input(s)
  key_display_name             = "Kafka Service Account API Key - {date} - Managed by Terraform Cloud"
  number_of_api_keys_to_retain = var.number_of_api_keys_to_retain
  day_count                    = var.day_count

  depends_on = [
    confluent_role_binding.flink_sql_runner_as_resource_owner_topic_access
  ]
}

# Explicitly manage the Kafka topics so terraform destroy cleans them up
resource "confluent_kafka_topic" "celsius_reading" {
  kafka_cluster {
    id = confluent_kafka_cluster.scalar_udf.id
  }
  topic_name    = "celsius_reading"
  rest_endpoint = confluent_kafka_cluster.scalar_udf.rest_endpoint
  credentials {
    key    = module.kafka_api_key_rotation.active_api_key.id
    secret = module.kafka_api_key_rotation.active_api_key.secret
  }
}

resource "confluent_kafka_topic" "celsius_to_fahrenheit" {
  kafka_cluster {
    id = confluent_kafka_cluster.scalar_udf.id
  }
  topic_name    = "celsius_to_fahrenheit"
  rest_endpoint = confluent_kafka_cluster.scalar_udf.rest_endpoint
  credentials {
    key    = module.kafka_api_key_rotation.active_api_key.id
    secret = module.kafka_api_key_rotation.active_api_key.secret
  }
}

resource "confluent_kafka_topic" "fahrenheit_reading" {
  kafka_cluster {
    id = confluent_kafka_cluster.scalar_udf.id
  }
  topic_name    = "fahrenheit_reading"
  rest_endpoint = confluent_kafka_cluster.scalar_udf.rest_endpoint
  credentials {
    key    = module.kafka_api_key_rotation.active_api_key.id
    secret = module.kafka_api_key_rotation.active_api_key.secret
  }
}

resource "confluent_kafka_topic" "fahrenheit_to_celsius" {
  kafka_cluster {
    id = confluent_kafka_cluster.scalar_udf.id
  }
  topic_name    = "fahrenheit_to_celsius"
  rest_endpoint = confluent_kafka_cluster.scalar_udf.rest_endpoint
  credentials {
    key    = module.kafka_api_key_rotation.active_api_key.id
    secret = module.kafka_api_key_rotation.active_api_key.secret
  }
}
