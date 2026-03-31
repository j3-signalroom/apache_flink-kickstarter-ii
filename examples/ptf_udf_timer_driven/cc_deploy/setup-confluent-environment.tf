resource "confluent_environment" "ptf_udf_timer_driven" {
  display_name = "ptf-udf-timer-driven"

  stream_governance {
    package = "ESSENTIALS"
  }
}
