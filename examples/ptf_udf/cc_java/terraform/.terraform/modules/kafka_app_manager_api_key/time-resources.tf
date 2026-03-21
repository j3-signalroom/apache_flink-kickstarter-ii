# This controls each key's rotations
resource "time_rotating" "api_key_rotations" {
    count = var.number_of_api_keys_to_retain
    rotation_days = var.day_count*var.number_of_api_keys_to_retain
    rfc3339 = timeadd(local.now, format("-%sh", (count.index)*local.hour_count))
}

# Store the retain API keys and the time when the rotation needs to accord  In order, to 
# trigger a `replace_triggered_by` on the API Key.  Refer to GitHub Issue for more info
# https://github.com/hashicorp/terraform-provider-time/issues/118
resource "time_static" "api_key_rotations" {
    count = var.number_of_api_keys_to_retain
    rfc3339 = time_rotating.api_key_rotations[count.index].rfc3339
}
