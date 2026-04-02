resource "confluent_environment" "ptf_udf_row_driven" {
  display_name = "ptf-udf-row-driven"

  stream_governance {
    package = "ESSENTIALS"
  }
}