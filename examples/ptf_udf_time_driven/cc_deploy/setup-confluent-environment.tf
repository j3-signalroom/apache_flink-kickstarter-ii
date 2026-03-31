resource "confluent_environment" "ptf_udf_time_driven" {
  display_name = "ptf-udf-time-driven"

  stream_governance {
    package = "ESSENTIALS"
  }
}
