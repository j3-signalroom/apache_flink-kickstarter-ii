locals {
    now = timestamp()
    hour_count = var.day_count*24

    sorted_dates = sort(time_rotating.api_key_rotations.*.rfc3339)
    dates_and_count = zipmap(time_rotating.api_key_rotations.*.rfc3339, range(var.number_of_api_keys_to_retain))
    latest_api_key = lookup(local.dates_and_count, local.sorted_dates[0])
}
