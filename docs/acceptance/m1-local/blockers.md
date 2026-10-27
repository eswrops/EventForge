# M1-LOCAL blockers and deferred items

## Active blockers

| # | Blocker | Impact | Path forward |
| --- | --- | --- | --- |
| B1 | ~~OCI-IMPORT approval~~ **RESOLVED 2026-10-27** — imports executed under the written approval record; 8/8 verified, reconciliation clean | — | [imports.md](imports.md) §6 |
| B2 | ~~PLATFORM-APPLY approval~~ **RESOLVED 2026-10-27** — two SHA-bound apply rounds completed the 29-create set (budget compartment fix documented); live verification 18/0 | — | [platform-plan.md](platform-plan.md) §6 |
| B3 | **ONS email subscription PENDING** (verified live 2026-10-27: `eswr.ops@gmail.com` on topic `eventforge-operations`, ACTIVE topic) | Alarm notifications cannot be marked delivered; alarm delivery is not PASS until the confirmation email is clicked and verified | Operator clicks the confirmation email (sent 2026-10-27T06:07Z); re-verify subscription lifecycle-state = ACTIVE |
| B4 | ~~Operator inputs for planning~~ **OBSOLETE** — the gated apply required no Cloudflare API access (`enable_api_ingress=false`; zero Cloudflare resources). Real account_id/zone_id/root_domain/token become mandatory only for the future ingress-enablement gate | Deferred to ingress enablement | operator supplies at that gate |

## Deferred (unchanged from full M1 — do not mark PASS here)

| Item | Status | Owner of the gate |
| --- | --- | --- |
| OCI-FEDERATION (JWT→RPST exchange) | **DEFERRED** — Oracle SR required to enable workload-identity exchange on the DEFAULT domain (ap-hyderabad-1); clients `eventforge-github-plan`/`-apply` + trust `eventforge-github` remain CREATED and untouched | [../m1-final/workload-federation.md](../m1-final/workload-federation.md) §0 |
| GitHub Stage-2 IAM policies | **DEFERRED** — behind the first successful live exchange + recorded claim mapping | federation §3; `enable_workload_policies=false` |
| IAM-DENIAL probe | **NOT_RUN** — requires an underprivileged principal; refuses `DEFAULT` by design | federation §5 |
| GitHub-dependent release installer as production path | **PREPARED, not local-tested** — local release installation is a separate later mechanism; application deployment is NOT claimed by M1-LOCAL | [../m1-final/release-operations.md](../m1-final/release-operations.md) |
| NSG attachment to existing VM VNICs / LB | Not part of the additive plan; separate reviewed existing-resource update when API ingress is actually enabled | future gate |
| M2 | **NOT_STARTED** (rule 16) | — |

## Historical evidence preserved

The retained disposable validation keys (`validation/live-acceptance-20261027T120000Z-m1live/`,
`…-20261027T130000Z-m1live-r2/`, `validation/restore-test-…/`) and their cleanup-approval
boundary are untouched (separately approved operation, [../m1-final/README.md](../m1-final/README.md)).
