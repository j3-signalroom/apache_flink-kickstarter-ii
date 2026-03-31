resource "confluent_kafka_cluster" "ptf_udf" {
  display_name = "ptf-udf"
  availability = "SINGLE_ZONE"
  cloud        = local.cloud
  region       = local.aws_region
  standard     {}

  environment {
    id = confluent_environment.ptf_udf.id
  }
}
