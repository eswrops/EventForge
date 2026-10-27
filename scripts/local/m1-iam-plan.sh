#!/usr/bin/env bash
# M1-LOCAL IAM plan — guarded, evidence-producing, never applied here.
# Operates only on infra/iam. Produces in the protected evidence dir:
#   1. saved plan (.tfplan, mode 0600)
#   2. JSON plan
#   3. plan SHA-256
#   4. source commit SHA
#   5. safe_plan verdict from the dedicated IAM contract checker
#      (scripts/ci/assert-iam-plan.sh — exact two-policy create set)
#   6. state-key identity at plan time (must be absent)
# The apply script consumes exactly this plan+metadata pair and refuses
# mismatches. Every non-no-op resource beyond the reviewed two-policy create
# set is refused by the contract checker — no address-level allowlist, the
# complete statements are compared character-for-character.
set -uo pipefail

# shellcheck source=scripts/local/lib-m1.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-m1.sh"

m1_init_evidence
m1_evidence_record "iam plan start (run $M1_RUN_TAG)"

root="$M1_REPO_ROOT/infra/iam"
backend_hcl="$root/backend.hcl"
tfvars="$root/terraform.auto.tfvars"

fail_gate() { m1_check FAIL "$1" "${*:2}"; m1_evidence_record "GATE FAIL: $1"; m1_exit_gate_failed; }

# Guards ------------------------------------------------------------------
m1_verify_terraform_bin \
  && m1_check PASS "terraform-pinned" "v$M1_TERRAFORM_VERSION" \
  || fail_gate terraform-pinned "wrong binary"
m1_verify_auth_mode \
  && m1_check PASS "auth-apikey-profile" "profile $M1_OCI_PROFILE" \
  || fail_gate auth-apikey-profile "invalid authentication"
m1_verify_locking_retained "$@" \
  && m1_check PASS "locking-retained" "locking retained" \
  || fail_gate locking-retained "lock disabling refused"
m1_verify_no_recovery_invocation "$@" \
  && m1_check PASS "no-state-recovery" "none" \
  || fail_gate no-state-recovery "recovery invocation refused"
m1_verify_bucket_preconditions \
  && m1_check PASS "state-bucket" "private/versioned/CMK-bound" \
  || fail_gate state-bucket "preconditions failed"
m1_verify_cmk_enabled \
  && m1_check PASS "cmk-enabled" "ENABLED" \
  || fail_gate cmk-enabled "CMK not ENABLED"
m1_verify_backend_config "$backend_hcl" "$M1_IAM_KEY" \
  && m1_check PASS "backend-config" "coordinates approved" \
  || fail_gate backend-config "unexpected backend coordinates"

[[ -d "$root/.terraform" ]] \
  && m1_check PASS "iam-initialized" "provider/backend present" \
  || fail_gate iam-initialized "run m1-iam-init.sh first"
m1_verify_workspace_default "$M1_TERRAFORM_BIN" "$root" \
  && m1_check PASS "workspace-default" "default" \
  || fail_gate workspace-default "non-default workspace"
m1_verify_no_lock_objects "iam/" \
  && m1_check PASS "no-locks" "no remote lock objects" \
  || fail_gate no-locks "stale or live lock objects under iam/"

# Expected initial state: absence must still be PROVEN. A state object,
# historical version, or delete marker here means the root's ownership changed
# since the reviewed baseline — STOP.
if m1_prove_state_key_absent "$M1_IAM_KEY"; then
  m1_check PASS "iam-key" "$M1_IAM_KEY absence proven — matches the expected initial state"
else
  fail_gate iam-key "$M1_IAM_KEY absence could not be proven (details above) — reconcile ownership before planning"
fi

# Operator OCIDs (git-ignored, reviewed per root) for the contract rendering.
[[ -f "$tfvars" ]] || fail_gate operator-vars "$tfvars missing — operator workstation inputs are required"
db_ocid="$(awk -F'"' '/^[[:space:]]*db_compartment_ocid[[:space:]]*=/{print $2}' "$tfvars")"
tenancy_ocid="$(awk -F'"' '/^[[:space:]]*tenancy_ocid[[:space:]]*=/{print $2}' "$tfvars")"
[[ "$db_ocid" == ocid1.compartment.oc1.* ]] \
  || fail_gate operator-vars "db_compartment_ocid missing or malformed in $tfvars"
[[ "$tenancy_ocid" == ocid1.tenancy.oc1.* ]] \
  || fail_gate operator-vars "tenancy_ocid missing or malformed in $tfvars"
m1_check PASS "operator-vars" "compartment and tenancy OCIDs present"

commit="$(git -C "$M1_REPO_ROOT" rev-parse HEAD)"
operator="$(git -C "$M1_REPO_ROOT" config user.name)"

# Plan -----------------------------------------------------------------------
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
plan_file="$M1_EVIDENCE_DIR/plans/iam-$stamp.tfplan"
plan_json="$M1_EVIDENCE_DIR/plans/iam-$stamp.json"
plan_log="$M1_EVIDENCE_DIR/logs/iam-plan.log"

if "$M1_TERRAFORM_BIN" -chdir="$root" plan -input=false -lock=true -out="$plan_file" >"$plan_log" 2>&1; then
  plan_rc=0
else
  plan_rc=$?
fi
case $plan_rc in
  0) m1_check PASS "terraform-plan" "plan produced (log preserved)" ;;
  2) m1_check PASS "terraform-plan" "plan produced with diffs (log preserved)" ;;
  *) tail -40 "$plan_log" >&2
     fail_gate terraform-plan "plan failed rc=$plan_rc — inspect $plan_log; no automatic retry (rule 11)" ;;
esac

chmod 600 "$plan_file"
"$M1_TERRAFORM_BIN" -chdir="$root" show -json "$plan_file" > "$plan_json" 2>"$M1_EVIDENCE_DIR/logs/iam-show.err" \
  && m1_check PASS "plan-json" "JSON representation written (0600)" \
  || fail_gate plan-json "could not render plan JSON"
chmod 600 "$plan_json"

plan_sha="$(shasum -a 256 "$plan_file" | awk '{print $1}')"
m1_plan_action_summary "$plan_json" > "$M1_EVIDENCE_DIR/plans/iam-$stamp.actions.txt" || true

# IAM contract checker — the exact two-policy create set, character-exact
# statements. This is the guard that rejects any additional resource, action,
# or policy statement.
if "$M1_REPO_ROOT/$M1_IAM_PLAN_CHECKER" \
     --policy "$M1_REPO_ROOT/$M1_IAM_PLAN_CONTRACT" \
     --var "db_compartment_ocid=$db_ocid" \
     --var "tenancy_ocid=$tenancy_ocid" \
     "$plan_json" >"$M1_EVIDENCE_DIR/logs/iam-contract.log" 2>&1; then
  safe_plan="PASS"
  m1_check PASS "iam-plan-contract" "plan matches the reviewed two-policy IAM contract"
else
  safe_plan="FAIL"
  m1_check FAIL "iam-plan-contract" "plan violates the reviewed IAM contract — gate stops"
  cat "$M1_EVIDENCE_DIR/logs/iam-contract.log" >&2
fi

changes_total="$(grep -c . "$M1_EVIDENCE_DIR/plans/iam-$stamp.actions.txt" || true)"
jq -n \
  --arg run_tag "$M1_RUN_TAG" --arg commit "$commit" --arg operator "$operator" \
  --arg plan "$plan_file" --arg plan_json "$plan_json" --arg plan_sha "$plan_sha" \
  --arg safe_plan "$safe_plan" --argjson changes "$changes_total" \
  --arg expected_state "absent" \
  --arg safe_plan_policy "$M1_IAM_PLAN_CONTRACT" \
  --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{plan:$plan, plan_json:$plan_json, plan_sha256:$plan_sha, commit:$commit, operator:$operator,
    safe_plan:$safe_plan, safe_plan_policy:$safe_plan_policy,
    expected_state:$expected_state, non_noop_changes:$changes,
    terraform_version:$tv, bucket:$bucket, state_key:$key,
    applied:false, apply_evidence:null, timestamp:$timestamp}' \
  --arg tv "$M1_TERRAFORM_VERSION" --arg bucket "$M1_TF_STATE_BUCKET" --arg key "$M1_IAM_KEY" \
  > "$M1_EVIDENCE_DIR/plans/iam-$stamp.metadata.json"
chmod 600 "$M1_EVIDENCE_DIR/plans/iam-$stamp.metadata.json"

[[ "$safe_plan" == "PASS" ]] \
  && m1_evidence_record "plan complete safe_plan=PASS changes=$changes_total" \
  || m1_evidence_record "plan complete safe_plan=FAIL changes=$changes_total"

echo "Plan artifacts in $M1_EVIDENCE_DIR/plans/ (safe_plan=$safe_plan, changes=$changes_total)"
[[ "$safe_plan" == "PASS" ]]
