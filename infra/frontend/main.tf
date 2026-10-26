locals {
  app_fqdn = "${var.app_hostname}.${var.root_domain}"
}

# The pipeline replaces public/ with the built Leptos/WASM asset output before
# applying this root. The checked-in placeholder makes validation deterministic.
resource "cloudflare_workers_script" "frontend" {
  account_id     = var.cloudflare_account_id
  script_name    = var.worker_name
  content_file   = "${path.module}/worker/index.js"
  content_sha256 = filesha256("${path.module}/worker/index.js")
  main_module    = "index.js"
  assets = {
    directory = "${path.module}/public"
  }
  annotations = {
    workers_tag     = var.release_tag
    workers_message = "EventForge frontend ${var.release_tag}"
  }
}

resource "cloudflare_workers_custom_domain" "app" {
  account_id = var.cloudflare_account_id
  zone_id    = var.cloudflare_zone_id
  zone_name  = var.root_domain
  hostname   = local.app_fqdn
  service    = cloudflare_workers_script.frontend.script_name
}

resource "cloudflare_workers_script_subdomain" "frontend" {
  account_id       = var.cloudflare_account_id
  script_name      = cloudflare_workers_script.frontend.script_name
  enabled          = false
  previews_enabled = false
}

output "frontend_url" {
  value = "https://${local.app_fqdn}"
}

