# Import safety audit

Status: **AUDITED, NOT EXECUTED.** No import was run (hard constraint). This audit compares the
Terraform mappings with the live inventory captured in
[`docs/acceptance/m1b/import-reconciliation.json`](../m1b/import-reconciliation.json) during M1B.

## 1. Mapping audit — every OCID verified against the live resource

| Terraform address | Live resource | OCID (from M1B capture) | Audit |
| --- | --- | --- | --- |
| `oci_core_vcn.existing` | `postgresmax-vcn` 10.0.0.0/16 | `ocid1.vcn.oc1.ap-hyderabad-1.amaaaaaatiosumiaz4zvhbqaopq7ljp4yq7gftrwdy2zmveizdmv62xvd6ca` | ✅ one-to-one |
| `oci_core_subnet.app` | `rust-api-test-public-subnet` 10.0.2.0/24 | `ocid1.subnet.oc1.ap-hyderabad-1.aaaaaaaawemcohc6vzzqwkv3hbq3mcpl3wf3bslzb5wmheixtitqcoqiddra` | ✅ |
| `oci_core_subnet.lb` | `rust-api-lb-public-subnet` 10.0.4.0/24 | `ocid1.subnet.oc1.ap-hyderabad-1.aaaaaaaargdyoju3emyheunr6di75z2tl74khyf7tem6hwj5x5tmxt44q2bq` | ✅ |
| `oci_core_subnet.mysql` | `rust-api-db-private-subnet` 10.0.3.0/24 | `ocid1.subnet.oc1.ap-hyderabad-1.aaaaaaaaipwpkmvnxdzw2yduccugoq6pkojn7lpd3izpewyusyvi7ywp7ewa` | ✅ |
| `oci_core_instance.api["vm1"]` | `rust-api-test` 10.0.2.129 | `ocid1.instance.oc1.ap-hyderabad-1.anuhsljrtiosumiceyilvbiclo7kynsdnzozmoeziwmsjdrhdwigvw5ibc4a` | ✅ |
| `oci_core_instance.api["vm2"]` | `rust-api-worker` 10.0.2.94 | `ocid1.instance.oc1.ap-hyderabad-1.anuhsljrtiosumicl5kpn6r7suoqgn4osm6pu3r7rrszwib3yuaeb65x7ooa` | ✅ |
| `oci_mysql_mysql_db_system.existing` | `rust-api-heatwave` MySQL.Free @10.0.3.18:3306 | `ocid1.mysqldbsystem.oc1.ap-hyderabad-1.aaaaaaaaes3clz2baohp34kuulobnhrp3cnz33bicso6r4syj7npztnvj2gq` | ✅ |
| `oci_load_balancer_load_balancer.existing` | `rust-api-public-lb` flexible 10–10, 129.159.239.48 | `ocid1.loadbalancer.oc1.ap-hyderabad-1.aaaaaaaa4by2dj7zniovxz327ieyws33wcsxfu2rcu6dasnuk5f6yljmihvq` | ✅ |

Each remote resource maps to **exactly one** Terraform address; no address is duplicated across
roots (bootstrap owns no network/compute resources; frontend owns only Cloudflare resources).

## 2. Managed vs read-only classification

| Component | Classification | Protection |
| --- | --- | --- |
| VCN, 3 subnets | Will become **managed** (import flow only) via the commented skeletons in `imported_resources.tf.example` | `prevent_destroy = true` in each skeleton; shared route/security references pinned to discovered OCIDs |
| The 2 instances | Managed (template, complete) | `prevent_destroy`, `ignore_changes = [metadata, agent_config, availability_config]`, existing NSG ids preserved and appended |
| MySQL DB system | Will become managed | `prevent_destroy` skeleton |
| Load balancer | Will become managed | `prevent_destroy` skeleton |
| **Route table** (`...lxwsn3othszsg4e6tyovwg4z4nnn62zuoph4fzdaso3w4xxcmfwa`) | **Read-only input** — referenced only as `var.*_subnet_ocid` data, never declared | Preflight check `shared-network-unmanaged` FAILs if any `oci_core_route_table` resource is ever declared |
| **Security lists** (lb-public / database-private / test-ssh-only) | **Read-only** — this root adds NSGs only | Same preflight check; safe-plan policy denies deletes |
| Internet gateway | Read-only (implicit via route table) | Untouched |
| NSGs + NSG rules | Managed **new** resources (additive) | Safe-plan allow-list: create only |

## 3. Compartment layout

The VCN/subnets live in the **tenancy root compartment** while instances/MySQL/LB live in the
`Test` compartment. The platform root handles this correctly: NSGs are created in
`var.compartment_ocid` and network OCIDs are passed as inputs. When the skeletons are uncommented,
`var.vcn_compartment_ocid` (root) must be added and used for VCN/subnets while
`var.compartment_ocid` (Test) stays for the rest — the skeleton comments mark exactly this.

## 4. Import execution checklist (per resource, gated by approval)

```bash
cd infra/platform   # after backend init + fresh state backup (state-recovery.md §2)
terraform import oci_core_vcn.existing <vcn_ocid>
terraform import 'oci_core_subnet.app' <app_subnet_ocid>
terraform import 'oci_core_subnet.lb' <lb_subnet_ocid>
terraform import 'oci_core_subnet.mysql' <mysql_subnet_ocid>
terraform import 'oci_core_instance.api["vm1"]' <vm1_ocid>
terraform import 'oci_core_instance.api["vm2"]' <vm2_ocid>
terraform import oci_mysql_mysql_db_system.existing <mysql_ocid>
terraform import oci_load_balancer_load_balancer.existing <lb_ocid>
# Then, before ANY normal plan:
terraform plan -refresh-only            # investigate every non-no-op before proceeding
terraform plan -out=production.tfplan && terraform show -json production.tfplan > production-plan.json
scripts/ci/assert-safe-plan.sh --policy scripts/ci/platform-safe-plan-policy.json production-plan.json
```

Order matters: VCN first, then subnets, then instances/MySQL/LB (they reference subnet ids). If a
refresh-only plan shows an unexpected change, **stop** — correct the configuration to match
reality; never "fix" reality to match configuration.

## 5. Rollback

Imports change only Terraform state, never OCI resources. Rollback = restore the pre-import state
backup (§2 of state-recovery.md) via `terraform state push` on the **local/scratch** copy used for
recovery — for the remote backend, copy the prior state-object version back per
state-recovery.md §6. A failed import is simply re-run with the corrected address/OCID.
