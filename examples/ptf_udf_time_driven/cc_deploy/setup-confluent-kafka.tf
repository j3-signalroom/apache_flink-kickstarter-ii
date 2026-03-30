resource "confluent_kafka_cluster" "ptf_udf_time_driven" {
  display_name = "ptf-udf-time-driven"
  availability = "SINGLE_ZONE"
  cloud        = local.cloud
  region       = local.aws_region
  standard     {}

  environment {
    id = confluent_environment.ptf_udf_time_driven.id
  }
}
