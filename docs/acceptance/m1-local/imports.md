# M1-LOCAL imports — inventory, generated configuration, execution record

Status: **Phase 2 PREPARED (2026-10-27) — Phase 3 execution STOPPED at the OCI-IMPORT
approval gate.** Nothing has been imported; `platform/terraform.tfstate` does not exist.

## 1. Live inventory reconciliation (read-only, 2026-10-27)

Executed by `scripts/local/m1-oci-inventory.sh` (16 PASS / 0 FAIL). Discovery bundle
(operator-only, full attribute capture): `/Users/eswr/secure/evidence/m1local-20261027T160117Z/oci-inventory.json`.
Every reviewed OCID from [../m1b-bootstrap/import-safety.md](../m1b-bootstrap/import-safety.md) §1
was found live and mapped one-to-one:

| Address | Live resource | State | Key attributes (from discovery, not assumed) |
| --- | --- | --- | --- |
| `oci_core_vcn.existing` | `postgresmax-vcn` | — | 10.0.0.0/16, DNS label `pgmax`, tenancy-root compartment |
| `oci_core_subnet.app` | `rust-api-test-public-subnet` | — | 10.0.2.0/24, dns `rusttest`, shared RT + test-ssh-only SL |
| `oci_core_subnet.lb` | `rust-api-lb-public-subnet` | — | 10.0.4.0/24, dns `rustlb`, shared RT + lb-public SL |
| `oci_core_subnet.mysql` | `rust-api-db-private-subnet` | — | 10.0.3.0/24, dns `rustdb`, public IPs prohibited, shared RT + database-private SL |
| `oci_core_instance.api["vm1"]` | `rust-api-test` | RUNNING | E2.1.Micro, AD-1/FD-1, 10.0.2.129, public VNIC, **no NSGs** |
| `oci_core_instance.api["vm2"]` | `rust-api-worker` | RUNNING | E2.1.Micro, AD-1/FD-2, 10.0.2.94, public VNIC, **no NSGs** |
| `oci_mysql_mysql_db_system.existing` | `rust-api-heatwave` | ACTIVE | MySQL.Free, 26.10.0, 10.0.3.18:3306, backup on (1-day retention, 09:27 window) |
| `oci_load_balancer_load_balancer.existing` | `rust-api-public-lb` | — | flexible 10–10 Mbps, LB subnet, public 129.159.239.48, **no listeners, no NSGs** |

A fourth subnet (`postgresmax-public-subnet` 10.0.1.0/24) exists in the VCN and is **out of
import scope** — untouched. Shared read-only inputs (never declared by the platform root):
one route table (`…xxcmfwa`, "Default Route Table for postgresmax-vcn") and four security
lists. Existing NSG attachments: none anywhere — nothing to preserve intact, and the initial
import attaches **no** NSGs (mission constraint); NSG attachment to VM VNICs / LB is a later,
separately reviewed existing-resource update.

Transcription control: OCIDs in the generated files were cross-checked against the discovery
bundle programmatically by `scripts/local/m1-verify-import-config.sh`. **That check caught and
fixed one real hand-transcription defect before any import ran** (pre-import security review,
2026-10-27): the app-subnet security-list OCID in `imported_resources.tf` was missing a
character (`…nmmagbgf2…` instead of the live `…nmmagbgqf2…`) — an earlier manual comparison had
missed it. All eight import-executor OCIDs were additionally verified char-for-char against the
live bundle. This is why the programmatic bundle comparison gates the approval: manual
comparison is not a control.

## 2. Generated configuration (git-ignored, completed from discovery)

- `infra/platform/imported_resources.tf` — all eight resources with `prevent_destroy`,
  pinned shared RT/SL OCIDs, NO `nsg_ids` on the instance VNICs (initial-import constraint),
  instance `ignore_changes = [metadata, agent_config, availability_config]` (template scope),
  MySQL backup policy pinned to discovered values with the narrow
  `ignore_changes = [admin_username, admin_password]` (the DB-system API never returns the
  credential pair; two write-only fields, not a broad ignore).
- `infra/platform/terraform.auto.tfvars` — discovered coordinates (OCIDs, private IPs,
  ONS topic), operator SSH /32, the 15 live-fetched Cloudflare origin IPv4 ranges
  (2026-10-27), `enable_api_ingress = false`.
- `infra/platform/variables.tf` (tracked, additive): `vcn_compartment_ocid` documenting the
  two-compartment layout (VCN/subnets in tenancy root; compute/MySQL/LB in `Test`).

`terraform validate` **PASS** (Terraform 1.12.2, offline). The configuration is import-ready;
it is NOT applied. Before any import the operator must supply the MySQL admin credential pair
(DB-system API never exposes it) via git-ignored `infra/platform/terraform.tfvars`:

```
mysql_admin_username = "<from operator vault>"
mysql_admin_password = "<from operator vault>"
```

## 3. Exact import plan (dependency order, one at a time)

Implemented by `scripts/local/m1-platform-imports.sh`, which refuses to run without
`M1_IMPORT_APPROVED_BY` and performs, per import: duplicate-address pre-check →
`terraform import` → state pull → address/OCID verification → duplicate check → snapshot.

| # | Command (`terraform -chdir=infra/platform import …`) |
| --- | --- |
| 1 | `oci_core_vcn.existing` |
| 2 | `oci_core_subnet.app` |
| 3 | `oci_core_subnet.lb` |
| 4 | `oci_core_subnet.mysql` |
| 5 | `oci_core_instance.api["vm1"]` |
| 6 | `oci_core_instance.api["vm2"]` |
| 7 | `oci_mysql_mysql_db_system.existing` |
| 8 | `oci_load_balancer_load_balancer.existing` |

Exact OCIDs live in the script (identical to the Phase 2 bundle and import-safety.md §1).
Imports write only Terraform state — no OCI resource is modified. After the eight imports the
script runs `plan -refresh-only` and FAILS CLOSED on any non-no-op drift.

## 4. Pre-import safety checks (all satisfied)

- Remote key `platform/terraform.tfstate` confirmed ABSENT (first state write will be import #1).
- No remote lock objects under any state prefix; no running terraform writers.
- Bucket private / versioning Enabled / CMK-bound, CMK ENABLED (preflight record).
- Platform backend config matches the approved coordinates exactly; no migration flags used or permitted.
- Workspace is `default` (fresh init; no workspace files exist).
- `prevent_destroy` present on all eight resources; shared RT/SLs referenced read-only.
- `enable_api_ingress = false` pinned in tfvars; no ingress resources exist in configuration paths.

## 5. Approval boundary (STOP)

**OCI-IMPORT is not yet approved.** Authorization is never granted by an environment variable
alone (pre-import security review): the operator must commit a written record at
[approvals/oci-import-approval.md](approvals/oci-import-approval.md) (template alongside it)
carrying `GATE: OCI-IMPORT`, the current commit SHA, all eight addresses, and an `APPROVER:`
line, then run:

```
M1_IMPORT_APPROVED_BY="<approver as in the record>" \
  [M1_EXTRA_VAR_FILE=/path/to/0600-vault-vars.tfvars] \
  scripts/local/m1-platform-imports.sh
```

MySQL admin credentials are loaded from a protected operator source (preferred: 0600 var file
outside the repository via `M1_EXTRA_VAR_FILE`) — never printed, never committed, never copied
into acceptance evidence. Any failed import stops the run (rule 11): preserve the log, inspect
remote state and live OCI, and decide with a fresh review — never auto-retry. Exits:
**OCI-IMPORTS = PASS** only when all eight resources are correctly mapped in the platform
remote state and the post-import refresh-only reconciliation is accepted (clean, or every
drift investigated and explicitly accepted line-by-line).

## 6. Phase 3 execution record (2026-10-27, under the OCI-IMPORT approval)

**OCI-IMPORTS = PASS.** All eight reviewed resources are correctly mapped in
`platform/terraform.tfstate` (lineage `cdda242b-92c1-4371-5b43-495f3849fc4d`, serial 8) and the
post-import refresh-only reconciliation is **clean — zero resource changes** (the only plan
deltas are the 7 known-after-apply output additions normal for fresh state). No OCI resource
was modified, created, or deleted by the imports; live VMs remain RUNNING, MySQL ACTIVE, LB
unchanged with no listeners, and no ingress resources exist.

| # | Address | Real OCI ID (verified in state) | Status |
| --- | --- | --- | --- |
| 1 | `oci_core_vcn.existing` | `ocid1.vcn.oc1.ap-hyderabad-1.amaaaaaatiosumiaz4zvhbqaopq7ljp4yq7gftrwdy2zmveizdmv62xvd6ca` | imported, ID verified |
| 2 | `oci_core_subnet.app` | `ocid1.subnet.oc1.ap-hyderabad-1.aaaaaaaawemcohc6vzzqwkv3hbq3mcpl3wf3bslzb5wmheixtitqcoqiddra` | imported, ID verified |
| 3 | `oci_core_subnet.lb` | `ocid1.subnet.oc1.ap-hyderabad-1.aaaaaaaargdyoju3emyheunr6di75z2tl74khyf7tem6hwj5x5tmxt44q2bq` | imported, ID verified |
| 4 | `oci_core_subnet.mysql` | `ocid1.subnet.oc1.ap-hyderabad-1.aaaaaaaaipwpkmvnxdzw2yduccugoq6pkojn7lpd3izpewyusyvi7ywp7ewa` | imported, ID verified |
| 5 | `oci_core_instance.api["vm1"]` | `ocid1.instance.oc1.ap-hyderabad-1.anuhsljrtiosumiceyilvbiclo7kynsdnzozmoeziwmsjdrhdwigvw5ibc4a` | imported, ID verified |
| 6 | `oci_core_instance.api["vm2"]` | `ocid1.instance.oc1.ap-hyderabad-1.anuhsljrtiosumicl5kpn6r7suoqgn4osm6pu3r7rrszwib3yuaeb65x7ooa` | imported, ID verified |
| 7 | `oci_mysql_mysql_db_system.existing` | `ocid1.mysqldbsystem.oc1.ap-hyderabad-1.aaaaaaaaes3clz2baohp34kuulobnhrp3cnz33bicso6r4syj7npztnvj2gq` | imported, ID verified |
| 8 | `oci_load_balancer_load_balancer.existing` | `ocid1.loadbalancer.oc1.ap-hyderabad-1.aaaaaaaa4by2dj7zniovxz327ieyws33wcsxfu2rcu6dasnuk5f6yljmihvq` | imported, ID verified |

Evidence: `/Users/eswr/secure/evidence/m1local-20261027T171413Z/` (per-import logs, per-import
state snapshots in `state/platform-post-imports-history/`, post-import refresh plan+JSON) and
the independent verification run `/Users/eswr/secure/evidence/m1local-20261027T172009Z/`
(13 PASS / 0 FAIL). Execution was partially resumed once: run
`m1local-20261027T171131Z` imported the VCN, then stopped on a verifier bug (not an import
failure); runs `…171322Z` (subnets + vm1) and `…171413Z` (vm2, MySQL, LB) completed the list.
The resume path only ever accepted an already-present address after verifying its recorded
state ID against the reviewed OCID — no double imports, no unverified skips.

**Execution-discovered script defects, fixed and re-verified offline (guards + harness 12/12):**

1. The import verifier matched `.address` against raw state JSON, which has no top-level
   address field (that is a `terraform show -json` concept). Fixed by rebuilding the address
   from `type`/`name`/instance `index_key` (map keys quoted).
2. `grep -cx` treated `api["vm1"]` as a regex character class; fixed with `grep -cFx`
   (fixed-string, whole-line).
3. The reconciliation drift extractor iterated `.resource_changes[]`, which Terraform 1.12
   OMITS when a plan has zero resource changes — a fully clean plan printed a jq error and
   passed vacuously. Fixed with `(.resource_changes // [])[]` in both the import script and
   `m1-verify.sh`, making the clean result a real empty set (independently confirmed: the
   refresh plan's `prior_state` holds all 8 resources, `resource_changes` empty).

**MySQL credential caveat (operator action recommended):** the vault secret
`rust-api-heatwave-admin` (root compartment) holds a 27-character value used as the
`mysql_admin_password` in the 0600 operator var file; the admin username is not recorded
anywhere retrievable (the DB-system API never returns the pair), so the var file carries the
documented placeholder `operator-vault-heatwave-admin`. Both fields are write-only and
permanently `ignore_changes`-ed — Terraform never sends them to OCI after import, so the
placeholders cannot affect the database. The operator should record the real username and
refresh the password in the vault at their convenience; if `ignore_changes` is ever widened
away, that vault update must happen first.

**Next gate (separate approval):** PLATFORM-APPLY per
[platform-plan.md](platform-plan.md) — requires the operator's Cloudflare inputs
(`cloudflare_account_id`, `cloudflare_zone_id`, `root_domain`,
`TF_VAR_cloudflare_api_token`), plan generation, review, and the written
`approvals/platform-apply-approval.md` naming the plan SHA-256.
