terraform {
    cloud {
      organization = "signalroom"

        workspaces {
            name = "apache-flink-kickstarter-ii-ptf-udf-timer-driven"
        }
  }

  required_providers {
        confluent = {
            source  = "confluentinc/confluent"
            version = "2.70.0"
        }
    }
}
