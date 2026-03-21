# Create the Confluent Resouce API Key Pair based on the service account from the Confluent Resource 
# (e.g., Kafka Cluster or Schema Registry)
resource "confluent_api_key" "resouce_api_key" {
    count = var.number_of_api_keys_to_retain
    display_name = replace(var.key_display_name, "{date}", time_static.api_key_rotations[count.index].rfc3339)
    description  = "Creation of the Confluent Resource API Key managed by Terraform Cloud using Confluent API Key Rotation Module"

    owner {
        id          = var.owner.id
        api_version = var.owner.api_version
        kind        = var.owner.kind
    }

    managed_resource {
        id          = var.resource.id
        api_version = var.resource.api_version
        kind        = var.resource.kind

        environment {
            id = var.resource.environment.id
        }
    }

    # To skip DNS-dependent validation:
    disable_wait_for_ready = var.disable_wait_for_ready

    lifecycle {
        replace_triggered_by = [time_static.api_key_rotations[count.index]]
    }
}
