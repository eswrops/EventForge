GATE: OCI-IMPORT
APPROVER: Koka Easwarendra <easwarendra.ece@gmail.com>
DATE: 2026-10-27
COMMIT: 974c9b5c0de632c6e605a65dcc485f5ddff99aa2

Reviewed artifacts:
- docs/acceptance/m1-local/imports.md (inventory reconciliation 16/0, generated configuration,
  pre-import security review record including the caught-and-fixed security-list OCID defect)
- infra/platform/imported_resources.tf (validated; prevent_destroy on all eight; no NSG
  attachments; narrow ignore_changes only)
- infra/platform/terraform.auto.tfvars (discovered coordinates, enable_api_ingress = false)
- /Users/eswr/secure/evidence/m1local-20261027T160117Z/oci-inventory.json (live discovery bundle)
- scripts/local/m1-verify-import-config.sh result: 34 PASS / 0 FAIL against the live bundle;
  all 8 import-executor OCIDs verified char-for-char

Approved import list (all eight, in this order):
- oci_core_vcn.existing
- oci_core_subnet.app
- oci_core_subnet.lb
- oci_core_subnet.mysql
- oci_core_instance.api["vm1"]
- oci_core_instance.api["vm2"]
- oci_mysql_mysql_db_system.existing
- oci_load_balancer_load_balancer.existing

Statement: I have reviewed the eight-address import list and the generated configuration
against the live OCI discovery evidence and approve importing these addresses into
platform/terraform.tfstate on this commit. Imports change only Terraform state. Any failure
stops without retry.

Operator grant: "approved" (2026-10-27, in the M1-LOCAL deployment session).
