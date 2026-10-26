resource "cloudflare_dns_record" "api" {
  zone_id = var.cloudflare_zone_id
  name    = var.api_hostname
  type    = "A"
  content = var.load_balancer_public_ip
  proxied = true
  ttl     = 1
}

resource "cloudflare_zone_setting" "ssl" {
  zone_id    = var.cloudflare_zone_id
  setting_id = "ssl"
  value      = "strict"
}

resource "cloudflare_ruleset" "api_no_cache" {
  zone_id = var.cloudflare_zone_id
  name    = "eventforge-api-no-cache"
  kind    = "zone"
  phase   = "http_request_cache_settings"

  rules = [{
    action            = "set_cache_settings"
    expression        = "http.host eq \"${local.api_fqdn}\""
    description       = "API responses must not be cached at the edge"
    action_parameters = { cache = false }
  }]
}

