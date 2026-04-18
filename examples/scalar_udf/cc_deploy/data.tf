data "confluent_organization" "signalroom" {}

# Config the environment's schema registry
data "confluent_schema_registry_cluster" "scalar_udf" {
  environment {
    id = confluent_environment.scalar_udf.id
  }

  depends_on = [
    confluent_kafka_cluster.scalar_udf
  ]
}

data "confluent_flink_region" "scalar_udf" {
  cloud  = local.cloud
  region = local.aws_region
}

locals {
  cloud      = "AWS"
  aws_region = "us-east-1"
}