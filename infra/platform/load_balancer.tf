resource "terraform_data" "api_origin_generation" {
  input = var.origin_certificate_generation
}

resource "tls_private_key" "api_origin" {
  count     = var.enable_api_ingress ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 2048

  lifecycle {
    replace_triggered_by = [terraform_data.api_origin_generation]
  }
}

resource "tls_cert_request" "api_origin" {
  count           = var.enable_api_ingress ? 1 : 0
  private_key_pem = tls_private_key.api_origin[0].private_key_pem
  dns_names       = [local.api_fqdn]

  subject {
    common_name = local.api_fqdn
  }
}

resource "cloudflare_origin_ca_certificate" "api" {
  count              = var.enable_api_ingress ? 1 : 0
  csr                = tls_cert_request.api_origin[0].cert_request_pem
  hostnames          = [local.api_fqdn]
  requested_validity = 5475
  request_type       = "origin-rsa"
}

resource "oci_load_balancer_certificate" "api_origin" {
  count              = var.enable_api_ingress ? 1 : 0
  load_balancer_id   = var.load_balancer_ocid
  certificate_name   = "eventforge-origin-${var.origin_certificate_generation}"
  public_certificate = cloudflare_origin_ca_certificate.api[0].certificate
  private_key        = tls_private_key.api_origin[0].private_key_pem

  lifecycle {
    create_before_destroy = true
  }
}

resource "oci_load_balancer_backend_set" "api" {
  count            = var.enable_api_ingress ? 1 : 0
  load_balancer_id = var.load_balancer_ocid
  name             = "eventforge-api-backends"
  policy           = "ROUND_ROBIN"

  health_checker {
    protocol          = "HTTP"
    port              = 8080
    url_path          = "/readyz"
    return_code       = 200
    interval_ms       = 10000
    timeout_in_millis = 3000
    retries           = 3
  }
}

resource "oci_load_balancer_backend" "api" {
  for_each         = var.enable_api_ingress ? var.api_private_ips : {}
  load_balancer_id = var.load_balancer_ocid
  backendset_name  = oci_load_balancer_backend_set.api[0].name
  ip_address       = each.value
  port             = 8080
  backup           = false
  drain            = false
  offline          = false
  weight           = 1
}

resource "oci_load_balancer_listener" "https" {
  count                    = var.enable_api_ingress ? 1 : 0
  load_balancer_id         = var.load_balancer_ocid
  name                     = "eventforge-https"
  default_backend_set_name = oci_load_balancer_backend_set.api[0].name
  port                     = 443
  protocol                 = "HTTP"

  ssl_configuration {
    certificate_name = oci_load_balancer_certificate.api_origin[0].certificate_name
  }
}

