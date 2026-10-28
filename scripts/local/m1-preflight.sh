#!/usr/bin/env bash
# M1-LOCAL Phase 0 preflight — READ-ONLY.
# Establishes the local deployment baseline: pinned Terraform, API-key auth,
# bucket/CMK health, bootstrap remote-state readability, lock absence,
# repository hygiene, and dormant GitHub WIF workflows.
# It never writes a remote object, lock, plan, or resource.
set -uo pipefail

# shellcheck source=scripts/local/lib-m1.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-m1.sh"

m1_init_evidence
m1_evidence_record "preflight start (run $M1_RUN_TAG)"

operator="${M1_OPERATOR_NAME:-$(git -C "$M1_REPO_ROOT" config user.name)}"
commit="$(git -C "$M1_REPO_ROOT" rev-parse HEAD)"
dirty="$(git -C "$M1_REPO_ROOT" status --porcelain | wc -l | tr -d ' ')"
m1_evidence_record "operator=$operator commit=$commit dirty_files=$dirty"

oci_user_json="$(mktemp)"
trap 'rm -f "$oci_user_json"' EXIT

fail_gate() { # preserve evidence, then fail closed
  local name="$1"; shift
  m1_check FAIL "$name" "$*"
  m1_evidence_record "GATE FAIL: $name"
  m1_exit_gate_failed
}

# 1. Tools ------------------------------------------------------------
m1_verify_terraform_bin \
  && m1_check PASS "terraform-pinned" "$M1_TERRAFORM_BIN = v$M1_TERRAFORM_VERSION" \
  || fail_gate "terraform-pinned" "missing or wrong version"

command -v oci >/dev/null 2>&1 \
  && m1_check PASS "oci-cli" "$(oci --version 2>/dev/null)" \
  || fail_gate "oci-cli" "not installed"
command -v jq >/dev/null 2>&1 \
  && m1_check PASS "jq" "present" \
  || fail_gate "jq" "not installed"

# 2. Authentication ----------------------------------------------------
m1_verify_auth_mode \
  && m1_check PASS "auth-apikey-profile" "API-key profile $M1_OCI_PROFILE selected; no conflicting auth mode" \
  || fail_gate "auth-apikey-profile" "authentication mode invalid"

namespace="$(oci os ns get "${M1_OCI_REGION_ARGS[@]}" 2>/dev/null | jq -r '.data')" || namespace=""
[[ "$namespace" == "$M1_OCI_NAMESPACE" ]] \
  && m1_check PASS "namespace" "$namespace" \
  || fail_gate "namespace" "expected $M1_OCI_NAMESPACE, got ${namespace:-<auth failure>}"

oci iam user get --user-id "$(awk -F= '/^user=/{print $2; exit}' "$(m1_oci_config_file)")" > "$oci_user_json" 2>/dev/null \
  && m1_check PASS "operator-identity" "$(jq -r '.data.name + " " + .data.id' "$oci_user_json")" \
  || fail_gate "operator-identity" "cannot read operator user"

# 3. State bucket ------------------------------------------------------
m1_verify_bucket_preconditions \
  && m1_check PASS "state-bucket" "$M1_TF_STATE_BUCKET private/versioned/CMK-bound" \
  || fail_gate "state-bucket" "preconditions failed"
m1_verify_cmk_enabled \
  && m1_check PASS "cmk-enabled" "$M1_EXPECTED_KMS_KEY_ID" \
  || fail_gate "cmk-enabled" "state CMK not ENABLED"

# 4. Bootstrap remote state -------------------------------------------
bootstrap_pull="$M1_EVIDENCE_DIR/state/bootstrap-phase0-pull.tfstate"
if "$M1_TERRAFORM_BIN" -chdir="$M1_REPO_ROOT/infra/bootstrap" state pull > "$bootstrap_pull" 2>"$M1_EVIDENCE_DIR/logs/bootstrap-pull.err" \
   && [[ -s "$bootstrap_pull" ]]; then
  read -r lineage serial <<<"$(m1_state_meta "$bootstrap_pull")"
else
  lineage=""; serial=""
fi
[[ "$lineage" == "$M1_BOOTSTRAP_LINEAGE" ]] \
  && m1_check PASS "bootstrap-lineage" "$lineage serial=$serial" \
  || fail_gate "bootstrap-lineage" "expected $M1_BOOTSTRAP_LINEAGE, got ${lineage:-<unreadable>}"

addresses="$("$M1_TERRAFORM_BIN" -chdir="$M1_REPO_ROOT/infra/bootstrap" state list 2>/dev/null)" || addresses=""
count="$(grep -c . <<<"$addresses")"
expected_addresses="$(cat <<'EOF'
oci_identity_dynamic_group.eventforge_instances
oci_identity_policy.eventforge_instance_backups
oci_identity_policy.objectstorage_kms
oci_objectstorage_bucket.backups
oci_objectstorage_bucket.terraform_state
oci_objectstorage_object_lifecycle_policy.terraform_state_versions
oci_ons_notification_topic.operations
oci_ons_subscription.operations_email
EOF
)"
[[ "$count" -eq "$M1_BOOTSTRAP_ADDRESSES" && "$addresses" == "$expected_addresses" ]] \
  && m1_check PASS "bootstrap-addresses" "$count expected addresses" \
  || fail_gate "bootstrap-addresses" "expected $M1_BOOTSTRAP_ADDRESSES known addresses, got $count"
printf '%s\n' "$addresses" > "$M1_EVIDENCE_DIR/state/bootstrap-phase0-addresses.txt"

# 5. Locks and writers --------------------------------------------------
for prefix in "$M1_BOOTSTRAP_KEY" "$M1_PLATFORM_KEY" "$M1_FRONTEND_KEY"; do
  dir_prefix="${prefix%/*}/"
  m1_verify_no_lock_objects "$dir_prefix" \
    && m1_check PASS "no-locks" "$dir_prefix" \
    || fail_gate "no-locks" "$dir_prefix has lock objects"
done
if pgrep -x terraform >/dev/null 2>&1; then
  fail_gate "no-terraform-writers" "a terraform process is running"
else
  m1_check PASS "no-terraform-writers" "no live terraform process"
fi

# 6. Platform state-key ownership ---------------------------------------
# Presence is classified; a failed or ambiguous probe is never recorded as
# "absent" and fails the preflight.
platform_key_status="$(m1_state_key_status "$M1_PLATFORM_KEY")"
case "$platform_key_status" in
  exists)
    m1_check FAIL "platform-key" "$M1_PLATFORM_KEY already exists — Phase 3 init requires the operator snapshot decision"
    ;;
  absent)
    m1_check PASS "platform-key" "$M1_PLATFORM_KEY authoritatively absent (fresh platform state expected)"
    ;;
  *)
    m1_check FAIL "platform-key" \
      "$M1_PLATFORM_KEY presence UNKNOWN (OCI probe classified: $platform_key_status) — a failed or ambiguous response is never treated as absence"
    ;;
esac

# 7. Repository hygiene --------------------------------------------------
m1_refuse_tracked_sensitive_files "$M1_REPO_ROOT" \
  && m1_check PASS "repo-hygiene" "no credentials/state in tracked files" \
  || fail_gate "repo-hygiene" "tracked sensitive content found"

# 8. Dormant GitHub WIF workflows ----------------------------------------
m1_verify_workflows_dormant "$M1_REPO_ROOT/.github/workflows" \
  && m1_check PASS "wif-workflows-dormant" "infrastructure workflows dispatch-only" \
  || fail_gate "wif-workflows-dormant" "workflow trigger drift detected"

# 9. Record ---------------------------------------------------------------
m1_evidence_record "preflight PASS checks=$m1_pass_count FAIL=$m1_fail_count"
jq -n \
  --arg run_tag "$M1_RUN_TAG" \
  --arg operator "$operator" \
  --arg operator_ocid "$(jq -r '.data.id' "$oci_user_json")" \
  --arg commit "$commit" \
  --arg lineage "$lineage" \
  --arg platform_key_state "$platform_key_status" \
  --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{deployment_mode:"LOCAL_OPERATOR", oci_federation:"DEFERRED", github_stage_2_iam:"DEFERRED",
    run_tag:$run_tag, operator:{name:$operator, ocid:$operator_ocid}, commit:$commit,
    terraform_version:$tv, region:$region, bucket:$bucket, bootstrap_lineage:$lineage,
    platform_state_key:$platform_key_state, timestamp:$timestamp,
    pass_checks:$p, fail_checks:$f}' \
  --arg tv "$M1_TERRAFORM_VERSION" --arg region "$M1_OCI_REGION" --arg bucket "$M1_TF_STATE_BUCKET" \
  --argjson p "$m1_pass_count" --argjson f "$m1_fail_count" \
  > "$M1_EVIDENCE_DIR/preflight-baseline.json"

echo "Preflight PASS — evidence in $M1_EVIDENCE_DIR"
