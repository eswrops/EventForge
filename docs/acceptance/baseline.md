# M1A baseline record

The acceptance-harness baseline was captured from commit `8e6e371` (`first commit`) on 2026-10-27. The working tree already contained the production-readiness foundation edits when this record was made; they have been preserved rather than reset or recreated.

Terraform roots: `infra/bootstrap`, `infra/platform`, and `infra/frontend`. Each declares Terraform `>= 1.12.0, < 2.0.0` and has a committed provider lock file. The production roots use distinct Object Storage state keys: `bootstrap/terraform.tfstate`, `platform/terraform.tfstate`, and `frontend/terraform.tfstate`.

Workflows inventoried: `terraform.yml` (PR validation), `terraform-plan.yml`, `terraform-apply.yml`, `oci-backend-validation.yml`, `oci-preflight.yml`, `frontend.yml`, and `release.yml`. No live workflow, plan, apply, ingress, OCI, or Cloudflare operation was run during baseline capture.

Local validation status is recorded in the generated acceptance JSON rather than this static record. A missing local Terraform binary is reported as `NOT_RUN`, never as a pass.
