resource "confluent_environment" "scalar_udf" {
  display_name = "scalar-udf"

  stream_governance {
    package = "ESSENTIALS"
  }
}