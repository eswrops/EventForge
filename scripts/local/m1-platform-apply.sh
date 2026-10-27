#!/usr/bin/env bash
# M1-LOCAL platform apply — executes EXACTLY one reviewed saved plan.
#
#   m1-platform-apply.sh <plan.tfplan> <metadata.json> <approval-record>
#
# The apply refuses any mismatch against the reviewed metadata (SHA-256,
# source commit, safe-plan verdict, remote state lineage/serial) AND requires
# a written approval record containing "GATE: PLATFORM-APPLY", the plan's
# SHA-256, the source commit, and an APPROVER: line matching the
# M1_APPLY_APPROVED_BY environment attestation — authorization is never
# granted by an environment variable alone or by a passed policy check.
# It never generates a new plan, never uses -auto-approve, retains locking,
# and on any failure stops with preserved logs and NO automatic retry or
# rollback (mission rules 11–14).
set -uo pipefail

# shellcheck source=scripts/local/lib-m1.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-m1.sh"

if [[ $# -ne 3 ]]; then
  echo "usage: m1-platform-apply.sh <plan.tfplan> <metadata.json> <approval-record>" >&2
  exit 64
fi
if [[ -z "${M1_APPLY_APPROVED_BY:-}" ]]; then
  echo "Refusing to apply: set M1_APPLY_APPROVED_BY to the APPROVER recorded in the approval record" >&2
  exit 1
fi

m1_init_evidence
m1_evidence_record "platform apply start (run $M1_RUN_TAG)"

plan_file="$1"
metadata_file="$2"
approval_record="$3"
root="$M1_REPO_ROOT/infra/platform"
backend_hcl="$root/backend.hcl"

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
m1_verify_backend_config "$backend_hcl" "$M1_PLATFORM_KEY" \
  && m1_check PASS "backend-config" "coordinates approved" \
  || fail_gate backend-config "unexpected backend coordinates"
[[ -f "$plan_file" && -f "$metadata_file" ]] \
  && m1_check PASS "artifacts-present" "$(basename "$plan_file") + metadata" \
  || fail_gate artifacts-present "plan or metadata missing"

# Metadata contract ------------------------------------------------------------
plan_sha="$(shasum -a 256 "$plan_file" | awk '{print $1}')"
meta_plan="$(jq -r '.plan' "$metadata_file")"
meta_sha="$(jq -r '.plan_sha256' "$metadata_file")"
meta_commit="$(jq -r '.commit' "$metadata_file")"
meta_safe_plan="$(jq -r '.safe_plan' "$metadata_file")"
meta_lineage="$(jq -r '.state_lineage' "$metadata_file")"
meta_serial="$(jq -r '.state_serial' "$metadata_file")"
meta_applied="$(jq -r '.applied' "$metadata_file")"
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
  && m1_check PASS "metadata-safe-plan" "reviewed policy PASS" \
  || fail_gate metadata-safe-plan "plan was never policy-approved"
[[ "$meta_applied" != "true" ]] \
  && m1_check PASS "metadata-not-applied" "plan not previously applied" \
  || fail_gate metadata-not-applied "this plan was already applied"

# Written approval record — the plan SHA-256 and commit must be named in it,
# and the operator's env attestation must match the record's APPROVER line.
if m1_verify_approval_record "$approval_record" "PLATFORM-APPLY" "$plan_sha" "$commit"; then
  record_approver="$(awk -F': ' '/^APPROVER:/{print $2; exit}' "$approval_record")"
  [[ "$record_approver" == "$M1_APPLY_APPROVED_BY" ]] \
    && m1_check PASS "approval-record" "PLATFORM-APPLY approved by $record_approver (plan-SHA-bound)" \
    || fail_gate approval-record "M1_APPLY_APPROVED_BY does not match the record's APPROVER line"
else
  fail_gate approval-record \
    "invalid or missing approval record ($approval_record): it must contain 'GATE: PLATFORM-APPLY', the plan SHA-256 $plan_sha, commit $commit, and an APPROVER: line"
fi

m1_verify_workspace_default "$M1_TERRAFORM_BIN" "$root" \
  && m1_check PASS "workspace-default" "default" \
  || fail_gate workspace-default "non-default workspace"
m1_verify_no_lock_objects "platform/" \
  && m1_check PASS "no-locks" "no remote lock objects" \
  || fail_gate no-locks "stale or live lock objects under platform/"

# The remote state must be exactly the state this plan was built against.
pre_pull="$M1_EVIDENCE_DIR/state/platform-pre-apply.tfstate"
"$M1_TERRAFORM_BIN" -chdir="$root" state pull > "$pre_pull" 2>"$M1_EVIDENCE_DIR/logs/pre-apply-pull.err" \
  && [[ -s "$pre_pull" ]] \
  && m1_check PASS "pre-apply-snapshot" "state snapshot saved" \
  || fail_gate pre-apply-snapshot "could not pull platform state before apply"
read -r live_lineage live_serial <<<"$(m1_state_meta "$pre_pull")"
[[ "$live_lineage" == "$meta_lineage" && "$live_serial" == "$meta_serial" ]] \
  && m1_check PASS "state-unchanged-since-plan" "lineage=$live_lineage serial=$live_serial" \
  || fail_gate state-unchanged-since-plan \
       "remote state moved since the plan (lineage=$live_lineage serial=$live_serial, expected $meta_lineage/$meta_serial) — re-plan and re-review"

m1_evidence_record "apply of $plan_file (sha $plan_sha) beginning — single execution, no retry"

# Apply — one execution of the reviewed plan; no new plan, no -auto-approve.
apply_log="$M1_EVIDENCE_DIR/logs/platform-apply.log"
for a in "$@"; do
  [[ "$a" == "-auto-approve" ]] && fail_gate auto-approve "-auto-approve is prohibited (rule 13)"
done
if "$M1_TERRAFORM_BIN" -chdir="$root" apply -input=false -lock=true "$plan_file" >"$apply_log" 2>&1; then
  m1_check PASS "terraform-apply" "apply completed (log preserved)"
else
  rc=$?
  tail -60 "$apply_log" >&2
  m1_evidence_record "GATE FAIL: apply failed rc=$rc — STOP, no retry, no rollback"
  fail_gate terraform-apply \
    "apply FAILED rc=$rc. STOPPED per rules 11/15: preserve $apply_log, inspect live OCI changes and remote state before any operator decision"
fi

# Post-apply protected state backup ----------------------------------------------
post_pull="$M1_EVIDENCE_DIR/state/platform-post-apply.tfstate"
"$M1_TERRAFORM_BIN" -chdir="$root" state pull > "$post_pull" 2>"$M1_EVIDENCE_DIR/logs/post-apply-pull.err" \
  && [[ -s "$post_pull" ]] \
  && m1_check PASS "post-apply-snapshot" "$(m1_state_meta "$post_pull")" \
  || fail_gate post-apply-snapshot "could not snapshot post-apply state"

# Mark the plan as consumed so it cannot be applied twice.
jq '.applied = true | .apply_evidence = $e' \
  --arg e "$M1_EVIDENCE_DIR" "$metadata_file" > "$metadata_file.applied" \
  && mv "$metadata_file.applied" "$metadata_file"
m1_evidence_record "apply complete; metadata marked applied"

echo "Apply complete — evidence in $M1_EVIDENCE_DIR"
echo "Next: run scripts/local/m1-verify.sh before claiming M1C-PLATFORM."
