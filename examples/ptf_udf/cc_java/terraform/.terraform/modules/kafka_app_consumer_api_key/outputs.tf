output "active_api_key" {
    value       = confluent_api_key.resouce_api_key[local.latest_api_key]
    description = "The current active API Key to be used for new logins.  Refer to [Confluent/confluent_api_key](https://registry.terraform.io/providers/confluentinc/confluent/latest/docs/resources/confluent_api_key) for the expected structure."
}

output "all_api_keys" {
    value       = [for d in local.sorted_dates : confluent_api_key.resouce_api_key[lookup(local.dates_and_count, d)]]
    description = "All API keys sorted by creation date.  With the current active API Key being the 1st in the collection."
}