# M1B.2 — Controlled GitHub security setup (steps 1–6) — complete

Generated: 2026-10-27T00:50:00Z · Base: PR #6 merged as `365e4c054c49ee5f7d10dd7006adf4bccdd32210` · Evidence: [environments.json](environments.json)

## Executed (operator-authorized, recorded before execution)

| M1B.2 step | Result | Gate |
| --- | --- | --- |
| 1. Merge preflight correction | PR #6 merged (environment-check jq fixes + fixture cases + CI path-filter coverage for the acceptance harness) | CI green ([CI run on PR #6](https://github.com/eswrops/EventForge/actions)) ✓ |
| 2. Pre-bootstrap preflight | 13 PASS / 0 FAIL / 8 BLOCKED (all operator prerequisites) | Zero FAIL ✓ |
| 3. Record operator approval | Recorded in [operator-checklist.md](../m1b-bootstrap/operator-checklist.md) step 3 before execution | ✓ |
| 4. Create both environments | `production-plan` (id 25412942570) and `production` (id 25412943777) via the corrected JSON-body command; each with required reviewer `eswrops` (237514587), `prevent_self_review: false`, one deployment branch policy `main` | Approved mutation ✓ |
| 5. Verify environment protections | Preflight: `gh-environment-production-plan` PASS, `gh-environment-production` PASS — exact reviewer IDs, exactly one main-only branch policy, prevent_self_review=false. The live API response confirmed the corrected expressions (the field lives in the protection rule) | Both PASS ✓ |
| 6. Protected OIDC claim inspection | Run [40428463744](https://github.com/eswrops/EventForge/actions/runs/40428463744) dispatched, **entered `waiting`** (protection boundary proven live), approved as the required reviewer via the deployment review API, completed `success`. **Actual subject: `repo:eswrops@237514587/EventForge@1434990962:environment:production-plan`** — exact match, all claims verified, REST cross-checked, sanitized output only | Actual subject matches immutable identity ✓ |

## M1B.2 success criteria — all met

Both environments exist and require the intended reviewer; only `main` can deploy; self-review
prevention is disabled for the documented single-maintainer configuration; the actual issued OIDC
subject matches the immutable numeric identity; no OCI credentials were attached; no OCI resources
were modified.

## What was deliberately not done

- **Step 7 (branch protection + Actions allowlist/pinning) awaits its separate recorded approval** —
  `main` is still unprotected and `allowed_actions=all` remains; the preflight carries both as
  BLOCKED.
- No secrets or variables in either environment (checklist step 11, after federation trusts).
- No OCI/Cloudflare/ingress changes; no apply; no imports.

## Next

With the subject confirmed live, the path is: step-7 approval → branch protection + Actions
restrictions → Vault/key decision and real bootstrap inputs (steps 7–8 of the M1B.2 sequence, 6–8
of the full checklist), then the bootstrap plan review. Trust configuration may now proceed at any
time — the claim inspection it depends on has been proven against real tokens.
