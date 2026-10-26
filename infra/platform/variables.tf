variable "tenancy_ocid" { type = string }
variable "compartment_ocid" { type = string }
variable "region" { type = string }
variable "vcn_ocid" { type = string }
variable "app_subnet_ocid" { type = string }
variable "lb_subnet_ocid" { type = string }
variable "mysql_subnet_ocid" { type = string }
variable "load_balancer_ocid" { type = string }
variable "load_balancer_public_ip" { type = string }
variable "mysql_db_system_ocid" { type = string }
variable "mysql_private_ip" { type = string }
variable "api_private_ips" {
  type = map(string)

  validation {
    condition     = length(var.api_private_ips) == 2 && contains(keys(var.api_private_ips), "vm1") && contains(keys(var.api_private_ips), "vm2")
    error_message = "api_private_ips must contain exactly vm1 and vm2 private addresses."
  }
}
variable "operator_ssh_cidr" {
  type = string

  validation {
    condition     = can(cidrnetmask(var.operator_ssh_cidr)) && endswith(var.operator_ssh_cidr, "/32")
    error_message = "operator_ssh_cidr must be one IPv4 /32."
  }
}
variable "cloudflare_origin_cidrs" {
  type        = set(string)
  description = "Reviewed Cloudflare published origin-facing IPv4/IPv6 ranges."

  validation {
    condition     = length(var.cloudflare_origin_cidrs) > 0 && alltrue([for cidr in var.cloudflare_origin_cidrs : can(cidrnetmask(cidr))])
    error_message = "Provide valid, reviewed Cloudflare CIDR ranges."
  }
}
variable "cloudflare_account_id" { type = string }
variable "cloudflare_zone_id" { type = string }
variable "cloudflare_api_token" {
  type      = string
  sensitive = true
}
variable "root_domain" {
  type = string
  validation {
    condition     = can(regex("^[A-Za-z0-9.-]+$", var.root_domain))
    error_message = "root_domain must be a DNS name without a scheme."
  }
}
variable "app_hostname" {
  type    = string
  default = "app"
}
variable "api_hostname" {
  type    = string
  default = "api"
}
variable "operations_topic_id" { type = string }
variable "notification_email" { type = string }
variable "monthly_budget_amount" {
  type    = number
  default = 5
}

