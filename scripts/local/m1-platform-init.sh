#!/usr/bin/env bash
# M1-LOCAL platform backend init — guarded.
# Initializes infra/platform against the remote OCI backend ONLY after
# checking for pre-existing local and remote state. No implicit backend
# reconfiguration or migration is ever performed:
#   - a pre-existing remote platform state object stops the run; the operator
#     must snapshot it (automatic) and export M1_ALLOW_EXISTING_STATE=<lineage>
#     after reviewing the snapshot, and the live lineage must match exactly.
#   - a pre-existing local platform state file always stops the run.
set -uo pipefail

# shellcheck source=scripts/local/lib-m1.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-m1.sh"

m1_init_evidence
m1_evidence_record "platform init start (run $M1_RUN_TAG)"

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
  && m1_check PASS "locking-retained" "no lock-disabling flags" \
  || fail_gate locking-retained "lock disabling refused"
m1_verify_no_recovery_invocation "$@" \
  && m1_check PASS "no-state-recovery" "no state push / force-unlock" \
  || fail_gate no-state-recovery "recovery invocation refused"
m1_verify_bucket_preconditions \
  && m1_check PASS "state-bucket" "private/versioned/CMK-bound" \
  || fail_gate state-bucket "preconditions failed"
m1_verify_cmk_enabled \
  && m1_check PASS "cmk-enabled" "state CMK ENABLED" \
  || fail_gate cmk-enabled "CMK not ENABLED"
m1_verify_backend_config "$backend_hcl" "$M1_PLATFORM_KEY" \
  && m1_check PASS "backend-config" "$backend_hcl matches approved coordinates" \
  || fail_gate backend-config "unexpected backend coordinates"

# Pre-existing local state -------------------------------------------------
if [[ -f "$root/terraform.tfstate" || -f "$root/terraform.tfstate.backup" ]]; then
  fail_gate local-state "pre-existing local platform state present at $root — operator must review before any init"
fi
m1_check PASS "local-state" "no pre-existing local platform state"

# Pre-existing remote state -------------------------------------------------
if m1_object_exists "$M1_PLATFORM_KEY"; then
  snapshot="$M1_EVIDENCE_DIR/state/platform-pre-existing-$M1_RUN_TAG.tfstate"
  if oci os object get --bucket-name "$M1_TF_STATE_BUCKET" --name "$M1_PLATFORM_KEY" \
       --file "$snapshot" "${M1_OCI_REGION_ARGS[@]}" >/dev/null 2>&1 && [[ -s "$snapshot" ]]; then
    chmod 600 "$snapshot"
    read -r live_lineage live_serial <<<"$(m1_state_meta "$snapshot")"
    m1_evidence_record "existing platform state snapshot saved lineage=$live_lineage serial=$live_serial"
    # Not env-var-only: the operator must also present a written acknowledgement
    # record naming the live lineage after reviewing the snapshot.
    ack_record="${M1_EXISTING_STATE_ACK:-}"
    if [[ "${M1_ALLOW_EXISTING_STATE:-}" == "$live_lineage" && -n "$ack_record" ]] \
       && m1_verify_approval_record "$ack_record" "PLATFORM-INIT-EXISTING-STATE" "$live_lineage"; then
      m1_check PASS "platform-key" "existing state acknowledged by operator record: $live_lineage serial=$live_serial (no migration flags used)"
    else
      fail_gate platform-key \
        "$M1_PLATFORM_KEY already exists (lineage=$live_lineage serial=$live_serial). Snapshot saved to $snapshot. After operator review, re-run with M1_ALLOW_EXISTING_STATE=$live_lineage and M1_EXISTING_STATE_ACK=<record file naming GATE: PLATFORM-INIT-EXISTING-STATE and that lineage>"
    fi
  else
    fail_gate platform-key "$M1_PLATFORM_KEY exists but could not be snapshotted — refusing to init"
  fi
else
  m1_check PASS "platform-key" "$M1_PLATFORM_KEY absent — fresh platform state"
fi

# Init (plain; never -migrate-state / -reconfigure / -force-copy) -----------
for flag in -migrate-state -reconfigure -force-copy; do
  for arg in "$@"; do
    [[ "$arg" == "$flag" ]] && fail_gate init-flags "$flag is never permitted"
  done
done

init_log="$M1_EVIDENCE_DIR/logs/platform-init.log"
if "$M1_TERRAFORM_BIN" -chdir="$root" init -input=false -backend-config="$backend_hcl" >"$init_log" 2>&1; then
  m1_check PASS "platform-init" "backend initialized (log preserved)"
else
  tail -40 "$init_log" >&2
  fail_gate platform-init "init failed — inspect $init_log; do not retry before root cause"
fi

# Post-init verification -----------------------------------------------------
m1_verify_workspace_default "$M1_TERRAFORM_BIN" "$root" \
  && m1_check PASS "workspace-default" "workspace is default" \
  || fail_gate workspace-default "non-default workspace"
if m1_object_exists "$M1_PLATFORM_KEY"; then
  m1_check FAIL "init-wrote-nothing" "init unexpectedly created $M1_PLATFORM_KEY"
  m1_exit_gate_failed
else
  m1_check PASS "init-wrote-nothing" "no remote state object written by init"
fi

count="$("$M1_TERRAFORM_BIN" -chdir="$root" state list 2>/dev/null | grep -c . || true)"
[[ "${count:-0}" -eq 0 ]] \
  && m1_check PASS "state-empty" "platform state has no addresses" \
  || fail_gate state-empty "platform state unexpectedly holds $count addresses"

m1_evidence_record "platform init complete PASS=$m1_pass_count FAIL=$m1_fail_count"
echo "Platform init complete — evidence in $M1_EVIDENCE_DIR"
