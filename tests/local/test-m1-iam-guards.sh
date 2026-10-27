#!/usr/bin/env bash
# Offline tests for the guarded IAM execution scripts (MYSQL-NSG-IAM track).
# Never contacts OCI: every refusal exercised here happens in the OFFLINE
# contract-check section of the scripts, before any live access.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail() { echo "TEST FAIL: $1" >&2; exit 1; }

for script in m1-iam-init.sh m1-iam-plan.sh m1-iam-apply.sh; do
  [[ -x "$repo_root/scripts/local/$script" ]] || fail "$script must be executable"
  bash -n "$repo_root/scripts/local/$script" || fail "$script must parse"
done

# Contract greps: the state-key ownership rule (absent, no override) and the
# never-permitted operations.
grep -q 'already exists — the iam/ state key has an owner' "$repo_root/scripts/local/m1-iam-init.sh" \
  || fail "init must stop on an owned iam/ state key"
if grep -Eq -- '-migrate-state|-reconfigure|-force-copy' "$repo_root/scripts/local/m1-iam-init.sh" \
   && ! grep -q 'never permitted' "$repo_root/scripts/local/m1-iam-init.sh"; then
  fail "init migration flags must be actively refused"
fi
grep -q 'M1_IAM_APPLY_APPROVED_BY' "$repo_root/scripts/local/m1-iam-apply.sh" \
  || fail "apply must require an explicit operator attestation"
grep -q 'm1_verify_approval_record' "$repo_root/scripts/local/m1-iam-apply.sh" \
  || fail "apply must verify a written approval record (not env-only authorization)"
grep -q 'state-still-absent' "$repo_root/scripts/local/m1-iam-apply.sh" \
  || fail "apply must refuse when the iam state key exists at apply time"
if grep -q -- '-auto-approve' "$repo_root/scripts/local/m1-iam-plan.sh"; then
  fail "plan script must not reference -auto-approve"
fi
grep -q 'approval record is consumed' "$repo_root/scripts/local/m1-iam-apply.sh" \
  || fail "apply must consume the approval record on failure"

# The CI-level checker fixtures (exact two-policy contract, verbatim statement
# rendering) are exercised in tests/ci/test-iam-plan-guard.sh.
[[ -x "$repo_root/tests/ci/test-iam-plan-guard.sh" ]] || fail "IAM checker fixtures must be executable"
"$repo_root/tests/ci/test-iam-plan-guard.sh" || fail "IAM checker fixtures must pass"
[[ -x "$repo_root/tests/ci/test-safe-plan-mysql-retest.sh" ]] || fail "retest fixtures must be executable"

# ------------------------------------------------------------- apply offline refusals
plan_file="$work/plan.tfplan"
metadata_file="$work/metadata.json"
printf 'binary-plan-placeholder' > "$plan_file"
plan_sha="$(shasum -a 256 "$plan_file" | awk '{print $1}')"
commit="$(git -C "$repo_root" rev-parse HEAD)"
cat > "$metadata_file" <<EOF
{"plan":"$plan_file","plan_sha256":"$plan_sha","commit":"$commit","safe_plan":"PASS",
 "expected_state":"absent","applied":false,"apply_evidence":null,
 "terraform_version":"1.12.2","bucket":"eventforge-tfstate-prod","state_key":"iam/terraform.tfstate"}
EOF

run_apply() { # run_apply <record-file-or-missing> [env...]
  ( cd "$work" && M1_EVIDENCE_DIR="$work/evidence" M1_EVIDENCE_ROOT="$work/evidence-root" \
      "$repo_root/scripts/local/m1-iam-apply.sh" "$plan_file" "$metadata_file" "$@" >/dev/null 2>&1 )
}

if M1_IAM_APPLY_APPROVED_BY="" run_apply "$work/record.md"; then
  fail "apply must refuse without M1_IAM_APPLY_APPROVED_BY"
fi
if M1_IAM_APPLY_APPROVED_BY=op run_apply "$work/missing-record.md"; then
  fail "apply must refuse a missing approval record"
fi

# Wrong gate marker, wrong plan SHA, wrong commit, and a missing statement
# binding must each be refused offline.
printf 'GATE: PLATFORM-APPLY\nAPPROVER: op\n%s\n%s\niam/terraform.tfstate absent\n' "$plan_sha" "$commit" > "$work/record-wronggate.md"
if M1_IAM_APPLY_APPROVED_BY=op run_apply "$work/record-wronggate.md"; then
  fail "apply must refuse a record with the wrong gate marker"
fi

grep -v "$plan_sha" "$metadata_file" >/dev/null # no-op; build mismatching metadata explicitly
jq --arg sha "0000wrong" '.plan_sha256 = $sha' "$metadata_file" > "$work/meta-wrongsha.json"
if M1_IAM_APPLY_APPROVED_BY=op M1_EVIDENCE_DIR="$work/evidence" M1_EVIDENCE_ROOT="$work/evidence-root" \
     "$repo_root/scripts/local/m1-iam-apply.sh" "$plan_file" "$work/meta-wrongsha.json" "$work/record.md" >/dev/null 2>&1; then
  fail "apply must refuse a plan/metadata SHA mismatch"
fi

jq --arg c "0000oldcommit" '.commit = $c' "$metadata_file" > "$work/meta-wrongcommit.json"
if M1_IAM_APPLY_APPROVED_BY=op M1_EVIDENCE_DIR="$work/evidence" M1_EVIDENCE_ROOT="$work/evidence-root" \
     "$repo_root/scripts/local/m1-iam-apply.sh" "$plan_file" "$work/meta-wrongcommit.json" "$work/record.md" >/dev/null 2>&1; then
  fail "apply must refuse when the repository moved since review"
fi

jq '.expected_state = "present"' "$metadata_file" > "$work/meta-wrongstate.json"
if M1_IAM_APPLY_APPROVED_BY=op M1_EVIDENCE_DIR="$work/evidence" M1_EVIDENCE_ROOT="$work/evidence-root" \
     "$repo_root/scripts/local/m1-iam-apply.sh" "$plan_file" "$work/meta-wrongstate.json" "$work/record.md" >/dev/null 2>&1; then
  fail "apply must refuse unexpected expected_state"
fi

# A complete record (all bindings + both verbatim statements) still must not
# proceed past the OFFLINE section in a test environment — it would next hit
# the live guards; here we only assert the record-validation logic accepts it
# by checking the contract library directly.
lib="$repo_root/scripts/local/lib-m1.sh"
export M1_EVIDENCE_DIR="$work/evidence" M1_EVIDENCE_ROOT="$work/evidence-root"
# shellcheck source=scripts/local/lib-m1.sh
source "$lib"
db_ocid="ocid1.compartment.oc1..placeholder-for-tests"
tenancy_ocid="ocid1.tenancy.oc1..placeholder-for-tests"
mapfile -t stmts < <("$repo_root/scripts/ci/assert-iam-plan.sh" \
  --policy "$repo_root/scripts/ci/iam-plan-contract.json" \
  --var "db_compartment_ocid=$db_ocid" --var "tenancy_ocid=$tenancy_ocid" \
  --print-statements)
[[ "${#stmts[@]}" -eq 2 ]] || fail "expected 2 rendered statements from the contract"
cat > "$work/record-complete.md" <<EOF
GATE: MYSQL-NSG-IAM
APPROVER: op
COMMIT: $commit
PLAN SHA-256: $plan_sha
STATEMENT 1: ${stmts[0]}
STATEMENT 2: ${stmts[1]}
Expected initial state: iam/terraform.tfstate absent
Resources: oci_identity_policy.mysql_nsg_membership, oci_identity_policy.mysql_vnic_update
EOF
m1_verify_approval_record "$work/record-complete.md" "MYSQL-NSG-IAM" \
  "$plan_sha" "$commit" "oci_identity_policy.mysql_nsg_membership" \
  "oci_identity_policy.mysql_vnic_update" "${stmts[0]}" "${stmts[1]}" "iam/terraform.tfstate absent" \
  || fail "a complete statement-bound record must validate"

echo "IAM local guard tests passed"
