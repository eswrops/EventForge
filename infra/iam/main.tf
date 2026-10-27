# Corrective IAM policies for MySQL DB-system NSG attachment (blockers.md B5).
#
# Root cause (diagnosed 2026-10-28 from the FAILED UPDATE_DBSYSTEM work
# requests): the MySQL service's `mysqldbsystem` resource principal had NO
# authorization to update the DB-system endpoint VNIC / NSG membership — both
# work requests failed with `AuthorizationFailed`. This is exactly the gap
# Oracle documents as mandatory for NSG updates (mysql-database/doc/
# mandatory-policies-permissions.html, "For Network Security Groups").
#
# The statements below are the minimum Oracle-documented permissions, each
# doubly constrained:
#   - subject: any-user BUT where request.principal.type='mysqldbsystem'
#   - origin:  where request.resource.compartment.id = <Test compartment>
#              (only DB systems living in the Test compartment qualify —
#              this tenancy has exactly one, rust-api-heatwave)
#   - target:  scoped to the exact compartment owning the target resource
#              (NSGs in Test; VNICs in the tenancy root).
#
# Deliberately NOT granted: manage all-resources, tenancy-wide network
# administration, IAM administration, access to other DB systems or Object
# Storage. The GitHub Stage-2 workload policies stay disabled.
#
# A dedicated dynamic group was considered and rejected: Oracle documents the
# any-user + conditions form verbatim for this exact scenario, while the
# dynamic-group form's matching-rule attributes for mysqldbsystem principals
# are not documented; the conditions below are equally binding.

# Statement 1 of 2 — NSG compartment (Test): let the DB-system resource
# principal update the membership of the eventforge-db-nsg group.
resource "oci_identity_policy" "mysql_nsg_membership" {
  provider = oci

  name        = "eventforge-mysql-nsg-membership"
  description = "B5 recovery: allow mysqldbsystem resource principals of DB systems in the Test compartment to update NSG memberships of NSGs in the Test compartment (Oracle mandatory policy for DB-system NSG updates)."

  compartment_id = var.db_compartment_ocid

  statements = [
    "Allow any-user to {NETWORK_SECURITY_GROUP_UPDATE_MEMBERS} in compartment id ${var.db_compartment_ocid} where all {request.principal.type='mysqldbsystem', request.resource.compartment.id='${var.db_compartment_ocid}'}",
  ]
}

# Statement 2 of 2 — subnet compartment (tenancy root): let the DB-system
# resource principal update its own endpoint VNIC to associate/disassociate
# NSGs. Attached at the tenancy because the MySQL subnet (rust-api-db-private-
# subnet) and its VNIC live in the root compartment; the statement itself is
# scoped to root-compartment resources only.
resource "oci_identity_policy" "mysql_vnic_update" {
  provider = oci

  name        = "eventforge-mysql-vnic-update"
  description = "B5 recovery: allow mysqldbsystem resource principals of DB systems in the Test compartment to update VNICs (NSG association) in the tenancy root compartment, where the MySQL db subnet lives (Oracle mandatory policy for DB-system NSG updates)."

  compartment_id = var.tenancy_ocid

  statements = [
    "Allow any-user to {VNIC_CREATE, VNIC_UPDATE, VNIC_ASSOCIATE_NETWORK_SECURITY_GROUP, VNIC_DISASSOCIATE_NETWORK_SECURITY_GROUP} in compartment id ${var.tenancy_ocid} where all {request.principal.type='mysqldbsystem', request.resource.compartment.id='${var.db_compartment_ocid}'}",
  ]
}
