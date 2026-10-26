#!/usr/bin/env bash
# Offline infrastructure acceptance harness. It never calls terraform apply,
# contacts OCI/Cloudflare, or reads operator secrets.
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
report_path="${repo_root}/acceptance-report.json"
if [[ $# -eq 2 && "$1" == "--report" ]]; then
  report_path="$2"
elif [[ $# -ne 0 ]]; then
  echo "usage: $0 [--report <path>]" >&2
  exit 64
fi

mkdir -p "$(dirname "$report_path")"
checks_file="$(mktemp)"
trap 'rm -f "$checks_file"' EXIT
failures=0

record() {
  local name="$1" status="$2" detail="$3"
  jq -cn --arg name "$name" --arg status "$status" --arg detail "$detail" \
    '{name:$name,status:$status,detail:$detail}' >> "$checks_file"
  [[ "$status" != "FAIL" ]] || failures=$((failures + 1))
}

pass() { record "$1" PASS "$2"; }
fail() { record "$1" FAIL "$2"; }
not_run() { record "$1" NOT_RUN "$2"; }

run() {
  local name="$1" detail="$2"
  shift 2
  if "$@" >/dev/null 2>&1; then pass "$name" "$detail"; else fail "$name" "$detail"; fi
}

cd "$repo_root" || exit 1
run "shell-syntax" "bash parses CI, acceptance, operational, and fixture scripts" \
  bash -n scripts/ci/*.sh scripts/acceptance/*.sh scripts/oci-free-tier-preflight.sh ops/scripts/* tests/ci/*.sh tests/acceptance/*.sh

if command -v shellcheck >/dev/null; then
  run "shell-lint" "ShellCheck found no diagnostics" \
    shellcheck -S warning scripts/ci/*.sh scripts/acceptance/*.sh scripts/oci-free-tier-preflight.sh ops/scripts/* tests/ci/*.sh tests/acceptance/*.sh
else
  not_run "shell-lint" "shellcheck is not installed"
fi

if command -v actionlint >/dev/null; then
  run "workflow-lint" "actionlint accepted all GitHub workflows" actionlint
else
  not_run "workflow-lint" "actionlint is not installed"
fi

run "wif-fixtures" "valid and rejected OIDC/RPST exchange fixtures passed" tests/ci/test-configure-oci-wif.sh
run "safe-plan-fixtures" "safe-plan allow/deny fixtures passed" tests/ci/test-safe-plan.sh

# shellcheck disable=SC2016 # The command is deliberately evaluated by bash -c.
run "terraform-version-and-locks" "all roots require Terraform >= 1.12 and have locked providers" \
  bash -c '
    for root in infra/bootstrap infra/platform infra/frontend; do
      test -s "$root/.terraform.lock.hcl"
      rg -q "required_version = \">= 1\\.12\\.0" "$root/versions.tf"
      rg -q "provider \\\"registry\\.terraform\\.io/" "$root/.terraform.lock.hcl"
    done
  '

# shellcheck disable=SC2016 # The command is deliberately evaluated by bash -c.
run "oci-backend-safety" "OCI backend keys are distinct, ResourcePrincipal is explicit, and state encryption is configured" \
  bash -c '
    test "$(rg -h "^[[:space:]]*key[[:space:]]*=" infra/*/backend.hcl.example | sort -u | wc -l | tr -d " ")" = 3
    rg -q "kms_key_id[[:space:]]*=[[:space:]]*var.state_bucket_kms_key_id" infra/bootstrap/main.tf
    rg -q "auth[[:space:]]*=[[:space:]]*\\\"ResourcePrincipal\\\"" .github/workflows/terraform-plan.yml .github/workflows/terraform-apply.yml scripts/ci/verify-oci-backend.sh
  '

if rg -q '@[0-9a-f]{40}([[:space:]]|#|$)' .github/workflows/*.yml && \
   ! rg -q '^\s*- uses: [^@]+@(?![0-9a-f]{40}([[:space:]]|#|$))' .github/workflows/*.yml --pcre2; then
  pass "workflow-action-pins" "all third-party GitHub Actions are pinned to immutable commits"
else
  fail "workflow-action-pins" "one or more GitHub Actions are not pinned to immutable commits"
fi

if command -v terraform >/dev/null; then
  if terraform version -json >/dev/null 2>&1; then
    terraform_failure=false
    for root in infra/bootstrap infra/platform infra/frontend; do
      terraform -chdir="$root" fmt -check -recursive >/dev/null 2>&1 || terraform_failure=true
      # validate uses the checked-in lock file and never initializes a backend.
      terraform -chdir="$root" validate >/dev/null 2>&1 || terraform_failure=true
    done
    if [[ "$terraform_failure" == false ]]; then
      pass "terraform-format-and-validate" "all Terraform roots format and validate without a backend"
    else
      fail "terraform-format-and-validate" "one or more roots failed format or offline validation"
    fi
  else
    not_run "terraform-format-and-validate" "terraform is present but cannot report a usable version"
  fi
else
  not_run "terraform-format-and-validate" "terraform is not installed; no provider download was attempted"
fi

if git ls-files | rg -q '\.(pem|key|p12|tfstate|tfplan)$|(^|/)(backend\.hcl|[^/]*\.auto\.tfvars)$'; then
  fail "tracked-secret-material" "tracked credential, state, plan, or generated input file detected"
elif git grep -nE '(gh[pousr]_[A-Za-z0-9_]{20,}|-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----|AKIA[0-9A-Z]{16})' -- . >/dev/null 2>&1; then
  fail "tracked-secret-material" "tracked high-confidence secret pattern detected"
else
  pass "tracked-secret-material" "no tracked credential/state artifact or high-confidence secret pattern found"
fi

if rg -q 'default[[:space:]]*=[[:space:]]*false' infra/platform/variables.tf && \
   rg -q 'count[[:space:]]*=[[:space:]]*var.enable_api_ingress \? 1 : 0' infra/platform/load_balancer.tf infra/platform/cloudflare.tf; then
  pass "ingress-disabled" "API listener, DNS, certificate and cache resources remain gated by false-by-default ingress"
else
  fail "ingress-disabled" "public API ingress is not demonstrably false-by-default"
fi

if [[ -f docs/acceptance/README.md && -f docs/acceptance/checklist.md && -f docs/acceptance/live-validation-runbook.md ]]; then
  pass "acceptance-documentation" "acceptance guide, checklist, and live-validation runbook exist"
else
  fail "acceptance-documentation" "one or more required acceptance documents are missing"
fi

jq -s --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{schema_version:1,generated_at:$generated_at,offline:true,checks:.,summary:{pass:([.[] | select(.status == "PASS")] | length),fail:([.[] | select(.status == "FAIL")] | length),not_run:([.[] | select(.status == "NOT_RUN")] | length)}}' \
  "$checks_file" > "$report_path"

summary="$(jq -r '"PASS=" + (.summary.pass|tostring) + " FAIL=" + (.summary.fail|tostring) + " NOT_RUN=" + (.summary.not_run|tostring)' "$report_path")"
echo "Acceptance summary: $summary"
echo "Machine-readable report: $report_path"

(( failures == 0 ))
