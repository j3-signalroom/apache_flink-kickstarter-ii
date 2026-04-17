resource "confluent_kafka_cluster" "scalar_udf" {
  display_name = "ptf-udf-row-driven"
  availability = "SINGLE_ZONE"
  cloud        = local.cloud
  region       = local.aws_region
  standard {}

  environment {
    id = confluent_environment.scalar_udf.id
  }
}
