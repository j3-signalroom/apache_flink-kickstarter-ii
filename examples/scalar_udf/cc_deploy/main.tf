terraform {
  cloud {
    organization = "signalroom"

    workspaces {
      name = "apache-flink-kickstarter-ii-scalar-udf"
    }
  }

  required_providers {
    confluent = {
      source  = "confluentinc/confluent"
      version = "2.69.0"
    }
  }
}
