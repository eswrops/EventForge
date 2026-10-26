# Infrastructure acceptance evidence

`scripts/acceptance/run.sh` is an offline acceptance harness for this repository. It checks static Terraform and workflow safety, local fixture tests, shell syntax, provider locks, secret indicators, disabled ingress, and required documentation. It never runs `terraform apply`, contacts OCI or Cloudflare, reads operator tfvars, or deploys the Rust application.

Run it from a clean checkout when possible:

```bash
scripts/acceptance/run.sh --report /secure/evidence/eventforge-m1a-acceptance.json
```

The JSON report records every check as `PASS`, `FAIL`, or `NOT_RUN`. `NOT_RUN` means its prerequisite was unavailable (for example Terraform is not installed); it is evidence of an unperformed check, never a pass. The command exits non-zero only for `FAIL`, so reviewers must inspect `NOT_RUN` entries before accepting evidence.

Static acceptance is not production readiness. Follow [the live validation runbook](live-validation-runbook.md) with an approved operator and attach its redacted evidence to the change record. Keep `enable_api_ingress = false` throughout M1A.
