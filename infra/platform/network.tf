locals {
  app_fqdn = "${var.app_hostname}.${var.root_domain}"
  api_fqdn = "${var.api_hostname}.${var.root_domain}"
}

resource "oci_core_network_security_group" "lb" {
  compartment_id = var.compartment_ocid
  vcn_id         = var.vcn_ocid
  display_name   = "eventforge-lb-nsg"
}

resource "oci_core_network_security_group" "app" {
  compartment_id = var.compartment_ocid
  vcn_id         = var.vcn_ocid
  display_name   = "eventforge-app-nsg"
}

resource "oci_core_network_security_group" "db" {
  compartment_id = var.compartment_ocid
  vcn_id         = var.vcn_ocid
  display_name   = "eventforge-db-nsg"
}

resource "oci_core_network_security_group_security_rule" "lb_ingress_https" {
  network_security_group_id = oci_core_network_security_group.lb.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source_type               = "CIDR_BLOCK"
  source                    = each.value
  stateless                 = false
  description               = "HTTPS only from Cloudflare origin ranges"
  tcp_options {
    destination_port_range {
      min = 443
      max = 443
    }
  }
  for_each = var.cloudflare_origin_cidrs
}

resource "oci_core_network_security_group_security_rule" "lb_to_app" {
  network_security_group_id = oci_core_network_security_group.app.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source_type               = "NETWORK_SECURITY_GROUP"
  source                    = oci_core_network_security_group.lb.id
  stateless                 = false
  description               = "API traffic only from EventForge load balancer"
  tcp_options {
    destination_port_range {
      min = 8080
      max = 8080
    }
  }
}

resource "oci_core_network_security_group_security_rule" "ssh_from_operator" {
  network_security_group_id = oci_core_network_security_group.app.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source_type               = "CIDR_BLOCK"
  source                    = var.operator_ssh_cidr
  stateless                 = false
  description               = "Break-glass SSH from operator /32"
  tcp_options {
    destination_port_range {
      min = 22
      max = 22
    }
  }
}

resource "oci_core_network_security_group_security_rule" "app_to_mysql" {
  network_security_group_id = oci_core_network_security_group.app.id
  direction                 = "EGRESS"
  protocol                  = "6"
  destination_type          = "NETWORK_SECURITY_GROUP"
  destination               = oci_core_network_security_group.db.id
  stateless                 = false
  description               = "MySQL only to EventForge DB NSG"
  tcp_options {
    destination_port_range {
      min = 3306
      max = 3306
    }
  }
}

resource "oci_core_network_security_group_security_rule" "mysql_from_app" {
  network_security_group_id = oci_core_network_security_group.db.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source_type               = "NETWORK_SECURITY_GROUP"
  source                    = oci_core_network_security_group.app.id
  stateless                 = false
  description               = "MySQL only from EventForge application NSG"
  tcp_options {
    destination_port_range {
      min = 3306
      max = 3306
    }
  }
}

# Attach these NSG IDs while importing the existing primary VNICs and MySQL
# endpoint into imported_resources.tf. That generated configuration must retain
# current NSGs and append the IDs below; this root never replaces subnet lists.
output "required_app_nsg_id" { value = oci_core_network_security_group.app.id }
output "required_db_nsg_id" { value = oci_core_network_security_group.db.id }
output "required_lb_nsg_id" { value = oci_core_network_security_group.lb.id }

