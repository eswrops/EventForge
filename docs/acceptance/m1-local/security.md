# M1-LOCAL security verification

Status: **EFFECTIVE network security inspected live 2026-10-29 — post-B5-hardening
state; re-verified read-only 2026-10-29 (m1-verify 19/0, platform serial 14, drift
clean, refreshing plan = zero changes —
[post-b5-reproducibility-audit.md](post-b5-reproducibility-audit.md))**
(the Scope-A NSG associations + security-list corrections were applied and verified under
written approvals 2026-10-28; see [scope-a-network-execution-approval.md](scope-a-network-execution-approval.md)
§Execution record and §7 of that package for the pre-change union; the B5 DB-NSG
attachment, SSH-source refresh, transitional-SL-rule removal, and diagnostics-policy
removal were executed and verified 2026-10-28 — [b5-execution-record.md](b5-execution-record.md)).
`scripts/local/m1-verify.sh` is the repeatable verification gate; it fails closed (a failed
OCI listing is never treated as absence) and checks each item below.

## Effective network security — post-B5-hardening associations and permitted traffic

| Component | NSG membership (live 2026-10-29) | Governing security list | Effective ingress |
| --- | --- | --- | --- |
| VM1 `rust-api-test` (10.0.2.129, public 129.225.99.202) | `eventforge-app-nsg` (verified live) | `rust-api-test-ssh-only` (app subnet) | **UNION**: TCP 22 from `49.207.216.108/32` (app SL and app NSG — both controls refreshed to the same approved /32 on 2026-10-29; SL history: `.137`→`.221`→`.108`) ∪ TCP 8080 from `eventforge-lb-nsg` (app NSG). **Nothing else** — 8080 only from the (listener-less) LB NSG. |
| VM2 `rust-api-worker` (10.0.2.94, public 129.225.99.0) | `eventforge-app-nsg` (verified live) | `rust-api-test-ssh-only` (app subnet) | same as VM1 |
| LB `rust-api-public-lb` (public 129.159.239.48) | `eventforge-lb-nsg` (verified live) | `rust-api-lb-public` (lb subnet) — **ingress `[]`** | **UNION**: TCP 443 ONLY from the 15 reviewed Cloudflare origin ranges (LB NSG). The legacy unrestricted 80/443 rules are GONE. LB still has **zero listeners**, so nothing is served. |
| MySQL `rust-api-heatwave` (10.0.3.18, port 3306) | **`eventforge-db-nsg`** — DB-NSG attachment **RESOLVED** 2026-10-28T22:26Z (B5; state serial 13→14 matches live) | `rust-api-database-private` (db subnet) — **ingress `[]`** (the transitional `10.0.2.0/24 → 3306` rule was REMOVED 2026-10-28T23:23Z after both-VM proof; the 1522 legacy-port rule was removed earlier) | TCP **3306 ONLY from `eventforge-app-nsg`** (app-NSG↔db-NSG pairing) — the sole remaining MySQL path, live-proven from BOTH VMs post-removal. Private subnet, no public IP. |

Route table (shared by all three subnets): single static rule `0.0.0.0/0 → Internet Gateway`
(egress unrestricted; app NSG additionally narrows nothing — union semantics keep the SL's
all-egress rule in force).

### Verified live post-change — Scope-A execution record (2026-10-28, evidence m1local-scopea-exec-20261027T193848Z — HISTORICAL; superseded by the 2026-10-29 section above for SSH source, db SL, and MySQL NSG state)

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

### Verified live post-B5 hardening + read-only audit (2026-10-29)

- **B5 RESOLVED and hardened**: `rust-api-heatwave` ACTIVE with
  `nsg_ids = [eventforge-db-nsg]`; the transitional `10.0.2.0/24 → 3306`
  security-list rule REMOVED (2026-10-28T23:23Z) after the pinned diagnostic
  passed on BOTH VMs pre-removal (23:22:38/39Z) — and the immediate
  post-removal test passed on BOTH VMs (23:23:49/51Z, TCP-3306 CONNECT OK +
  greeting + exit 0). The app-NSG↔db-NSG pairing is the **sole live-proven
  MySQL path**; db SL ingress is `[]`.
- **SSH source /32-restricted on BOTH controls**: app SL and app NSG both pin
  `49.207.216.108/32`, port 22 only; two-VM SSH acceptance PASS (guest user
  `ubuntu`).
- **Diagnostics IAM policy REMOVED** (PR #53 + one gated destroy; IAM state
  `2d169472…` serial 3 = exactly the two MySQL policies).
- Platform state `cdda242b…` serial 14, lineage unchanged; `m1-verify.sh`
  **19 PASS / 0 FAIL**, drift clean.
- **Reproducibility (2026-10-29 audit)**: normal refreshing plan with pinned
  Terraform 1.12.2 = zero changes, zero drift, `applyable=false`;
  `operator_ssh_cidr = 49.207.216.108/32` matches the approved live source.
  SSH apply-gate deviation corrected: future SSH rotations require
  `GATE: SSH-SOURCE-UPDATE` with apply-time plan/live recheck +
  regression tests ([post-b5-reproducibility-audit.md](post-b5-reproducibility-audit.md)).

### Remaining exposures / notes

- **MySQL exposure (closed)**: effective exposure is EXACTLY
  app-NSG → db-NSG on 3306 (B5 RESOLVED 2026-10-28; transitional SL rule
  removed; the earlier B5 blocker text and the 2026-10-28 "remaining
  exposures" B5 bullet below are superseded — see
  [b5-execution-record.md](b5-execution-record.md) Addendum 3 and
  [blockers.md](blockers.md)).
- **SSH**: SL-level and NSG-level SSH now equal the same reviewed /32
  (`49.207.216.108/32`); the legacy `.137` and intermediate `.221` sources
  are gone from both controls. SSH from other addresses was not tested from a
  second vantage (single-VPS test recommended at next opportunity).
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
