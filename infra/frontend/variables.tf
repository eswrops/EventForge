variable "cloudflare_account_id" { type = string }
variable "cloudflare_zone_id" { type = string }
variable "cloudflare_api_token" {
  type      = string
  sensitive = true
}
variable "root_domain" { type = string }
variable "app_hostname" {
  type    = string
  default = "app"
}
variable "worker_name" {
  type    = string
  default = "eventforge-frontend"
}
variable "release_tag" {
  type        = string
  description = "Immutable Git revision or release tag shown in Cloudflare Worker metadata."
}

