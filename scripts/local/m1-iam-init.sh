#!/usr/bin/env bash
# M1-LOCAL IAM backend init — guarded (MYSQL-NSG-IAM track).
# Initializes infra/iam against the remote OCI backend. The iam/ state key is
# expected to be ABSENT: this root has never held state and must never adopt
# foreign state. Unlike the platform init there is NO acknowledgement override:
# an existing iam/ state object or a live lock object is an ownership conflict
# that stops the run for a documented operator reconciliation (no migration,
# no reconfiguration, no force-unlock — ever).
set -uo pipefail

# shellcheck source=scripts/local/lib-m1.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-m1.sh"

m1_init_evidence
m1_evidence_record "iam init start (run $M1_RUN_TAG)"

root="$M1_REPO_ROOT/infra/iam"
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
m1_verify_backend_config "$backend_hcl" "$M1_IAM_KEY" \
  && m1_check PASS "backend-config" "$backend_hcl matches approved coordinates" \
  || fail_gate backend-config "unexpected backend coordinates"

# Pre-existing local state -------------------------------------------------
if [[ -f "$root/terraform.tfstate" || -f "$root/terraform.tfstate.backup" ]]; then
  fail_gate local-state "pre-existing local iam state present at $root — operator must review before any init"
fi
m1_check PASS "local-state" "no pre-existing local iam state"

# State-key ownership: absence must be PROVEN (fail closed against
# authorization/service errors, historical versions, delete markers), and no
# live lock may sit under iam/.
if m1_prove_state_key_absent "$M1_IAM_KEY"; then
  m1_check PASS "iam-key" "$M1_IAM_KEY absence proven — unowned, fresh root"
else
  fail_gate iam-key "$M1_IAM_KEY absence could not be proven — the key exists, has history, or the listing failed (details above); STOP and reconcile"
fi
m1_verify_no_lock_objects "iam/" \
  && m1_check PASS "no-locks" "no live lock objects under iam/" \
  || fail_gate no-locks "stale or live lock objects under iam/"

# Init (plain; never -migrate-state / -reconfigure / -force-copy) -----------
for flag in -migrate-state -reconfigure -force-copy; do
  for arg in "$@"; do
    [[ "$arg" == "$flag" ]] && fail_gate init-flags "$flag is never permitted"
  done
done

init_log="$M1_EVIDENCE_DIR/logs/iam-init.log"
if "$M1_TERRAFORM_BIN" -chdir="$root" init -input=false -backend-config="$backend_hcl" >"$init_log" 2>&1; then
  m1_check PASS "iam-init" "backend initialized (log preserved)"
else
  tail -40 "$init_log" >&2
  fail_gate iam-init "init failed — inspect $init_log; do not retry before root cause"
fi

# Post-init verification -----------------------------------------------------
m1_verify_workspace_default "$M1_TERRAFORM_BIN" "$root" \
  && m1_check PASS "workspace-default" "workspace is default" \
  || fail_gate workspace-default "non-default workspace"
if m1_prove_state_key_absent "$M1_IAM_KEY"; then
  m1_check PASS "init-wrote-nothing" "no remote state object written by init (absence re-proven)"
else
  m1_check FAIL "init-wrote-nothing" "init unexpectedly created state or history under $M1_IAM_KEY"
  m1_exit_gate_failed
fi

count="$("$M1_TERRAFORM_BIN" -chdir="$root" state list 2>/dev/null | grep -c . || true)"
[[ "${count:-0}" -eq 0 ]] \
  && m1_check PASS "state-empty" "iam state has no addresses" \
  || fail_gate state-empty "iam state unexpectedly holds $count addresses"

m1_evidence_record "iam init complete PASS=$m1_pass_count FAIL=$m1_fail_count"
echo "IAM init complete — evidence in $M1_EVIDENCE_DIR"
