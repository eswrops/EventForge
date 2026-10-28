# Imported existing-resource declarations — the production inventory of the
# M1-LOCAL platform root (2026-10-27), tracked in Git for declarative
# reproducibility: a clean checkout supplied with the protected operator input
# files must manage exactly these eight addresses (seven blocks; the two API
# hosts share one for_each block).
#
# Discovery values (OCIDs, private addresses, availability/fault domains,
# image IDs) are account-specific and deliberately NOT committed. They are
# supplied by the git-ignored infra/platform/imported.auto.tfvars (template:
# imported.auto.tfvars.example), populated from the live OCI discovery bundle.
#
# Import-safety contract enforced here:
#   - prevent_destroy on every imported resource (never removed)
#   - shared route table + security lists pinned as read-only OCID inputs,
#     never declared here; never replaced by this root
#   - NSG attachment: the scope-A reviewed change (2026-10-28,
#     docs/acceptance/m1-local/scope-a-network-execution-approval.md) appends
#     exactly one eventforge-* NSG to each imported component below — an
#     append-only association change; no pre-existing membership existed, and
#     security lists / route tables stay pinned and untouched
#   - narrowly scoped ignore_changes only: instance runtime attributes and
#     the MySQL admin credential pair (write-only, invisible to the API);
#     never broad ignores
#   - MySQL admin values come from the operator vault via sensitive vars and
#     are never printed or committed

variable "imported_api_instances" {
  type = map(object({
    availability_domain = string
    fault_domain        = string
    shape               = string
    display_name        = string
    hostname_label      = string
    private_ip          = string
    source_type         = string
    source_id           = string
  }))
  description = "Discovered per-instance values for the two existing API hosts (imported.auto.tfvars)."
}

# MySQL admin credentials come from the operator vault only. They are not
# returned by the DB-system API (hence the narrow ignore_changes below) and
# must never be committed; the import flow refuses placeholders.
variable "mysql_admin_username" {
  type      = string
  sensitive = true
  default   = ""
}

variable "mysql_admin_password" {
  type      = string
  sensitive = true
  default   = ""
}

variable "imported_shared_route_table_id" {
  type        = string
  description = "OCID of the route table shared by all existing subnets (imported.auto.tfvars)."
}

variable "imported_subnet_security_lists" {
  type        = map(list(string))
  description = "Security-list OCIDs pinned per existing subnet, keyed app/lb/mysql (imported.auto.tfvars)."
}

variable "imported_mysql_availability_domain" {
  type        = string
  description = "Tenancy-specific availability domain of the existing MySQL DB system (imported.auto.tfvars)."
}

resource "oci_core_vcn" "existing" {
  compartment_id = var.vcn_compartment_ocid
  cidr_blocks    = ["10.0.0.0/16"]
  display_name   = "postgresmax-vcn"
  dns_label      = "pgmax"

  lifecycle { prevent_destroy = true }
}

resource "oci_core_subnet" "app" {
  compartment_id             = var.vcn_compartment_ocid
  vcn_id                     = oci_core_vcn.existing.id
  cidr_block                 = "10.0.2.0/24"
  display_name               = "rust-api-test-public-subnet"
  dns_label                  = "rusttest"
  route_table_id             = var.imported_shared_route_table_id
  security_list_ids          = var.imported_subnet_security_lists["app"]
  prohibit_public_ip_on_vnic = false

  lifecycle { prevent_destroy = true }
}

resource "oci_core_subnet" "lb" {
  compartment_id             = var.vcn_compartment_ocid
  vcn_id                     = oci_core_vcn.existing.id
  cidr_block                 = "10.0.4.0/24"
  display_name               = "rust-api-lb-public-subnet"
  dns_label                  = "rustlb"
  route_table_id             = var.imported_shared_route_table_id
  security_list_ids          = var.imported_subnet_security_lists["lb"]
  prohibit_public_ip_on_vnic = false

  lifecycle { prevent_destroy = true }
}

resource "oci_core_subnet" "mysql" {
  compartment_id             = var.vcn_compartment_ocid
  vcn_id                     = oci_core_vcn.existing.id
  cidr_block                 = "10.0.3.0/24"
  display_name               = "rust-api-db-private-subnet"
  dns_label                  = "rustdb"
  route_table_id             = var.imported_shared_route_table_id
  security_list_ids          = var.imported_subnet_security_lists["mysql"]
  prohibit_public_ip_on_vnic = true

  lifecycle { prevent_destroy = true }
}

resource "oci_core_instance" "api" {
  for_each            = var.imported_api_instances
  availability_domain = each.value.availability_domain
  fault_domain        = each.value.fault_domain
  compartment_id      = var.compartment_ocid
  shape               = each.value.shape
  display_name        = each.value.display_name

  create_vnic_details {
    display_name     = each.value.display_name
    hostname_label   = each.value.hostname_label
    subnet_id        = var.app_subnet_ocid
    assign_public_ip = true
    private_ip       = each.value.private_ip
    # Scope-A reviewed attachment (append-only): primary VNIC joins
    # eventforge-app-nsg. The live VNIC carried no NSGs before this change;
    # the subnet security list stays pinned above and keeps applying.
    nsg_ids = [oci_core_network_security_group.app.id]
  }

  source_details {
    source_type = each.value.source_type
    source_id   = each.value.source_id
  }

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [metadata, agent_config, availability_config]
  }
}

resource "oci_mysql_mysql_db_system" "existing" {
  compartment_id      = var.compartment_ocid
  display_name        = "rust-api-heatwave"
  shape_name          = "MySQL.Free"
  availability_domain = var.imported_mysql_availability_domain
  subnet_id           = var.mysql_subnet_ocid
  # DB-NSG attachment re-introduced for the MYSQL-NSG-RETEST (2026-10-29):
  # the original failure was AuthorizationFailed — the mysqldbsystem resource
  # principal lacked the NSG/VNIC-update policies the MySQL service requires
  # (blockers.md B5, b5-mysql-nsg-diagnosis.md). The corrective policies are
  # staged in infra/iam (NOT applied at the time of writing); applying this
  # declaration requires the separate GATE: MYSQL-NSG-RETEST approval record
  # and the apply gate re-verifies the live db system is ACTIVE with
  # nsg_ids=[] immediately before the one-attempt update. The db security
  # list (3306 from the app subnet) remains the governing transitional
  # control until the separate SL-CORRECTION approval.
  nsg_ids        = [oci_core_network_security_group.db.id]
  admin_username = var.mysql_admin_username
  admin_password = var.mysql_admin_password
  backup_policy {
    is_enabled        = true
    retention_in_days = 1
    window_start_time = "09:27"
    pitr_policy { is_enabled = false }
  }

  lifecycle {
    prevent_destroy = true
    # The DB-system API never returns the admin credential pair, so any config
    # value would read as drift; ignoring exactly these two write-only fields
    # is the documented import pattern (not a broad ignore).
    ignore_changes = [admin_username, admin_password]
  }
}

resource "oci_load_balancer_load_balancer" "existing" {
  compartment_id = var.compartment_ocid
  shape          = "flexible"
  shape_details {
    minimum_bandwidth_in_mbps = 10
    maximum_bandwidth_in_mbps = 10
  }
  display_name = "rust-api-public-lb"
  subnet_ids   = [var.lb_subnet_ocid]
  # Scope-A reviewed attachment (append-only): LB joins eventforge-lb-nsg.
  # Listeners remain absent here — enable_api_ingress stays false and the
  # LB security list still governs until separately corrected.
  network_security_group_ids = [oci_core_network_security_group.lb.id]

  lifecycle { prevent_destroy = true }
}
