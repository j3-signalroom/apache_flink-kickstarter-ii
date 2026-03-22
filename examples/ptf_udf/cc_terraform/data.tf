data "confluent_organization" "signalroom" {}

# Config the environment's schema registry
data "confluent_schema_registry_cluster" "ptf_udf_cc_java" {
  environment {
    id = confluent_environment.ptf_udf_cc_java.id
  }

  depends_on = [
    confluent_kafka_cluster.ptf_udf_cc_java
  ]
}

data "confluent_flink_region" "ptf_udf_cc_java" {
  cloud        = local.cloud
  region       = local.aws_region
}

locals {
    cloud = "AWS"
    aws_region = "us-east-1"
}