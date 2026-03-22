terraform {
    cloud {
      organization = "signalroom"

        workspaces {
            name = "apache-flink-kickstarter-ii-ptf-udf-cc-java"
        }
  }

  required_providers {
        confluent = {
            source  = "confluentinc/confluent"
            version = "2.65.0"
        }
    }
}
