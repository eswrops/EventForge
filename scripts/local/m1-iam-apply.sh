#!/usr/bin/env bash
# M1-LOCAL IAM apply — executes EXACTLY one reviewed two-policy plan.
#
#   m1-iam-apply.sh <plan.tfplan> <metadata.json> <approval-record>
#
# Offline contract checks run FIRST (plan/metadata/approval triangle), so a
# tampered or unapproved artifact never reaches OCI and the contract is
# testable offline. The written approval record must carry "GATE:
# MYSQL-NSG-IAM", the plan SHA-256, the source commit, BOTH complete policy
# statements (verified verbatim against the rendered IAM contract), both
# resource addresses, the expected initial state (iam/terraform.tfstate
# absent), and an APPROVER: line matching the M1_IAM_APPLY_APPROVED_BY
# environment attestation — authorization is never granted by an environment
# variable alone or by a passing policy check. Because the effective scope of
# `eventforge-mysql-vnic-update` is tenancy-wide via policy inheritance (no
# documented root-only form exists), the record must additionally carry
# EXACTLY ONE explicit decision line — `SCOPE_DECISION:
# ACCEPT_TENANCY_WIDE_VNIC` — validated before any live access; a missing,
# placeholder, ORACLE_FIRST, DECLINED, multiple/conflicting, or
# commentary-copied decision refuses execution. The apply refuses when the
# remote state key exists (ownership moved since review), never generates a
# new plan, never uses -auto-approve, retains locking, and on any failure
# consumes the approval with preserved logs and NO retry or rollback.
set -uo pipefail

# shellcheck source=scripts/local/lib-m1.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-m1.sh"

if [[ $# -ne 3 ]]; then
  echo "usage: m1-iam-apply.sh <plan.tfplan> <metadata.json> <approval-record>" >&2
  exit 64
fi
if [[ -z "${M1_IAM_APPLY_APPROVED_BY:-}" ]]; then
  echo "Refusing to apply: set M1_IAM_APPLY_APPROVED_BY to the APPROVER recorded in the approval record" >&2
  exit 1
fi

m1_init_evidence
m1_evidence_record "iam apply start (run $M1_RUN_TAG)"

plan_file="$1"
metadata_file="$2"
approval_record="$3"
root="$M1_REPO_ROOT/infra/iam"
backend_hcl="$root/backend.hcl"
tfvars="$root/terraform.auto.tfvars"
contract="$M1_REPO_ROOT/$M1_IAM_PLAN_CONTRACT"

fail_gate() { m1_check FAIL "$1" "${*:2}"; m1_evidence_record "GATE FAIL: $1"; m1_exit_gate_failed; }

# Offline contract checks ------------------------------------------------------
[[ -f "$plan_file" && -f "$metadata_file" ]] \
  && m1_check PASS "artifacts-present" "$(basename "$plan_file") + metadata" \
  || fail_gate artifacts-present "plan or metadata missing"

plan_sha="$(shasum -a 256 "$plan_file" | awk '{print $1}')"
meta_plan="$(jq -r '.plan' "$metadata_file")"
meta_sha="$(jq -r '.plan_sha256' "$metadata_file")"
meta_commit="$(jq -r '.commit' "$metadata_file")"
meta_safe_plan="$(jq -r '.safe_plan' "$metadata_file")"
meta_applied="$(jq -r '.applied' "$metadata_file")"
meta_expected_state="$(jq -r '.expected_state' "$metadata_file")"
commit="$(git -C "$M1_REPO_ROOT" rev-parse HEAD)"

[[ "$meta_plan" == "$plan_file" ]] \
  && m1_check PASS "metadata-plan-path" "$plan_file" \
  || fail_gate metadata-plan-path "metadata names a different plan: $meta_plan"
[[ "$meta_sha" == "$plan_sha" ]] \
  && m1_check PASS "metadata-plan-sha" "$plan_sha" \
  || fail_gate metadata-plan-sha "plan content changed since review"
[[ "$meta_commit" == "$commit" ]] \
  && m1_check PASS "metadata-commit" "$commit" \
  || fail_gate metadata-commit "repository moved since review ($meta_commit)"
[[ "$meta_safe_plan" == "PASS" ]] \
  && m1_check PASS "metadata-safe-plan" "reviewed IAM contract PASS" \
  || fail_gate metadata-safe-plan "plan was never contract-approved"
[[ "$meta_expected_state" == "absent" ]] \
  && m1_check PASS "metadata-expected-state" "expected initial state: $M1_IAM_KEY absent" \
  || fail_gate metadata-expected-state "unexpected expected_state in metadata: $meta_expected_state"
[[ "$meta_applied" != "true" ]] \
  && m1_check PASS "metadata-not-applied" "plan not previously applied" \
  || fail_gate metadata-not-applied "this plan was already applied"

# Render the reviewed statements from the contract and require the approval
# record to carry them verbatim, together with both addresses and the
# expected-initial-state binding.
[[ -f "$tfvars" ]] || fail_gate operator-vars "$tfvars missing"
db_ocid="$(awk -F'"' '/^[[:space:]]*db_compartment_ocid[[:space:]]*=/{print $2}' "$tfvars")"
tenancy_ocid="$(awk -F'"' '/^[[:space:]]*tenancy_ocid[[:space:]]*=/{print $2}' "$tfvars")"
[[ "$db_ocid" == ocid1.compartment.oc1.* && "$tenancy_ocid" == ocid1.tenancy.oc1.* ]] \
  || fail_gate operator-vars "operator OCIDs missing or malformed in $tfvars"
mapfile -t reviewed_statements < <("$M1_REPO_ROOT/$M1_IAM_PLAN_CHECKER" \
  --policy "$contract" \
  --var "db_compartment_ocid=$db_ocid" \
  --var "tenancy_ocid=$tenancy_ocid" \
  --print-statements)
((${#reviewed_statements[@]} == 2)) \
  && m1_check PASS "reviewed-statements" "${#reviewed_statements[@]} statements rendered from the contract" \
  || fail_gate reviewed-statements "expected exactly 2 reviewed statements"

record_requirements=("GATE: MYSQL-NSG-IAM" "$plan_sha" "$commit"
  "oci_identity_policy.mysql_nsg_membership" "oci_identity_policy.mysql_vnic_update"
  "${reviewed_statements[0]}" "${reviewed_statements[1]}"
  "$M1_IAM_KEY absent")
if m1_verify_approval_record "$approval_record" "MYSQL-NSG-IAM" "${record_requirements[@]}"; then
  record_approver="$(awk -F': ' '/^APPROVER:/{print $2; exit}' "$approval_record")"
  [[ "$record_approver" == "$M1_IAM_APPLY_APPROVED_BY" ]] \
    && m1_check PASS "approval-record" "MYSQL-NSG-IAM approved by $record_approver (plan-SHA- and statement-bound)" \
    || fail_gate approval-record "M1_IAM_APPLY_APPROVED_BY does not match the record's APPROVER line"
else
  fail_gate approval-record \
    "invalid or missing approval record ($approval_record): it must contain 'GATE: MYSQL-NSG-IAM', the plan SHA-256 $plan_sha, commit $commit, both resource addresses, both reviewed statements verbatim, '$M1_IAM_KEY absent', and an APPROVER: line"
fi

# Machine-enforced risk acceptance (blocker): the tenancy-wide effective scope
# of `eventforge-mysql-vnic-update` must be explicitly accepted with EXACTLY
# ONE standalone `SCOPE_DECISION: ACCEPT_TENANCY_WIDE_VNIC` line in the record
# — validated here, in the OFFLINE section, before any live access.
if m1_verify_scope_decision "$approval_record"; then
  m1_check PASS "scope-decision" "ACCEPT_TENANCY_WIDE_VNIC recorded (exactly one explicit decision)"
else
  fail_gate scope-decision \
    "the approval record lacks exactly one standalone 'SCOPE_DECISION: ACCEPT_TENANCY_WIDE_VNIC' line — missing decisions, placeholders, ORACLE_FIRST, DECLINED, multiple/conflicting decisions, decisions quoted in template commentary, and lines with trailing text are all refused; see the scope analysis in the approval template"
fi

# Independent pre-execution revalidation: render the saved plan (.tfplan — the
# exact SHA-bound artifact, not a companion JSON) back to JSON with the pinned
# binary and run the IAM contract checker against it with the operator OCIDs.
# This catches any saved plan whose content does not match the reviewed
# two-policy contract immediately before execution, independently of the
# plan-time metadata.
m1_verify_terraform_bin \
  && m1_check PASS "terraform-pinned-recheck" "v$M1_TERRAFORM_VERSION" \
  || fail_gate terraform-pinned-recheck "wrong binary for plan revalidation"
recheck_json="$M1_EVIDENCE_DIR/state/plan-recheck.json"
"$M1_TERRAFORM_BIN" -chdir="$root" show -json "$plan_file" > "$recheck_json" \
  2>"$M1_EVIDENCE_DIR/logs/plan-recheck-show.err" \
  || fail_gate offline-contract-recheck "could not render the saved plan for revalidation — inspect $M1_EVIDENCE_DIR/logs/plan-recheck-show.err"
chmod 600 "$recheck_json"
if "$M1_REPO_ROOT/$M1_IAM_PLAN_CHECKER" \
     --policy "$contract" \
     --var "db_compartment_ocid=$db_ocid" \
     --var "tenancy_ocid=$tenancy_ocid" \
     "$recheck_json" >"$M1_EVIDENCE_DIR/logs/plan-recheck.log" 2>&1; then
  m1_check PASS "offline-contract-recheck" "saved plan revalidated against the reviewed IAM contract"
else
  cat "$M1_EVIDENCE_DIR/logs/plan-recheck.log" >&2
  fail_gate offline-contract-recheck "the saved plan does not match the reviewed two-policy IAM contract — REFUSING to execute"
fi

# Live guards -----------------------------------------------------------------
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
m1_verify_workspace_default "$M1_TERRAFORM_BIN" "$root" \
  && m1_check PASS "workspace-default" "default" \
  || fail_gate workspace-default "non-default workspace"
m1_verify_no_lock_objects "iam/" \
  && m1_check PASS "no-locks" "no remote lock objects" \
  || fail_gate no-locks "stale or live lock objects under iam/"

# The state key must still be absent — proven, not assumed: the reviewed plan
# was built against an empty root; an appearing object, historical version, or
# delete marker is an ownership change, not a drift.
if m1_prove_state_key_absent "$M1_IAM_KEY"; then
  m1_check PASS "state-still-absent" "$M1_IAM_KEY absence proven"
else
  fail_gate state-still-absent "$M1_IAM_KEY absence could not be proven at apply time (details above) — STOP and reconcile ownership"
fi

m1_evidence_record "apply of $plan_file (sha $plan_sha) beginning — single execution, no retry"

# Apply — one execution of the reviewed plan; no new plan, no -auto-approve.
apply_log="$M1_EVIDENCE_DIR/logs/iam-apply.log"
for a in "$@"; do
  [[ "$a" == "-auto-approve" ]] && fail_gate auto-approve "-auto-approve is prohibited (rule 13)"
done
if "$M1_TERRAFORM_BIN" -chdir="$root" apply -input=false -lock=true "$plan_file" >"$apply_log" 2>&1; then
  m1_check PASS "terraform-apply" "apply completed (log preserved)"
else
  rc=$?
  tail -60 "$apply_log" >&2
  # A failed apply consumes this approval record (rule 11): the same approval
  # can never authorize a retry; a new attempt needs fresh plan+metadata+record.
  jq '.applied = true | .apply_evidence = ("FAILED rc=" + $rc + " — approval consumed; plan must not be re-applied")' \
    --arg rc "$rc" "$metadata_file" > "$metadata_file.consumed" \
    && mv "$metadata_file.consumed" "$metadata_file" \
    && chmod 600 "$metadata_file" \
    && m1_evidence_record "metadata marked applied=FAILED — approval record consumed"
  m1_evidence_record "GATE FAIL: apply failed rc=$rc — STOP, no retry, no rollback"
  fail_gate terraform-apply \
    "apply FAILED rc=$rc. STOPPED per rules 11/15: preserve $apply_log; this approval record is consumed — re-attempting requires a fresh plan, metadata, and approval"
fi

# Post-apply state snapshot ------------------------------------------------------
post_pull="$M1_EVIDENCE_DIR/state/iam-post-apply.tfstate"
"$M1_TERRAFORM_BIN" -chdir="$root" state pull > "$post_pull" 2>"$M1_EVIDENCE_DIR/logs/post-apply-pull.err" \
  && [[ -s "$post_pull" ]] \
  && m1_check PASS "post-apply-snapshot" "$(m1_state_meta "$post_pull")" \
  || fail_gate post-apply-snapshot "could not snapshot post-apply state"
chmod 600 "$post_pull"

policy_count="$(jq -r '[.resources[]? | select(.type == "oci_identity_policy")] | length' "$post_pull")"
[[ "$policy_count" == "2" ]] \
  && m1_check PASS "post-apply-resources" "exactly 2 oci_identity_policy resources in state" \
  || fail_gate post-apply-resources "state holds $policy_count oci_identity_policy resources, expected 2"

# Mark the plan as consumed so it cannot be applied twice.
jq '.applied = true | .apply_evidence = $e' \
  --arg e "$M1_EVIDENCE_DIR" "$metadata_file" > "$metadata_file.applied" \
  && mv "$metadata_file.applied" "$metadata_file"
m1_evidence_record "apply complete; metadata marked applied"

echo "IAM apply complete — evidence in $M1_EVIDENCE_DIR"
echo "Next: record the execution in the MYSQL-NSG-IAM approval, verify policy propagation, then seek the separate MYSQL-NSG-RETEST approval."
