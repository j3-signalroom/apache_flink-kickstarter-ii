# Create the Kafka cluster
resource "confluent_kafka_cluster" "ptf_udf_cc_java" {
  display_name = "ptf_udf_cc_java"
  availability = "SINGLE_ZONE"
  cloud        = local.cloud
  region       = local.aws_region
  standard     {}

  environment {
    id = confluent_environment.ptf_udf_cc_java.id
  }
}

# 'app_manager' service account is required in this configuration to create 'user_events' and 'enriched_events'
# topics and grant ACLs to 'app_producer' and 'app_consumer' service accounts.
resource "confluent_service_account" "app_manager" {
  display_name = "ptf_udf_cc_java_app_manager"
  description  = "Apache Flink Kickstarter Service account to manage Kafka cluster"

  depends_on = [ 
    confluent_kafka_cluster.ptf_udf_cc_java
  ]
}

resource "confluent_role_binding" "app_manager_kafka_cluster_admin" {
  principal   = "User:${confluent_service_account.app_manager.id}"
  role_name   = "CloudClusterAdmin"
  crn_pattern = confluent_kafka_cluster.ptf_udf_cc_java.rbac_crn

  depends_on = [ 
    confluent_service_account.app_manager 
  ]
}

# Creates the app_manager Kafka Cluster API Key Pairs, rotate them in accordance to a time schedule,
# and provide the current acitve API Key Pair to use
module "kafka_app_manager_api_key" {
  source = "github.com/j3-signalroom/iac-confluent-api_key_rotation-tf_module"

  #Required Input(s)
  owner = {
    id          = confluent_service_account.app_manager.id
    api_version = confluent_service_account.app_manager.api_version
    kind        = confluent_service_account.app_manager.kind
  }

  resource = {
    id          = confluent_kafka_cluster.ptf_udf_cc_java.id
    api_version = confluent_kafka_cluster.ptf_udf_cc_java.api_version
    kind        = confluent_kafka_cluster.ptf_udf_cc_java.kind

    environment = {
      id = confluent_environment.ptf_udf_cc_java.id
    }
  }

  # Optional Input(s)
  key_display_name             = "Confluent Kafka Cluster Service Account API Key - {date} - Managed by Terraform Cloud"
  number_of_api_keys_to_retain = var.number_of_api_keys_to_retain
  day_count                    = var.day_count
}

# Create the `user_events` Kafka topic
resource "confluent_kafka_topic" "user_events" {
  kafka_cluster {
    id = confluent_kafka_cluster.ptf_udf_cc_java.id
  }
  topic_name    = "user_events"
  rest_endpoint = confluent_kafka_cluster.ptf_udf_cc_java.rest_endpoint
  credentials {
    key    = module.kafka_app_manager_api_key.active_api_key.id
    secret = module.kafka_app_manager_api_key.active_api_key.secret
  }

  depends_on = [ 
    confluent_role_binding.app_manager_kafka_cluster_admin,
    module.kafka_app_manager_api_key 
  ]
}

resource "confluent_service_account" "app_consumer" {
  display_name = "ptf_udf_cc_java_app_consumer"
  description  = "Apache Flink Kickstarter Service account to consume from 'user_events' topic of Kafka cluster"
}

module "kafka_app_consumer_api_key" {
  source = "github.com/j3-signalroom/iac-confluent-api_key_rotation-tf_module"

  #Required Input(s)
  owner = {
    id          = confluent_service_account.app_consumer.id
    api_version = confluent_service_account.app_consumer.api_version
    kind        = confluent_service_account.app_consumer.kind
  }

  resource = {
    id          = confluent_kafka_cluster.ptf_udf_cc_java.id
    api_version = confluent_kafka_cluster.ptf_udf_cc_java.api_version
    kind        = confluent_kafka_cluster.ptf_udf_cc_java.kind

    environment = {
      id = confluent_environment.ptf_udf_cc_java.id
    }
  }

  # Optional Input(s)
  key_display_name             = "Confluent Kafka Cluster Service Account API Key - {date} - Managed by Terraform Cloud"
  number_of_api_keys_to_retain = var.number_of_api_keys_to_retain
  day_count                    = var.day_count
}

# Create the `enriched_events` Kafka topic
resource "confluent_kafka_topic" "enriched_events" {
  kafka_cluster {
    id = confluent_kafka_cluster.ptf_udf_cc_java.id
  }
  topic_name    = "enriched_events"
  rest_endpoint = confluent_kafka_cluster.ptf_udf_cc_java.rest_endpoint
  credentials {
    key    = module.kafka_app_manager_api_key.active_api_key.id
    secret = module.kafka_app_manager_api_key.active_api_key.secret
  }

  depends_on = [ 
    confluent_role_binding.app_manager_kafka_cluster_admin,
    module.kafka_app_manager_api_key 
  ]
}

resource "confluent_kafka_acl" "app_producer_write_on_topic" {
  kafka_cluster {
    id = confluent_kafka_cluster.ptf_udf_cc_java.id
  }
  resource_type = "TOPIC"
  resource_name = confluent_kafka_topic.enriched_events.topic_name
  pattern_type  = "LITERAL"
  principal     = "User:${confluent_service_account.app_producer.id}"
  host          = "*"
  operation     = "WRITE"
  permission    = "ALLOW"
  rest_endpoint = confluent_kafka_cluster.ptf_udf_cc_java.rest_endpoint
  credentials {
    key    = module.kafka_app_producer_api_key.active_api_key.id
    secret = module.kafka_app_producer_api_key.active_api_key.secret
  }
}

resource "confluent_service_account" "app_producer" {
  display_name = "ptf_udf_cc_java_app_producer"
  description  = "Apache Flink Kickstarter Service account to produce to 'enriched_events' topic of Kafka cluster"
}

module "kafka_app_producer_api_key" {
  source = "github.com/j3-signalroom/iac-confluent-api_key_rotation-tf_module"

  #Required Input(s)
  owner = {
    id          = confluent_service_account.app_producer.id
    api_version = confluent_service_account.app_producer.api_version
    kind        = confluent_service_account.app_producer.kind
  }

  resource = {
    id          = confluent_kafka_cluster.ptf_udf_cc_java.id
    api_version = confluent_kafka_cluster.ptf_udf_cc_java.api_version
    kind        = confluent_kafka_cluster.ptf_udf_cc_java.kind

    environment = {
      id = confluent_environment.ptf_udf_cc_java.id
    }
  }

  # Optional Input(s)
  key_display_name             = "Confluent Kafka Cluster Service Account API Key - {date} - Managed by Terraform Cloud"
  number_of_api_keys_to_retain = var.number_of_api_keys_to_retain
  day_count                    = var.day_count
}


resource "confluent_kafka_acl" "app_consumer_read_on_group" {
  kafka_cluster {
    id = confluent_kafka_cluster.ptf_udf_cc_java.id
  }
  resource_type = "GROUP"
  resource_name = "apache_flink_kickstarter"
  pattern_type  = "LITERAL"
  principal     = "User:${confluent_service_account.app_consumer.id}"
  host          = "*"
  operation     = "READ"
  permission    = "ALLOW"
  rest_endpoint = confluent_kafka_cluster.ptf_udf_cc_java.rest_endpoint
  credentials {
    key    = module.kafka_app_manager_api_key.active_api_key.id
    secret = module.kafka_app_manager_api_key.active_api_key.secret
  }
}

resource "confluent_kafka_acl" "app_consumer_read_on_topic" {
  kafka_cluster {
    id = confluent_kafka_cluster.ptf_udf_cc_java.id
  }
  resource_type = "TOPIC"
  resource_name = confluent_kafka_topic.user_events.topic_name
  pattern_type  = "LITERAL"
  principal     = "User:${confluent_service_account.app_consumer.id}"
  host          = "*"
  operation     = "READ"
  permission    = "ALLOW"
  rest_endpoint = confluent_kafka_cluster.ptf_udf_cc_java.rest_endpoint
  credentials {
    key    = module.kafka_app_manager_api_key.active_api_key.id
    secret = module.kafka_app_manager_api_key.active_api_key.secret
  }
}
