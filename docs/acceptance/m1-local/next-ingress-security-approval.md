# Next-ingress security approval package (ingress-gate preparation)

Status: **PREPARED 2026-10-28 — read-only mission; NO change has been applied or authorized.**
This document is the reviewed change-package for the future network-security gate. It
identifies exact resources, current vs desired rules, impacts, sequencing, rollback and
verification — so that the operator can authorize **scope A** (network-rule / NSG-association
changes) and **scope B** (public API listener, certificate, backends, DNS) as two separate
approvals, in that order.

> **HARD PROHIBITION (carried forward from the M1-LOCAL acceptance):** no API-ingress
> activation — no listener, no certificate, no backend set, no public API DNS, no
> `enable_api_ingress=true`, no security-list update, no NSG attachment — until BOTH
> scope A and scope B have separate written approvals AND the full effective network
> policy produced by this package has been re-verified as the actual post-change state.

## 0. Effective-rule semantics this package relies on

OCI evaluates the **union** of a VNIC's subnet security-list rules and its NSG rules:
if a VNIC belongs to an NSG, traffic is permitted when *either* the security list *or* the
NSG allows it. Therefore **attaching an NSG can only ADD permissions — it can never remove
the legacy `0.0.0.0/0` rules** documented below. Cloudflare-only origin restriction requires
the legacy security-list rules to be **removed or narrowed**, which is a separate,
individually reviewed change (scope A).

## 1. Exact existing resources to update

All live-verified read-only 2026-10-28 (OCI CLI, operator workstation) and re-confirmed by
`scripts/local/m1-verify.sh` (18 PASS / 0 FAIL):

| # | Resource | OCID (suffix) | Terraform address | Current NSG membership |
| --- | --- | --- | --- | --- |
| 1 | Security list `rust-api-lb-public` | `…elahefjk6ddczauhmu4tznf6pocrtkb7h26ihs2i4nlafoibdsya` | *not managed by the platform root* | n/a (SL) |
| 2 | Security list `rust-api-test-ssh-only` | `…irrc6gzsc5emsx6hhvajcd6nmmagbgqf2qy5zvb77dqrfo63sm3q` | *not managed by the platform root* | n/a (SL) |
| 3 | Security list `rust-api-database-private` | `…aaaaaaaarwcfapns7orc6hvovfrt2md3xhko443sp5vz324b5c7pwiu7apoa` | *not managed by the platform root* | n/a (SL) |
| 4 | VM `rust-api-test` primary VNIC (public 129.225.99.202) | `…abuhsljr2ug2zn4z3wopw56irscxau7fhzzd7nahjhhrda2vsx7tuaxss4xq` | `oci_core_instance.api["vm1"]` | **none** (live: `nsg_ids = []`) |
| 5 | VM `rust-api-worker` primary VNIC (public 129.225.99.0) | `…abuhsljrnhjfp477j6e242dl555vmyude7vesuotzg325xkne64t46utmehq` | `oci_core_instance.api["vm2"]` | **none** (live: `nsg_ids = []`) |
| 6 | LB `rust-api-public-lb` (public 129.159.239.48, **zero listeners**) | `…aaaaaaaa4by2dj7zniovxz327ieyws33wcsxfu2rcu6dasnuk5f6yljmihvq` | `oci_load_balancer_load_balancer.existing` | **none** (live: `network_security_group_ids = []`) |
| 7 | MySQL `rust-api-heatwave` (ACTIVE, private 10.0.3.18) | `…aaaaaaaaes3clz2baohp34kuulobnhrp3cnz33bicso6r4syj7npztnvj2gq` | `oci_mysql_mysql_db_system.existing` | **none** (live: `nsg_ids = null`) |

Target NSGs (all AVAILABLE, created by the approved platform apply, currently attached to
nothing — all 19 rules verified present): `eventforge-lb-nsg`, `eventforge-app-nsg`,
`eventforge-db-nsg` (`oci_core_network_security_group.{lb,app,db}` in
`infra/platform/network.tf`).

## 2. Current effective rule union (exact, live 2026-10-28)

### Security-list rules (subnet-wide, legacy — not Terraform-managed)

| Security list | Attached subnet | Ingress | Egress |
| --- | --- | --- | --- |
| `rust-api-lb-public` | `rust-api-lb-public-subnet` 10.0.4.0/24 (LB only) | TCP **80 from 0.0.0.0/0**; TCP **443 from 0.0.0.0/0** | all protocols → 0.0.0.0/0 |
| `rust-api-test-ssh-only` | `rust-api-test-public-subnet` 10.0.2.0/24 (VM1 + VM2) | TCP **22 only from 49.207.205.137/32** (description "SSH for rust-api-test") | all protocols → 0.0.0.0/0 |
| `rust-api-database-private` | `rust-api-db-private-subnet` 10.0.3.0/24 (MySQL only) | TCP **1522 from 10.0.2.0/24**; TCP **3306 from 10.0.2.0/24** | all protocols → 0.0.0.0/0 |

Not part of the platform union: `Default Security List for postgresmax-vcn` is attached to
**no** subnet in the VCN (each of the four subnets names exactly one SL — verified live);
`postgresmax-public-subnet` (10.0.1.0/24) and its own SL are out of import/platform scope.

### NSG rules (19, exact — `infra/platform/network.tf`, verified live)

| NSG | Rules |
| --- | --- |
| `eventforge-lb-nsg` | INGRESS TCP 443 from each of the **15 reviewed Cloudflare origin IPv4 CIDRs** (173.245.48.0/20, 103.21.244.0/22, 103.22.200.0/22, 103.31.4.0/22, 141.101.64.0/18, 108.162.192.0/18, 190.93.240.0/20, 188.114.96.0/20, 197.234.240.0/22, 198.41.128.0/17, 162.158.0.0/15, 104.16.0.0/13, 104.24.0.0/14, 172.64.0.0/13, 131.0.72.0/22 — fetched live 2026-10-27, pinned in git-ignored `terraform.auto.tfvars`) |
| `eventforge-app-nsg` | INGRESS TCP 8080 from NSG `eventforge-lb-nsg`; INGRESS TCP 22 from reviewed operator /32 `49.207.214.221/32` |
| `eventforge-db-nsg` | INGRESS TCP 3306 from NSG `eventforge-app-nsg` |
| (paired egress) | `eventforge-app-nsg` EGRESS TCP 3306 to NSG `eventforge-db-nsg` |

### Current effective posture (union of the above, since no NSG is attached)

- LB: TCP 80 + 443 **from anywhere** — mitigated only by the LB having **zero listeners**
  (verified live 2026-10-28); nothing is served.
- VM1/VM2: TCP 22 from `49.207.205.137/32` only; nothing else (no 8080 rule exists anywhere
  for the app subnet).
- MySQL: TCP 1522 + 3306 from the app subnet 10.0.2.0/24 only; private subnet, no public IP.
- Egress: unrestricted everywhere; single route `0.0.0.0/0 → Internet Gateway`.

## 3. Findings to correct (scope A justification)

| # | Finding | Severity | Detail |
| --- | --- | --- | --- |
| F1 | **Legacy LB-subnet SL permits TCP 80/443 from `0.0.0.0/0`** | High at the ingress gate | NSG attachment alone does **not** restrict this (§0 union semantics). Once a 443 listener exists, the SL rules make the origin publicly reachable at the LB IP 129.159.239.48 regardless of the Cloudflare-only NSG. The SL rules must be removed/narrowed in the same scope-A change. |
| F2 | **Stale operator SSH /32** | Medium | The live app-SL rule pins `49.207.205.137/32` (old address); the reviewed input pins `49.207.214.221/32`. SSH from the current address is likely blocked today. The app NSG already pins the reviewed /32, so NSG attachment restores SSH — but the SL rule must then be updated/removed to avoid permanently depending on the union. |
| F3 | **App→MySQL SL rule is subnet-wide** | Low | `rust-api-database-private` admits 3306 from the whole app subnet 10.0.2.0/24, while the intended policy is app-NSG↔db-NSG. Keep during scope A; narrowing is a later optional hardening (removing it makes the app NSG rules the only 3306 path — do not remove until the NSG path is proven). |
| F4 | **Port 1522 legacy rule** | Low | The db SL admits 1522 (a PostgreSQL-era port, unused by MySQL). Review for removal at scope A; no db-NSG rule covers 1522, so removing the SL rule removes the flow. |
| F5 | **Egress is unrestricted on every SL** | Note | Out of scope for the origin-restriction gate; recorded for completeness. |

**Shared resources relying on current rules:** `rust-api-test-ssh-only` is shared by VM1 and
VM2 — any change to it affects both. The three platform SLs are each attached to exactly one
subnet, and no other resource lives in those subnets; the out-of-scope
`postgresmax-public-subnet` is unaffected. None of the three SLs is Terraform-managed by the
platform root (pinned read-only in `imported_resources.tf`), so SL corrections are
out-of-band OCI operations (or a separately reviewed import-scope extension) — they will not
appear in a Terraform plan.

## 4. Desired end state (Cloudflare-only origin access)

1. LB subnet SL: **no** TCP 80/443 ingress from 0.0.0.0/0 (rules removed; if any SL ingress
   is kept, it must be the 15 Cloudflare CIDRs on 443 — redundant with the NSG but harmless).
2. App subnet SL: SSH rule updated to the reviewed `49.207.214.221/32` (or removed once the
   app-NSG SSH rule is proven); still no 8080 rule anywhere.
3. DB subnet SL: 3306 from 10.0.2.0/24 retained (fallback) or narrowed after the NSG pair is
   proven; 1522 removed (decision recorded at approval time).
4. NSG memberships: VM1 + VM2 primary VNICs → `eventforge-app-nsg`; LB → `eventforge-lb-nsg`;
   MySQL → `eventforge-db-nsg`.
5. Effective origin access: 443 only from the 15 Cloudflare ranges (LB IP), 8080 only
   LB-NSG→app-NSG, 22 only the reviewed /32, 3306 only app-NSG↔db-NSG.

## 5. Safe sequencing (scope A) — avoid SSH / DB interruption

| Step | Action | Type | Why ordered here |
| --- | --- | --- | --- |
| 0 | Prove/restore SSH from the current operator address (update app-SL SSH rule to `49.207.214.221/32`, or plan to rely on step 1's NSG and verify immediately after) | SL update (out-of-band) | Never leave a state where both the SL rule is stale and the NSG is unattached. |
| 1 | Attach NSGs: add `eventforge-app-nsg` to both VNICs, `eventforge-lb-nsg` to the LB, `eventforge-db-nsg` to MySQL | Terraform in-place updates (scope A) | Purely additive — union semantics mean no existing flow can break; SSH gains the reviewed /32, MySQL gains the app-NSG path, LB gains Cloudflare-only 443. |
| 2 | Verify: SSH to both VMs from the current /32; app→MySQL connection (existing flow, must be unchanged); `oci lb` shows NSG attached | read-only | Gate for step 3. |
| 3 | Remove/narrow legacy SL rules: LB SL 80+443 from 0.0.0.0/0; app SL old /32; (optional) db SL 1522 | SL update (out-of-band) | Only after NSG flows are proven — from here the NSGs are the sole source of the removed permissions. |
| 4 | Re-verify source filtering (§7) and record the post-change effective policy in `security.md` | read-only | The union after removals IS the final policy; it must be re-inspected, not assumed. |

Stop conditions (abort scope A, roll back per §6): SSH to either VM fails after step 1;
app→MySQL fails at any point; any Terraform plan proposing replacement/destruction rather
than in-place update; NSG/rule drift from the 19-rule reviewed set.

## 6. Rollback plan (preserves remote access)

- **Step-1 rollback**: remove the `nsg_ids` entries (re-run the prior Terraform code/pin) —
  in-place updates again; SL rules untouched throughout, so the pre-change posture returns
  exactly. SSH is preserved at every point because SL rules are never removed before the NSG
  path is verified live (§5 step 2 gates step 3).
- **Step-3 rollback**: re-add the removed SL rules from this document's §2 table (exact
  source/port tuples are recorded above); re-attach nothing.
- **DB protection**: if app→MySQL breaks after any step, first re-add the db-SL 3306 rule
  from 10.0.2.0/24 (that is the flow MySQL depends on today), then investigate the NSG pair.
- MySQL admin credentials are write-only and `ignore_changes`-ed; none of these steps touch
  them. `prevent_destroy` on all eight imported resources blocks any destructive plan.

## 7. Verification of source filtering after scope A

1. `oci network nsg list-network-security-group-vnics` for each NSG shows exactly the
   intended members (2 VNICs / 1 LB / 1 DB system).
2. From a non-Cloudflare host: TCP connect to 129.159.239.48:443 and :80 must **time out**
   (after the scope-B listener exists; before that, verify the SL rules are gone by
   `oci network security-list get`).
3. Through Cloudflare (scope B): `https://api.<root-domain>` answers (origin reachability
   proves the Cloudflare-CIDR path).
4. SSH from the reviewed /32 succeeds to both VMs; from any other address it must fail.
5. App→MySQL: application health check / MySQL client from both VMs succeeds.
6. Record the full post-change rule union in `security.md` (same table format as §2).

## 8. Scope B — public API listener, certificate, backends, DNS (separate approval)

Planned resources (all currently absent; `enable_api_ingress=false` gates them in the root):

- Terraform: LB listener 443 (TLS, Cloudflare **Origin CA** certificate + key as secret
  material), backend set → VM1 + VM2 port 8080, health check path, path-based routing as
  needed; `cloudflare_dns_record.api` (proxied A → 129.159.239.48),
  `cloudflare_ruleset.api_no_cache` (`infra/platform/cloudflare.tf`).
- Cloudflare: Origin CA certificate generation (needs real `cloudflare_account_id`,
  `cloudflare_zone_id`, `root_domain`, API token — B4 operator inputs), proxied DNS record,
  no-cache ruleset.
- Scope B requires scope A **already applied and verified** (an origin that admits 0.0.0.0/0
  must not receive a public listener). If scope B is approved without scope A being complete,
  the LB IP becomes publicly reachable API surface — explicitly prohibited.

## 9. Exact expected Terraform plan actions (scope A)

Clean-checkout plan on current `main` (commit `ae25230`) is verified a no-op
(`changes=0`, serial 10). The approved scope-A change must show **exactly**:

```
~ oci_core_instance.api["vm1"]                          update (in-place)   nsg_ids += eventforge-app-nsg
~ oci_core_instance.api["vm2"]                          update (in-place)   nsg_ids += eventforge-app-nsg
~ oci_load_balancer_load_balancer.existing              update (in-place)   network_security_group_ids += eventforge-lb-nsg
~ oci_mysql_mysql_db_system.existing                    update (in-place)   nsg_ids += eventforge-db-nsg
Plan: 0 to add, 0 to destroy, 4 to change
```

No replacement, no destroy (`prevent_destroy` + safe-plan policy enforce), no change to any
of the other 33 addresses, no new resources, no SL/route changes in the plan (SLs are
unmanaged; §5 step 0/3 are out-of-band). The safe-plan policy
(`scripts/ci/platform-safe-plan-policy.json`) and `scripts/ci/assert-safe-plan.sh` must pass
on the saved plan before any apply approval is written.

## 10. Monitoring and readiness prerequisites (before scope A execution)

1. **ONS subscription ACTIVE** — currently **PENDING** (verified live 2026-10-28,
   `eswr.ops@gmail.com` on topic `eventforge-operations`): operator clicks the OCI
   confirmation email (sent 2026-10-27T06:07Z) or resends via
   `oci ons subscription resend-confirmation`, then re-verifies `lifecycle-state = ACTIVE`.
   Until then alarm delivery is not proven ([blockers.md](blockers.md) B3).
2. Alarms `eventforge-compute-cpu-high` + `eventforge-unhealthy-backends` enabled (verified
   PASS 2026-10-28) and budget `eventforge-monthly` (amount 5, three alert rules) live.
3. Plan + apply executed from a clean checkout of the reviewed commit with the SHA-bound
   written approval (template `approvals/platform-apply-approval.template`) naming the
   saved-plan SHA-256 — the same gate discipline as M1-LOCAL.
4. Scope B additionally: Origin CA certificate generated and stored in the operator vault,
   operator Cloudflare inputs supplied, DNS hostname chosen, rollback listener plan ready.

## 11. Approval records required (separate mutation scopes)

| Scope | Mutations covered | Record required |
| --- | --- | --- |
| **A** | The four NSG-association updates (§9) **plus** the out-of-band SL corrections (§5 steps 0/3) | New written approval in `approvals/` (extend the gate vocabulary with e.g. `NSG-ATTACH-SL-FIX`) naming the plan SHA-256 and the exact SL rule changes |
| **B** | LB listener/certificate/backends, Cloudflare DNS/ruleset, `enable_api_ingress=true` | Separate later approval; only after scope A is applied AND its §7 verification recorded |

A single combined approval is explicitly **not** permitted: these are different mutation
scopes with different blast radii.
