resource "cloudflare_dns_record" "api" {
  count   = var.enable_api_ingress ? 1 : 0
  zone_id = var.cloudflare_zone_id
  name    = var.api_hostname
  type    = "A"
  content = var.load_balancer_public_ip
  proxied = true
  ttl     = 1
}

resource "cloudflare_ruleset" "api_no_cache" {
  count   = var.enable_api_ingress ? 1 : 0
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

