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

# Contract greps: the state-key ownership rule (absence must be PROVEN, no
# override) and the never-permitted operations.
grep -q 'm1_prove_state_key_absent' "$repo_root/scripts/local/m1-iam-init.sh" \
  || fail "init must prove state-key absence fail-closed"
grep -q 'exists, has history, or the listing failed' "$repo_root/scripts/local/m1-iam-init.sh" \
  || fail "init must stop on an owned or historically-versioned iam/ state key"
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

# ------------------------------------------------- state-key absence proof (fail closed)
# The proof must never infer absence from an authorization/service error, an
# unparseable listing, historical object versions, or delete markers.
stubbin="$work/stub-bin"
mkdir -p "$stubbin"
make_oci_stub() { # make_oci_stub <stdout> <rc>
  printf '#!/bin/sh\ncat <<'"'"'IAMEOF'"'"'\n%s\nIAMEOF\nexit %s\n' "$1" "$2" > "$stubbin/oci"
  chmod +x "$stubbin/oci"
}
run_proof() { PATH="$stubbin:$PATH" m1_prove_state_key_absent "iam/terraform.tfstate" >/dev/null 2>&1; }

make_oci_stub '{"data":[]}' 0
run_proof || fail "clean versionless listing must prove absence"

make_oci_stub '{"data":[{"name":"iam/terraform.tfstate","version-id":"v1","is-delete-marker":false,"time-created":"2026-10-27T20:00:00Z"}]}' 0
if run_proof; then fail "a historical object version must defeat the absence proof"; fi

make_oci_stub '{"data":[{"name":"iam/terraform.tfstate","version-id":"v2","is-delete-marker":true,"time-created":"2026-10-27T20:00:00Z"}]}' 0
if run_proof; then fail "a delete marker must defeat the absence proof"; fi

make_oci_stub '{"data":[{"name":"iam/terraform.tfstate.lock","version-id":"v3","is-delete-marker":true,"time-created":"2026-10-27T20:00:00Z"}]}' 0
run_proof || fail "an unrelated (lock) object name must not defeat the absence proof"

make_oci_stub 'oci: ServiceError' 1
if run_proof; then fail "an authorization/service error must defeat the absence proof"; fi

make_oci_stub 'not-json-at-all' 0
if run_proof; then fail "an unparseable listing must defeat the absence proof"; fi

make_oci_stub '' 0
if run_proof; then fail "an empty listing body must defeat the absence proof"; fi

rm -f "$stubbin/oci"
echo "ok: state-key absence proof"

# ------------------------------------------------- pre-execution contract recheck
# The apply must re-run the IAM contract checker on the re-rendered saved plan
# as its last offline gate: after the approval-record gate, before any live
# guard and before the terraform apply invocation.
apply_script="$repo_root/scripts/local/m1-iam-apply.sh"
recheck_line="$(grep -n 'offline-contract-recheck" "saved plan revalidated' "$apply_script" | cut -d: -f1)"
record_line="$(grep -n 'PASS "approval-record"' "$apply_script" | cut -d: -f1)"
apply_line="$(grep -n 'apply -input=false -lock=true' "$apply_script" | cut -d: -f1)"
[[ -n "$recheck_line" && -n "$record_line" && -n "$apply_line" ]] || fail "recheck/approval/apply gates must exist in m1-iam-apply.sh"
(( record_line < recheck_line && recheck_line < apply_line )) \
  || fail "the contract recheck must sit between the approval-record gate and the apply"
grep -q 'show -json "$plan_file"' "$apply_script" \
  || fail "the recheck must re-render the SHA-bound .tfplan itself, not a companion JSON"

# Behavioral: with a stub terraform whose `show -json` emits a contract-violating
# plan, the apply must refuse at offline-contract-recheck. Requires the operator
# workstation inputs (real rendered statements for the approval record); on CI
# checkouts without infra/iam/terraform.auto.tfvars the behavioral half is
# skipped — the checker itself is fully fixture-tested in tests/ci.
if [[ -f "$repo_root/infra/iam/terraform.auto.tfvars" ]]; then
  stub_tf="$work/stub-tf"
  mkdir -p "$stub_tf"
  cat > "$stub_tf/terraform" <<STUB
#!/bin/bash
if [[ "\$1" == -chdir=* ]]; then shift 2; fi
if [[ "\$1" == "version" ]]; then echo "Terraform v1.12.2"; echo "on test"; exit 0; fi
if [[ "\$1" == "show" ]]; then cat "$work/recheck-bad.json"; exit 0; fi
exit 99
STUB
  chmod +x "$stub_tf/terraform"
  db_ocid_r="$(awk -F'"' '/^[[:space:]]*db_compartment_ocid[[:space:]]*=/{print $2}' "$repo_root/infra/iam/terraform.auto.tfvars")"
  tenancy_ocid_r="$(awk -F'"' '/^[[:space:]]*tenancy_ocid[[:space:]]*=/{print $2}' "$repo_root/infra/iam/terraform.auto.tfvars")"
  mapfile -t rstmts < <("$repo_root/scripts/ci/assert-iam-plan.sh" \
    --policy "$repo_root/scripts/ci/iam-plan-contract.json" \
    --var "db_compartment_ocid=$db_ocid_r" --var "tenancy_ocid=$tenancy_ocid_r" \
    --print-statements)
  # Contract-violating saved plan: statement 2 broadened to `in tenancy`.
  jq -n --arg db "$db_ocid_r" --arg ten "$tenancy_ocid_r" --arg s1 "${rstmts[0]}" \
    --arg s2 "$(sed "s/in compartment id [^ ]* where all/in tenancy where all/" <<<"${rstmts[1]}")" \
    '{resource_changes:[
      {address:"oci_identity_policy.mysql_nsg_membership",type:"oci_identity_policy",
       change:{actions:["create"],before:null,after:{name:"eventforge-mysql-nsg-membership",compartment_id:$db,statements:[$s1]},after_unknown:{}}},
      {address:"oci_identity_policy.mysql_vnic_update",type:"oci_identity_policy",
       change:{actions:["create"],before:null,after:{name:"eventforge-mysql-vnic-update",compartment_id:$ten,statements:[$s2]},after_unknown:{}}}]}' \
    > "$work/recheck-bad.json"
  printf 'binary-plan-placeholder' > "$work/recheck-plan.tfplan"
  recheck_sha="$(shasum -a 256 "$work/recheck-plan.tfplan" | awk '{print $1}')"
  jq -n --arg p "$work/recheck-plan.tfplan" --arg sha "$recheck_sha" --arg c "$commit" \
    '{plan:$p,plan_sha256:$sha,commit:$c,safe_plan:"PASS",expected_state:"absent",applied:false,apply_evidence:null,
      terraform_version:"1.12.2",bucket:"eventforge-tfstate-prod",state_key:"iam/terraform.tfstate"}' \
    > "$work/recheck-metadata.json"
  cat > "$work/recheck-record.md" <<EOF
GATE: MYSQL-NSG-IAM
APPROVER: test-operator
COMMIT: $commit
PLAN SHA-256: $recheck_sha
STATEMENT 1: ${rstmts[0]}
STATEMENT 2: ${rstmts[1]}
Expected initial state: iam/terraform.tfstate absent
Resources: oci_identity_policy.mysql_nsg_membership, oci_identity_policy.mysql_vnic_update
EOF
  if ( cd "$work" && M1_TERRAFORM_BIN="$stub_tf/terraform" \
        M1_EVIDENCE_DIR="$work/evidence2" M1_EVIDENCE_ROOT="$work/evidence-root2" \
        M1_IAM_APPLY_APPROVED_BY="test-operator" \
        "$repo_root/scripts/local/m1-iam-apply.sh" "$work/recheck-plan.tfplan" \
        "$work/recheck-metadata.json" "$work/recheck-record.md" 2>"$work/recheck.err" ); then
    fail "apply must refuse a saved plan that violates the reviewed contract"
  fi
  grep -q "offline-contract-recheck" "$work/recheck.err" \
    || { echo "recheck refusal output:"; cat "$work/recheck.err" >&2; fail "refusal must name the offline-contract-recheck gate"; }
  echo "ok: pre-execution contract recheck (behavioral)"
else
  echo "skip: pre-execution recheck behavioral test (operator tfvars absent — CI checkout)"
fi

echo "IAM local guard tests passed"
