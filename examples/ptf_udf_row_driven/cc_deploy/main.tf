terraform {
  cloud {
    organization = "signalroom"

    workspaces {
      name = "apache-flink-kickstarter-ii-ptf-udf"
    }
  }

  required_providers {
    confluent = {
      source  = "confluentinc/confluent"
      version = "2.68.0"
    }
  }
}
