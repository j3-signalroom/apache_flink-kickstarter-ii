resource "confluent_kafka_cluster" "ptf_udf_timer_driven" {
  display_name = "ptf-udf-timer-driven"
  availability = "SINGLE_ZONE"
  cloud        = local.cloud
  region       = local.aws_region
  standard     {}

  environment {
    id = confluent_environment.ptf_udf_timer_driven.id
  }
}

# Create the Environment API Key Pairs, rotate them in accordance to a time schedule, and provide the current
# acitve API Key Pair to use
module "kafka_api_key_rotation" {
  source  = "github.com/j3-signalroom/iac-confluent-api_key_rotation-tf_module"

  # Required Input(s)
  owner = {
    id          = confluent_service_account.flink_sql_runner.id
    api_version = confluent_service_account.flink_sql_runner.api_version
    kind        = confluent_service_account.flink_sql_runner.kind
  }

  resource = {
    id          = confluent_kafka_cluster.ptf_udf_timer_driven.id
    api_version = confluent_kafka_cluster.ptf_udf_timer_driven.api_version
    kind        = confluent_kafka_cluster.ptf_udf_timer_driven.kind

    environment = {
      id = confluent_environment.ptf_udf_timer_driven.id
    }
  }

  # Optional Input(s)
  key_display_name = "Kafka Service Account API Key - {date} - Managed by Terraform Cloud"
  number_of_api_keys_to_retain = var.number_of_api_keys_to_retain
  day_count = var.day_count

  depends_on = [
    confluent_role_binding.flink_sql_runner_as_resource_owner_topic_access
  ]
}

# Explicitly manage the Kafka topics so terraform destroy cleans them up
resource "confluent_kafka_topic" "user_activity" {
  kafka_cluster {
    id = confluent_kafka_cluster.ptf_udf_timer_driven.id
  }
  topic_name    = "user_activity"
  rest_endpoint = confluent_kafka_cluster.ptf_udf_timer_driven.rest_endpoint
  credentials {
    key    = module.kafka_api_key_rotation.active_api_key.id
    secret = module.kafka_api_key_rotation.active_api_key.secret
  }
}

resource "confluent_kafka_topic" "timeout_events" {
  kafka_cluster {
    id = confluent_kafka_cluster.ptf_udf_timer_driven.id
  }
  topic_name    = "timeout_events"
  rest_endpoint = confluent_kafka_cluster.ptf_udf_timer_driven.rest_endpoint
  credentials {
    key    = module.kafka_api_key_rotation.active_api_key.id
    secret = module.kafka_api_key_rotation.active_api_key.secret
  }
}
