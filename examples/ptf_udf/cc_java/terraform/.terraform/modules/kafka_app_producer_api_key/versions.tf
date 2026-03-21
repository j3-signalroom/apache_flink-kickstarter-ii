terraform {
    required_version = ">= 1.11.0"

    required_providers {
        confluent = {
            source  = "confluentinc/confluent"
            version = "~> 2.40"
        }
    }
}
