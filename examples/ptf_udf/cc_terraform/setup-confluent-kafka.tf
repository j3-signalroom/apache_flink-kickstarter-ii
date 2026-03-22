resource "confluent_kafka_cluster" "ptf_udf_cc_java" {
  display_name = "ptf_udf_cc_java"
  availability = "SINGLE_ZONE"
  cloud        = local.cloud
  region       = local.aws_region
  standard     {}

  environment {
    id = confluent_environment.ptf_udf_cc_java.id
  }
}
