# M1-LOCAL security verification

Status: **EFFECTIVE network security inspected live 2026-10-28 — post-Scope-A state; re-verified
read-only 2026-10-28 (m1-verify 18/0, serial 12, drift clean, SSH + MySQL re-proven)**
(the Scope-A NSG associations + security-list corrections were applied and verified under
written approvals; see [scope-a-network-execution-approval.md](scope-a-network-execution-approval.md)
§Execution record and §7 of that package for the pre-change union).
`scripts/local/m1-verify.sh` is the repeatable verification gate; it fails closed (a failed
OCI listing is never treated as absence) and checks each item below.

## Effective network security — post-Scope-A associations and permitted traffic

| Component | NSG membership (live 2026-10-28) | Governing security list | Effective ingress |
| --- | --- | --- | --- |
| VM1 `rust-api-test` (10.0.2.129, public 129.225.99.202) | `eventforge-app-nsg` (verified live) | `rust-api-test-ssh-only` (app subnet) | **UNION**: TCP 22 from `49.207.214.221/32` (SL, corrected from the stale `49.207.205.137/32`) ∪ TCP 22 from the reviewed /32 (app NSG) ∪ TCP 8080 from `eventforge-lb-nsg` (app NSG). **Nothing else** — 8080 only from the (listener-less) LB NSG. |
| VM2 `rust-api-worker` (10.0.2.94, public 129.225.99.0) | `eventforge-app-nsg` (verified live) | `rust-api-test-ssh-only` (app subnet) | same as VM1 |
| LB `rust-api-public-lb` (public 129.159.239.48) | `eventforge-lb-nsg` (verified live) | `rust-api-lb-public` (lb subnet) — **ingress now `[]`** (both 0.0.0.0/0 80/443 rules removed) | **UNION**: TCP 443 ONLY from the 15 reviewed Cloudflare origin ranges (LB NSG). The legacy unrestricted 80/443 rules are GONE. LB still has **zero listeners**, so nothing is served. |
| MySQL `rust-api-heatwave` (10.0.3.18, port 3306) | **none** — `nsg_ids = []` (db-NSG attachment **BLOCKED — missing IAM resource-principal policies**, re-diagnosed 2026-10-28 from the failed work requests; the earlier "service-level limitation" claim is retracted — [blockers.md](blockers.md) B5, [b5-mysql-nsg-diagnosis.md](b5-mysql-nsg-diagnosis.md)) | `rust-api-database-private` (db subnet) | TCP **3306** from `10.0.2.0/24` (app subnet) — retained as the explicit transitional control; **1522 rule REMOVED** (legacy PostgreSQL-era port). Private subnet, no public IP. |

Route table (shared by all three subnets): single static rule `0.0.0.0/0 → Internet Gateway`
(egress unrestricted; app NSG additionally narrows nothing — union semantics keep the SL's
all-egress rule in force).

### Verified live post-change (2026-10-28, evidence m1local-scopea-exec-20261027T193848Z)

- Both VM VNICs: exactly 1 attachment each, `nsg_ids = [eventforge-app-nsg]` — no secondary
  VNIC was created.
- LB: `network_security_group_ids = [eventforge-lb-nsg]`, listeners `[]`.
- Security lists: app SL SSH source `49.207.214.221/32`; LB SL ingress `[]` (hash
  `37517e5f…`); db SL single 3306 rule (hash `57027896…`); app SL hash `75441a3a…`.
- **Real authenticated SSH** from the approved /32 to BOTH VMs succeeds (via SL and NSG).
- **MySQL service greeting** (`26.10.0-cloud` on 3306) received from BOTH VMs — app→MySQL
  path intact after every change (full authenticated login still requires the admin
  username, which only the operator vault's owner holds — recorded caveat in imports.md §6).
- Source filtering from a non-Cloudflare vantage: TCP 80 and 443 to 129.159.239.48 refused
  (SL rule removed; note: with no listener this is corroborating, not conclusive — the
  conclusive filter test repeats at scope B when a listener exists).
- `m1-verify.sh` **18 PASS / 0 FAIL** post-apply and post-SL-corrections; state lineage
  `cdda242b-92c1-4371-5b43-495f3849fc4d` unchanged (serial 12 after the apply); drift clean.

### Remaining exposures / notes

- **MySQL DB-NSG gap (B5)**: the intended app-NSG↔db-NSG pairing is half-built — the app NSG
  carries the 3306 egress rule to the db NSG, but the db system cannot join the db NSG.
  **Root cause (re-diagnosed 2026-10-28): missing `mysqldbsystem` resource-principal IAM
  policies** (`AuthorizationFailed` in both failed UPDATE_DBSYSTEM work requests), not a
  service limitation. The db SL's subnet-wide 3306 rule remains the operative control;
  tightening it requires B5 resolution first ([b5-mysql-nsg-diagnosis.md](b5-mysql-nsg-diagnosis.md)).
- **SSH**: SL-level SSH now equals the reviewed /32; the legacy `.137` rule is gone.
  SSH from other addresses was not tested from a second vantage (single-VPS test recommended
  at next opportunity).
- **LB → application**: still blocked (no listener; and 8080 only permitted LB-NSG→app-NSG,
  which is now attached on both sides).
- **Egress**: unrestricted (SL) — unchanged.

## Verified controls (read-only, unchanged from the pre-apply record)

| Control | Evidence |
| --- | --- |
| No public API/DB exposure | Live NSG + security-list listing: no 0.0.0.0/0 rule on 8080/3306 anywhere; LB zero listeners; MySQL private-only. |
| Existing VMs safe | Both VMs RUNNING; public IPs unchanged. (Historic pre-Scope-A wording said "no NSG/VNIC/SL mutation by any M1-LOCAL step" — **superseded**: Scope A's approved apply DID mutate the two primary VNICs (`create_vnic_details.nsg_ids`), the LB NSG membership, and three security lists; those were the reviewed Scope-A changes, verified in [scope-a-network-execution-approval.md](scope-a-network-execution-approval.md) §14. No other VNIC/SL mutation occurred — no secondary VNICs, no state drift (serial 12, lineage unchanged).) |
| MySQL safe | `rust-api-heatwave` ACTIVE on 10.0.3.18; admin credentials never printed or committed (write-only narrow `ignore_changes`; operator vault). |
| State safety | Bucket `NoPublicAccess`, versioning Enabled, CMK-bound and ENABLED; no lock objects; plans/state mode 0600 in 0700 evidence dirs outside the repository. |
| Least-privilege executor | Local API-key `DEFAULT` profile only; Resource/Instance Principal environments refused. GitHub WIF clients/trust untouched and dormant. |
| Credentials hygiene | Preflight rejects tracked `*.pem`/state/backend.hcl/tfvars/imported.auto.tfvars and embedded private-key material. |

## Not authorized by this track

API ingress enablement, public API DNS, Origin CA generation, NSG attachment to existing VM
VNICs, the LB, or MySQL, route-table/security-list changes, GitHub WIF IAM policies — each
is a separate reviewed change outside M1-LOCAL.

## Serial-console (break-glass) access review — 2026-10-28, read-only

Scope A step A0 created two OCI instance-console connections (out-of-band recovery
path, independent of SL/NSG state). Inventory verified live 2026-10-28:

| Connection | Instance | Status | Public-key fingerprint (SHA256) |
| --- | --- | --- | --- |
| `ocid1.instanceconsoleconnection.oc1.ap-hyderabad-1.anuhsljrtiosumicuchw6ewb64jflhbtrpxlfpzyqivytxb75vw4qk2u2nmq` | VM1 `rust-api-test` (`…vw5ibc4a`) | **ACTIVE** | `SHA256:heYKOT0b00idJoOp5WCX8kEjMDo9Who9U0bF3GZzDiE` |
| `ocid1.instanceconsoleconnection.oc1.ap-hyderabad-1.anuhsljrtiosumiceyvy22z36xjw3a2nzqiwhjpsvnztoj4i7uxchm4kcuea` | VM2 `rust-api-worker` (`…b65x7ooa`) | **ACTIVE** | `SHA256:heYKOT0b00idJoOp5WCX8kEjMDo9Who9U0bF3GZzDiE` (same RSA-4096 keypair) |

- **Key material**: one dedicated RSA-4096 keypair (`console_recovery_rsa4096`), private
  key mode `0600` inside a `0700` protected evidence directory outside the repository
  (`/Users/eswr/secure/evidence/m1local-scopea-exec-20261027T193848Z/console/`); never
  committed (preflight rejects tracked key material). ed25519 keys are refused by the
  console-connection API — RSA was a service requirement, not a choice.
- **Operational ownership**: the operator workstation only (the same single operator
  identity that holds the `Administrators` group membership); no other principal can list
  or use these connections beyond what tenancy policy grants.
- **Intentionality**: yes — A0 was the approved independent recovery path and its stop
  condition (§7 of the Scope-A package) depended on it. Permanent break-glass access is
  **intentional and currently justified**: SSH to the VMs is locked to a single operator
  /32 at both the SL and NSG layers, so the serial console is the only access path that
  survives an operator-IP change.
- **Retention recommendation**: KEEP both connections while the network posture allows
  exactly one SSH source. If the operator IP rotates and a new /32 is approved, or if a
  second independent SSH path is established, re-review and delete the connections then
  (each deletion is a separate operator-approved action; no connection is deleted by this
  review). The private key's loss would not widen network access (console access also
  requires tenancy-admin IAM), but the keypair should be rotated if the evidence directory
  is ever exposed.
