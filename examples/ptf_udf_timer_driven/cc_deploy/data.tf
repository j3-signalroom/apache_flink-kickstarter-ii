data "confluent_organization" "signalroom" {}

# Config the environment's schema registry
data "confluent_schema_registry_cluster" "ptf_udf_timer_driven" {
  environment {
    id = confluent_environment.ptf_udf_timer_driven.id
  }

  depends_on = [
    confluent_kafka_cluster.ptf_udf_timer_driven
  ]
}

data "confluent_flink_region" "ptf_udf_timer_driven" {
  cloud        = local.cloud
  region       = local.aws_region
}

locals {
    cloud = "AWS"
    aws_region = "us-east-1"
}
