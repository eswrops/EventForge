# M1-LOCAL security verification

Status: **PRE-APPLY posture verified live 2026-10-27; post-apply verification pending
PLATFORM-APPLY.** `scripts/local/m1-verify.sh` is the repeatable verification gate; it fails
closed (a failed OCI listing is never treated as absence) and checks each item below.

## Verified now (read-only)

| Control | Evidence |
| --- | --- |
| No public API/DB exposure | Live NSG listing: only the four pre-existing shared security lists exist; **no NSGs and no 0.0.0.0/0 rules on 8080/3306 anywhere**. Load balancer has zero listeners (nothing is published on 443); API port 8080 is reachable only inside the VCN; MySQL 3306 only from the private DB subnet (`prohibit_public_ip_on_vnic = true`). |
| Existing VMs safe | Both VMs RUNNING, public VNICs unchanged, no NSG or VNIC mutation performed by any M1-LOCAL step (imports are state-only). |
| MySQL safe | `rust-api-heatwave` ACTIVE on 10.0.3.18 in the private subnet; admin credentials never printed or committed (write-only narrow `ignore_changes`; operator vault). |
| State safety | Bucket `NoPublicAccess`, versioning Enabled, CMK-bound and ENABLED; 30-day noncurrent-version lifecycle; no lock objects; every plan/state artifact in mode-0700 evidence dirs outside the repository; plans mode 0600. |
| Least-privilege executor | Local API-key `DEFAULT` profile only; Resource/Instance Principal environments refused by the guard library. GitHub WIF clients/trust untouched and dormant (all infra workflows `workflow_dispatch`-only, verified by offline test). |
| Credentials hygiene | Preflight rejects tracked `*.pem`/state/backend.hcl/tfvars files and embedded private-key material; MySQL admin pair lives only in git-ignored tfvars. |

## Applied after PLATFORM-APPLY (planned creates only)

- `eventforge-{lb,app,db}-nsg`: HTTPS 443 **only** from the 15 reviewed Cloudflare origin
  ranges; 8080 **only** LB-NSG→app-NSG; SSH 22 **only** from the operator /32; 3306
  **only** app-NSG↔db-NSG. The verify gate fails the run on any public 8080/3306 rule or any
  unexpected listener.
- Alarms and budget alerts → ONS topic `eventforge-operations` / operator email.

## Not authorized by this track

API ingress enablement, public API DNS, Origin CA generation, NSG attachment to existing VM
VNICs or the LB, route-table/security-list changes, GitHub WIF IAM policies — each is a
separate reviewed change outside M1-LOCAL.
