# Importing the existing OCI estate

Before importing, save OCI resource-discovery output and the current VCN security-list rules in the operator evidence record. This repository adds NSGs and never writes shared subnet security lists. Generated resource configuration is reviewed operator input: keep `imported_resources.tf` ignored and do not commit live OCIDs, private addresses, or discovered configuration.

Populate the ignored platform `terraform.auto.tfvars` with discovered values. Copy the import template, complete it from OCI discovery output, retain `prevent_destroy`, and review its VNIC/NSG configuration before importing these resources:

| Existing resource | Terraform address |
| --- | --- |
| VCN | `oci_core_vcn.existing` |
| Application subnet | `oci_core_subnet.app` |
| Load-balancer subnet | `oci_core_subnet.lb` |
| MySQL subnet | `oci_core_subnet.mysql` |
| VM 1 / VM 2 | `oci_core_instance.api["vm1"]` / `oci_core_instance.api["vm2"]` |
| MySQL DB system | `oci_mysql_mysql_db_system.existing` |
| Public load balancer | `oci_load_balancer_load_balancer.existing` |

Use `terraform import` with the exact OCID. After every import run `terraform plan -refresh-only`; resolve drift explicitly. Before the first normal plan:

1. Run the protected **Production Terraform plan** workflow from `main` using the `production-plan` environment.
2. Save its non-sensitive address/action summary with the inventory record. It must match `scripts/ci/platform-safe-plan-policy.json` and contain no deletion, replacement, or unapproved imported-resource update.
3. Add a narrowly scoped policy entry only after reviewing an intentional imported-resource update. The `allow_import_update` field is required for such updates. Certificate rotation is a separate deliberate change and requires an explicit `allow_delete` policy entry; never broadly permit deletes.
4. Keep `enable_api_ingress = false` for this first apply. It may create NSGs, monitoring, and other reviewed additive resources, but it cannot create the public API certificate, listener, backends, DNS record, or cache rule.

After the validation API is deployed and both hosts return `/readyz`, confirm Cloudflare Full (strict) with the shared-zone owner, set `enable_api_ingress = true`, review a new plan, and apply only through the protected `production` workflow. For Origin CA rotation, bump `origin_certificate_generation`; the unique OCI certificate name and create-before-destroy lifecycle prevent a same-name collision.

