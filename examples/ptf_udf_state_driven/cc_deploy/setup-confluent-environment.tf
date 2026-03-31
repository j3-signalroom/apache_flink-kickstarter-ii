resource "confluent_environment" "ptf_udf" {
  display_name = "ptf-udf"

  stream_governance {
    package = "ESSENTIALS"
  }
}