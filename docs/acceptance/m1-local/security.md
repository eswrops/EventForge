# M1-LOCAL security verification

Status: **EFFECTIVE network security inspected live 2026-10-27 (post-apply, read-only).**
`scripts/local/m1-verify.sh` is the repeatable verification gate; it fails closed (a failed
OCI listing is never treated as absence) and checks each item below.

## Effective network security — current associations and permitted traffic

The three platform-created NSGs (`eventforge-{lb,app,db}-nsg`, 19 rules) exist but are
**attached to nothing**. Every existing component's traffic is therefore governed solely by
its subnet security list and its own attachment state, verified live per component:

| Component | NSG membership | Governing security list | Effective ingress |
| --- | --- | --- | --- |
| VM1 `rust-api-test` (10.0.2.129, public 129.225.99.202) | **none** (0 NSGs) | `rust-api-test-ssh-only` (app subnet) | TCP 22 **only** from `49.207.205.137/32`; **nothing else** — 8080 is NOT reachable from anywhere |
| VM2 `rust-api-worker` (10.0.2.94, public 129.225.99.0) | **none** (0 NSGs) | `rust-api-test-ssh-only` (app subnet) | same as VM1 |
| LB `rust-api-public-lb` (public 129.159.239.48) | **none** (0 NSGs) | `rust-api-lb-public` (lb subnet) | TCP 80/443 from `0.0.0.0/0` — but the LB has **zero listeners**, so nothing is served |
| MySQL `rust-api-heatwave` (10.0.3.18, port 3306) | **none** (0 NSGs) | `rust-api-database-private` (db subnet) | TCP 1522/3306 **only** from `10.0.2.0/24` (app subnet); private subnet, no public IP |

Route table (shared by all three subnets): single static rule `0.0.0.0/0 → Internet Gateway`
(egress allowed from all components; no egress restriction anywhere).

### Answers to the specific exposure questions

- **Public ingress to 8080**: NOT possible. The app security list has no 8080 rule at all
  (only TCP 22 from a single /32), and no NSG is attached to either VNIC.
- **Public ingress to 3306**: NOT possible. MySQL sits in the private subnet
  (`prohibit_public_ip_on_vnic = true`, private IP 10.0.3.18 only) and the db security list
  admits 3306 only from `10.0.2.0/24`.
- **SSH to port 22**: allowed only from `49.207.205.137/32` per the live app security list.
  Note: the reviewed operator input pins `operator_ssh_cidr = 49.207.214.221/32` — the
  operator's current address has changed since the pre-existing security list was written.
  This is a pre-existing live rule, not touched by M1-LOCAL; SSH access from the current
  address is likely blocked until the operator updates the rule (or uses a jump path). The
  created-but-unattached app NSG already pins the reviewed /32.
- **LB → application**: BLOCKED today. The LB has no listeners, and the app security list
  admits no traffic from the LB subnet (`10.0.4.0/24`) on any port.
- **Application → MySQL**: WORKS. The db security list admits `10.0.2.0/24` (the app subnet)
  to 3306.
- **Egress**: unrestricted (all-protocol `0.0.0.0/0` egress on every security list, IGW
  route).

## NSG attachment status and the required operations

The created NSGs are the **intended final** per-tier policy (443 only from the 15 reviewed
Cloudflare origin ranges; 8080 only LB-NSG→app-NSG; 22 only the reviewed operator /32; 3306
only app-NSG↔db-NSG). Attaching them is **not required for M1-LOCAL security acceptance** —
the effective posture above is already closed to public API/DB traffic — and is deliberately
**not applied** by this mission.

The attachment becomes necessary only at the future ingress-enablement gate (an LB listener
needs the app backends to accept 8080, and 443 needs Cloudflare-origin restriction). That
gate requires a separately reviewed NSG-ATTACHMENT change; the required OCI operations are:

1. Update each `oci_core_instance.api["vm1"/"vm2"]`: add `eventforge-app-nsg` to the primary
   VNIC `nsg_ids` (existing-resource update; no replacement; VNIC keeps its public IP).
2. Update `oci_load_balancer_load_balancer.existing`: add `eventforge-lb-nsg` to
   `network_security_group_ids` (in-place update).
3. Update `oci_mysql_mysql_db_system.existing`: set `nsg_ids = [eventforge-db-nsg]`
   (in-place db-system update).
4. Only then: LB listener/backends/certificate + DNS (the `enable_api_ingress` gate).

Connectivity impact of that future change: VMs gain 8080 from the LB NSG and SSH from the
reviewed /32 (current effective SSH source stays whatever the app security list pins — the
union of security-list and NSG rules applies); MySQL gains 3306 from the app NSG; the LB
gains 443 from Cloudflare ranges. No existing allow-rule is removed, so no current flow can
break. All three `eventforge-*` NSGs and their 19 rules must be preserved verbatim by that
update (safe-plan `protected_imports`/allowlist and the verify gate enforce it).

## Verified controls (read-only, unchanged from the pre-apply record)

| Control | Evidence |
| --- | --- |
| No public API/DB exposure | Live NSG + security-list listing: no 0.0.0.0/0 rule on 8080/3306 anywhere; LB zero listeners; MySQL private-only. |
| Existing VMs safe | Both VMs RUNNING; public VNICs unchanged; no NSG/VNIC/SL mutation performed by any M1-LOCAL step (imports are state-only; applies created only NSG/alarm/budget objects). |
| MySQL safe | `rust-api-heatwave` ACTIVE on 10.0.3.18; admin credentials never printed or committed (write-only narrow `ignore_changes`; operator vault). |
| State safety | Bucket `NoPublicAccess`, versioning Enabled, CMK-bound and ENABLED; no lock objects; plans/state mode 0600 in 0700 evidence dirs outside the repository. |
| Least-privilege executor | Local API-key `DEFAULT` profile only; Resource/Instance Principal environments refused. GitHub WIF clients/trust untouched and dormant. |
| Credentials hygiene | Preflight rejects tracked `*.pem`/state/backend.hcl/tfvars/imported.auto.tfvars and embedded private-key material. |

## Not authorized by this track

API ingress enablement, public API DNS, Origin CA generation, NSG attachment to existing VM
VNICs, the LB, or MySQL, route-table/security-list changes, GitHub WIF IAM policies — each
is a separate reviewed change outside M1-LOCAL.
