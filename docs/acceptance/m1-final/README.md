# M1 final acceptance

Working directory for the M1 completion mission (GitHub security → OCI bootstrap → remote
state → federation → imports → additive platform → final report). Status as of 2026-10-27,
commit `1d0c7e6` (PR #13).

## Files

| File | Content |
| --- | --- |
| [baseline.md](baseline.md) | Phase 0 reconciled starting state (lockdown re-verified live, OCI inventory pristine) |
| [release-operations.md](release-operations.md) | Phase 8 evidence — exit gate **RELEASE-OPERATIONS = PREPARED** |
| remaining Phase 9 files | written as their phases execute (architecture, github-security, oci-bootstrap, workload-federation, remote-state, imports, network-security, monitoring, cost-and-free-tier, acceptance-checklist, blockers, m1-final-report.json) |

## Gate status

| Gate | Status |
| --- | --- |
| GH-SECURITY (Phase 1) | **PASS** — lockdown applied under operator approval and independently re-verified live: 4 required contexts strict+admin-enforced, linear history, 0 approvals (deliberate solo-maintainer config), strict SHA-pinned allowlist, read-only workflow tokens, both environments protected, OIDC inspection re-run PASS (run 40453021102), docs-only PR merge path proven (PRs #10/#11), direct push to main rejected by the protected-branch hook |
| BOOTSTRAP-PLAN (Phase 2) | **BLOCKED** on operator checklist step 7 (state CMK) — everything else prepared: Stage-1/2 split merged (PR #12), checksum-verified Terraform 1.12.2 at `~/tools/terraform/1.12.2`, operator tfvars prepared (one pending input), preflight 19 PASS / 0 unexpected FAIL |
| OCI-BOOTSTRAP (Phase 3) | BLOCKED — first apply needs its own approval (step 9) |
| OCI-REMOTE-STATE (Phase 4) | BLOCKED — needs the bootstrap buckets |
| OCI-FEDERATION (Phase 5) | BLOCKED — needs trusts/clients (steps 10–11); `production` subject not yet inspected in its environment |
| OCI-IMPORTS (Phase 6) | BLOCKED — needs remote state |
| M1C-PLATFORM (Phase 7) | BLOCKED — needs imports |
| RELEASE-OPERATIONS (Phase 8) | **PREPARED** — 12-scenario offline dry-run suite, 5 real installer defects found and fixed (PR #13) |
| M1 final report (Phase 9) | pending |

## Next operator action (checklist step 7)

Approve creation of the dedicated state CMK, then the plan/apply sequence of
[../m1b-bootstrap/operator-checklist.md](../m1b-bootstrap/operator-checklist.md) steps 8–9.
