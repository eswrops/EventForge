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
#   - target:  scoped to the compartment owning the target resource
#              (NSGs in Test; VNICs in the tenancy root).
#              NOTE on effective scope (verified against Oracle's policy
#              inheritance documentation, 2026-10-28): a location clause
#              naming a compartment covers that compartment AND all its
#              descendants. Statement 1 (Test) therefore covers NSGs in Test
#              and any future Test children; statement 2 (root) is EFFECTIVELY
#              TENANCY-WIDE — there is no documented policy-language form that
#              scopes a grant to the root compartment only. The where-clause
#              constraints above are the binding limits: only mysqldbsystem
#              principals of Test-compartment DB systems can use either grant.
#              See b5-mysql-nsg-diagnosis.md §8; MYSQL-NSG-IAM approval is
#              BLOCKED until the operator explicitly acknowledges this scope.
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

  lifecycle {
    prevent_destroy = true
  }
}

# Statement 2 of 2 — subnet compartment (tenancy root): let the DB-system
# resource principal update its own endpoint VNIC to associate/disassociate
# NSGs. Attached at the tenancy because the MySQL subnet (rust-api-db-private-
# subnet) and its VNIC live in the root compartment; a child-attached policy
# cannot grant access to parent-compartment resources. Via policy inheritance
# the location clause effectively covers root + ALL descendant compartments
# (no root-only form exists in the documented policy language) — the
# where-clause, not the location, is what limits the principals.
resource "oci_identity_policy" "mysql_vnic_update" {
  provider = oci

  name        = "eventforge-mysql-vnic-update"
  description = "B5 recovery: allow mysqldbsystem resource principals of DB systems in the Test compartment to update VNICs (NSG association) in the tenancy root compartment, where the MySQL db subnet lives (Oracle mandatory policy for DB-system NSG updates)."

  compartment_id = var.tenancy_ocid

  statements = [
    "Allow any-user to {VNIC_CREATE, VNIC_UPDATE, VNIC_ASSOCIATE_NETWORK_SECURITY_GROUP, VNIC_DISASSOCIATE_NETWORK_SECURITY_GROUP} in compartment id ${var.tenancy_ocid} where all {request.principal.type='mysqldbsystem', request.resource.compartment.id='${var.db_compartment_ocid}'}",
  ]

  lifecycle {
    prevent_destroy = true
  }
}

# Connectivity-diagnostics policy (prepared 2026-10-28, NOT applied; PR kept
# unmerged until the operator chooses this diagnostic approach). Lets the two
# existing instances (dynamic group `eventforge-instances`, whose matching
# rule is exactly the two instance OCIDs) receive Compute Run Command
# diagnostics so VM→MySQL connectivity can be re-verified without widening
# any SSH source. Deliberate least privilege per the reviewed mission:
#   - verb `use` on instance-agent-command-execution-family = READ-only (the
#     arbitrary-code-execution trigger, INSTANCE_AGENT_COMMAND_EXECUTION_
#     CREATE, exists only at `manage`, which stays with the operator);
#   - compartment is the Test compartment, never the tenancy;
#   - the request/target condition pins each instance to its own commands.
#   EXECUTION-TIME RISKS (fail-closed, verify on the first approved command):
#   (1) Oracle's documented dynamic-group form uses `manage` on this family;
#       with `use` the agent may poll but be unable to report results — if the
#       command is created but never polled/completed, STOP and prepare a
#       re-reviewed package; never broaden in place.
#   (2) `target.instance.id` population for this family is not documented;
#       per the target.compartment.id finding (b5-mysql-nsg-diagnosis.md §9)
#       an unpopulated target variable evaluates the condition false and
#       DENIES — the same re-reviewed-package path applies.
resource "oci_identity_policy" "instance_run_command_diagnostics" {
  provider = oci

  name        = "eventforge-instance-run-command-diagnostics"
  description = "B5 connectivity diagnostics: let the two existing instances (dynamic group eventforge-instances) poll Compute Run Command diagnostics in the Test compartment, read-only, each instance restricted to its own commands."

  compartment_id = var.db_compartment_ocid

  statements = [
    "Allow dynamic-group eventforge-instances to use instance-agent-command-execution-family in compartment id ${var.db_compartment_ocid} where request.instance.id=target.instance.id",
  ]

  lifecycle {
    prevent_destroy = true
  }
}
