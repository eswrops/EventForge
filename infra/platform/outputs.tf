output "app_url" { value = "https://${local.app_fqdn}" }
output "api_url" { value = "https://${local.api_fqdn}" }
output "backend_set_name" { value = try(oci_load_balancer_backend_set.api[0].name, null) }
output "backup_mysql_host" { value = var.mysql_private_ip }

