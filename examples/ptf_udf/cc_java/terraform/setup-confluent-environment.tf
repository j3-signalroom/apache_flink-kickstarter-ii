resource "confluent_environment" "ptf_udf_cc_java" {
  display_name = "ptf_udf_cc_java"

  stream_governance {
    package = "ESSENTIALS"
  }
}