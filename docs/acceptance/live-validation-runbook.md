# Operator-approved live validation runbook

This runbook is intentionally manual. Run only from protected `main` workflows or an approved short-lived operator session. Do not run `terraform apply` as part of these steps, do not upload state/plan artifacts, and keep `enable_api_ingress = false`.

1. Capture OCI inventory and the existing VCN/security-list configuration; store redacted identifiers with the change record.
2. Capture current Terraform state using the OCI-native backend and a read-only evidence location. Do not copy state into CI artifacts.
3. Verify GitHub OIDC claim restrictions for issuer, audience, repository, environment subject, and approved `main` ref. Prove the plan and apply identities use different trust/client boundaries.
4. Run the protected RPST exchange and record only exit status, expiry window, and key-file permissions. Never record JWTs, RPSTs, client secrets, or private keys.
5. Run the protected OCI backend validation workflow with the approval package's concrete RUN_ID; the scripts confine all writes to `validation/live-acceptance-<RUN_ID>/` and `validation/restore-test-<RUN_ID>/`, pin Terraform 1.12.2 via `TERRAFORM_BIN`, and fail closed on any deviation (see `m1-final/live-backend-validation-approval.md`). Record remote read/write, lock acquisition, rejected contention, and release. The IAM-denial probe (`scripts/ci/verify-oci-backend-denied.sh`) runs only in the federation phase with an explicitly underprivileged principal — never with the privileged operator profile; record the redacted authorization denial there.
6. With the plan identity, demonstrate that a mutation is denied; preserve only the redacted denial metadata.
7. From an instance principal, demonstrate backup-bucket access and Terraform-state-bucket denial.
8. Reconcile imports with `terraform plan -refresh-only`; investigate drift before any normal plan.
9. Generate a fresh production plan from `main` using the plan identity.
10. Apply `assert-safe-plan.sh` with the committed production policy. Record the redacted address/action summary and any reviewed exception separately.
11. Attach the offline JSON report and all redacted live evidence to the approval record. Production readiness remains unclaimed until these live checks are reviewed.

Certificate-only maintenance is a separate approved change: use a new `origin_certificate_generation`, validate the new listener certificate, and add only a narrow, time-bounded reviewed policy exception. The committed default policy continues to deny certificate replacement and all unreviewed deletes.
