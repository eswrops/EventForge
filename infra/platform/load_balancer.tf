resource "tls_private_key" "api_origin" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_cert_request" "api_origin" {
  private_key_pem = tls_private_key.api_origin.private_key_pem
  dns_names       = [local.api_fqdn]

  subject {
    common_name = local.api_fqdn
  }
}

resource "cloudflare_origin_ca_certificate" "api" {
  csr                = tls_cert_request.api_origin.cert_request_pem
  hostnames          = [local.api_fqdn]
  requested_validity = 5475
  request_type       = "origin-rsa"
}

resource "oci_load_balancer_certificate" "api_origin" {
  load_balancer_id   = var.load_balancer_ocid
  certificate_name   = "eventforge-origin-v1"
  public_certificate = cloudflare_origin_ca_certificate.api.certificate
  private_key        = tls_private_key.api_origin.private_key_pem

  lifecycle {
    create_before_destroy = true
  }
}

resource "oci_load_balancer_backend_set" "api" {
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
  for_each         = var.api_private_ips
  load_balancer_id = var.load_balancer_ocid
  backendset_name  = oci_load_balancer_backend_set.api.name
  ip_address       = each.value
  port             = 8080
  backup           = false
  drain            = false
  offline          = false
  weight           = 1
}

resource "oci_load_balancer_listener" "https" {
  load_balancer_id         = var.load_balancer_ocid
  name                     = "eventforge-https"
  default_backend_set_name = oci_load_balancer_backend_set.api.name
  port                     = 443
  protocol                 = "HTTP"

  ssl_configuration {
    certificate_name = oci_load_balancer_certificate.api_origin.certificate_name
  }
}

