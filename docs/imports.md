# Importing the existing OCI estate

Before importing, save the output of OCI resource discovery and export the current VCN security-list rules. This repository adds NSGs and never writes shared subnet security lists.

Populate the platform `terraform.auto.tfvars` file with the existing OCIDs and private addresses. Create configuration first, then import these resources into the addresses documented below:

| Existing resource | Terraform address |
| --- | --- |
| VCN | `oci_core_vcn.existing` |
| Application subnet | `oci_core_subnet.app` |
| Load-balancer subnet | `oci_core_subnet.lb` |
| MySQL subnet | `oci_core_subnet.mysql` |
| VM 1 / VM 2 | `oci_core_instance.api["vm1"]` / `oci_core_instance.api["vm2"]` |
| MySQL DB system | `oci_mysql_mysql_db_system.existing` |
| Public load balancer | `oci_load_balancer_load_balancer.existing` |

Use `terraform import` with the exact OCID. After every import run `terraform plan -refresh-only`; resolve drift explicitly. The first normal plan is acceptable only when it contains the new NSGs, NSG attachments, backend set/listener/certificate, buckets, monitoring, and Cloudflare configuration. Stop on any destroy or replacement of an imported resource.

