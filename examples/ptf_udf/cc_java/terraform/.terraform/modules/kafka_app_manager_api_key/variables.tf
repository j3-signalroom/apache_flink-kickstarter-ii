variable "day_count" {
    description = "How many day(s) should the API Key be rotated for."
    type = number
    default = 30
    
    validation {
        condition = var.day_count >= 1
        error_message = "Rolling day count, `day_count`, must be greater than or equal to 1."
    }
}

variable "number_of_api_keys_to_retain" {
    description = "Specifies the number of API keys to create and retain.  Must be greater than or equal to 2 in order to maintain proper key rotation for your application(s)."
    type = number
    default = 2
    
    validation {
        condition = var.number_of_api_keys_to_retain >= 2
        error_message = "Number of API keys to retain, `number_of_api_keys_to_retain`, must be greater than or equal to 2."
    }
}

variable "key_display_name" {
    description = "A descriptive name for the API key."
    type = string
    default = "Confluent Service Account API Key - {date} - Managed by Terraform Confluent"
}

variable "owner" {
    description = "API Key Owner.  Refer to [Confluent API Key Docs](https://registry.terraform.io/providers/confluentinc/confluent/latest/docs/resources/confluent_api_key#argument-reference) for more info."
    type = object({
        id = string
        api_version = string
        kind = string
    })
}

variable "resource" {
    description = "Resource the API Key is associated with.  Refer to [Confluent API Key Docs](https://registry.terraform.io/providers/confluentinc/confluent/latest/docs/resources/confluent_api_key#argument-reference) for more info."
    type = object({
        id = string
        api_version = string
        kind = string
        environment = object({
            id = string
        })
    })    
}

variable "disable_wait_for_ready" {
  description = "Whether to skip waiting for API key to sync (set true for PrivateLink clusters when running outside VPC)"
  type        = bool
  default     = false
}