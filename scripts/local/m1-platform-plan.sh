#!/usr/bin/env bash
# M1-LOCAL platform plan — guarded, evidence-producing, never applied here.
# Operates only on infra/platform. Produces in the protected evidence dir:
#   1. saved plan (.tfplan, mode 0600 — plans may carry sensitive values)
#   2. JSON plan
#   3. non-sensitive address/action summary
#   4. plan SHA-256
#   5. source commit SHA
#   6. state lineage/serial metadata at plan time
#   7. safe-plan policy result
#   8. explicit list of proposed existing-resource updates
# The apply script consumes exactly this plan+metadata pair and rejects mismatches.
set -uo pipefail

# shellcheck source=scripts/local/lib-m1.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-m1.sh"

m1_init_evidence
m1_evidence_record "platform plan start (run $M1_RUN_TAG)"

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
m1_verify_refreshing_plan "$@" \
  && m1_check PASS "refreshing-plan" "normal refreshing plan (no -refresh=false / -refresh-only)" \
  || fail_gate refreshing-plan "a reviewed plan must reflect live state"
m1_verify_no_recovery_invocation "$@" \
  && m1_check PASS "no-state-recovery" "none" \
  || fail_gate no-state-recovery "recovery invocation refused"

# M1-LOCAL never enables API ingress. Refuse any input file or TF_VAR that
# sets enable_api_ingress=true before touching live coordinates; the plan
# scan below additionally rejects any plan that proposes ingress resources.
ingress_inputs=""
for f in "$root/terraform.auto.tfvars" "$root/imported.auto.tfvars" "$root/terraform.tfvars" "$root"/*.tfvars.local; do
  [[ -f "$f" ]] || continue
  grep -Eq '^[[:space:]]*enable_api_ingress[[:space:]]*=[[:space:]]*true' "$f" && ingress_inputs+="$(basename "$f") "
done
if [[ -n "$ingress_inputs" || "${TF_VAR_enable_api_ingress:-}" == true ]]; then
  fail_gate api-ingress-disabled \
    "enable_api_ingress=true is refused by M1-LOCAL scripts (inputs: ${ingress_inputs:-TF_VAR_enable_api_ingress}); ingress enablement is a separately reviewed future gate"
fi
m1_check PASS "api-ingress-disabled" "enable_api_ingress=false in all consumed inputs"
m1_verify_bucket_preconditions \
  && m1_check PASS "state-bucket" "private/versioned/CMK-bound" \
  || fail_gate state-bucket "preconditions failed"
m1_verify_cmk_enabled \
  && m1_check PASS "cmk-enabled" "ENABLED" \
  || fail_gate cmk-enabled "CMK not ENABLED"
m1_verify_backend_config "$backend_hcl" "$M1_PLATFORM_KEY" \
  && m1_check PASS "backend-config" "coordinates approved" \
  || fail_gate backend-config "unexpected backend coordinates"

[[ -d "$root/.terraform" ]] \
  && m1_check PASS "platform-initialized" "provider/backend present" \
  || fail_gate platform-initialized "run m1-platform-init.sh first"
m1_verify_workspace_default "$M1_TERRAFORM_BIN" "$root" \
  && m1_check PASS "workspace-default" "default" \
  || fail_gate workspace-default "non-default workspace"
m1_verify_no_lock_objects "platform/" \
  && m1_check PASS "no-locks" "no remote lock objects" \
  || fail_gate no-locks "stale or live lock objects under platform/"

commit="$(git -C "$M1_REPO_ROOT" rev-parse HEAD)"
operator="$(git -C "$M1_REPO_ROOT" config user.name)"

# Pre-plan protected state snapshot -----------------------------------------
pre_pull="$M1_EVIDENCE_DIR/state/platform-pre-plan.tfstate"
platform_key_status="$(m1_state_key_status "$M1_PLATFORM_KEY")"
case "$platform_key_status" in
  exists)
    if "$M1_TERRAFORM_BIN" -chdir="$root" state pull > "$pre_pull" 2>"$M1_EVIDENCE_DIR/logs/pre-plan-pull.err" && [[ -s "$pre_pull" ]]; then
      read -r state_lineage state_serial <<<"$(m1_state_meta "$pre_pull")"
      m1_check PASS "pre-plan-snapshot" "remote state lineage=$state_lineage serial=$state_serial"
    else
      fail_gate pre-plan-snapshot "could not pull platform state before planning"
    fi
    ;;
  absent)
    state_lineage=""; state_serial="0"
    m1_check FAIL "pre-plan-snapshot" "$M1_PLATFORM_KEY authoritatively absent — import flow must run before a platform plan"
    m1_exit_gate_failed
    ;;
  *)
    m1_check FAIL "pre-plan-snapshot" \
      "$M1_PLATFORM_KEY presence UNKNOWN (OCI probe classified: $platform_key_status) — a failed or ambiguous response is never treated as absence"
    m1_exit_gate_failed
    ;;
esac

# Plan -----------------------------------------------------------------------
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
plan_file="$M1_EVIDENCE_DIR/plans/platform-$stamp.tfplan"
plan_json="$M1_EVIDENCE_DIR/plans/platform-$stamp.json"
plan_log="$M1_EVIDENCE_DIR/logs/platform-plan.log"

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
"$M1_TERRAFORM_BIN" -chdir="$root" show -json "$plan_file" > "$plan_json" 2>"$M1_EVIDENCE_DIR/logs/platform-show.err" \
  && m1_check PASS "plan-json" "JSON representation written (0600 — JSON plans carry sensitive values)" \
  || fail_gate plan-json "could not render plan JSON"
chmod 600 "$plan_json"
chmod 600 "$pre_pull" 2>/dev/null || true

plan_sha="$(shasum -a 256 "$plan_file" | awk '{print $1}')"
m1_plan_action_summary "$plan_json" > "$M1_EVIDENCE_DIR/plans/platform-$stamp.actions.txt"
m1_plan_import_updates "$plan_json" "$M1_REPO_ROOT/$M1_SAFE_PLAN_POLICY" > "$M1_EVIDENCE_DIR/plans/platform-$stamp.import-updates.txt" || true

# Safe-plan policy -------------------------------------------------------------
if m1_run_safe_plan_policy "$plan_json" >"$M1_EVIDENCE_DIR/logs/safe-plan.log" 2>&1; then
  safe_plan="PASS"
  m1_check PASS "safe-plan-policy" "plan matches reviewed policy"
else
  safe_plan="FAIL"
  m1_check FAIL "safe-plan-policy" "plan violates the reviewed policy — gate stops"
  cat "$M1_EVIDENCE_DIR/logs/safe-plan.log" >&2
fi

# Attribute-level enforcement at plan time: any selected policy that carries
# expected attribute values (the dedicated retest and SSH-source-update
# policies) is checked by BOTH the address-level checker above and the
# attribute-level scope-A checker here, so a reviewed plan is authorized at
# attribute granularity before it is ever saved; the apply path rechecks the
# saved plan independently under its own approval gate.
attr_gate="attribute-check"
[[ "$M1_SAFE_PLAN_POLICY" == "$M1_MYSQL_RETEST_POLICY" ]] && attr_gate="retest-attribute-check"
if jq -e '.allow[0].expected_attribute_values' "$M1_REPO_ROOT/$M1_SAFE_PLAN_POLICY" >/dev/null 2>&1; then
  if "$M1_REPO_ROOT/scripts/ci/assert-safe-plan-scope-a.sh" \
       --policy "$M1_REPO_ROOT/$M1_SAFE_PLAN_POLICY" "$plan_json" \
       >"$M1_EVIDENCE_DIR/logs/attribute-check.log" 2>&1; then
    m1_check PASS "$attr_gate" "attribute-level policy PASS at plan time ($M1_SAFE_PLAN_POLICY)"
  else
    safe_plan="FAIL"
    m1_check FAIL "$attr_gate" "plan violates the attribute-level policy — gate stops"
    cat "$M1_EVIDENCE_DIR/logs/attribute-check.log" >&2
  fi
fi

import_updates="$(grep -c . "$M1_EVIDENCE_DIR/plans/platform-$stamp.import-updates.txt" || true)"
m1_check PASS "import-updates-listed" "$import_updates proposed existing-resource update(s) recorded"

# Defense in depth: even if an input slipped past the input guard above, a
# plan proposing API-ingress resources is refused — this track never deploys
# listeners, backends, certificates, or DNS records.
ingress_creates="$(jq -r '
  [.resource_changes[]?
   | select(.change.actions | index("create"))
   | .address
   | select(test("^(oci_load_balancer_(listener|backend_set|backend|certificate)|cloudflare_dns_record|cloudflare_ruleset|tls_private_key|tls_cert_request|cloudflare_origin_ca_certificate)"))]
  | join(",")' "$plan_json")"
[[ -z "$ingress_creates" ]] \
  && m1_check PASS "no-ingress-creates" "plan proposes no API-ingress resources" \
  || fail_gate no-ingress-creates "API-ingress resources refused by M1-LOCAL: $ingress_creates"

# Metadata (the reviewed contract consumed by m1-platform-apply.sh) -------------
changes_total="$(grep -c . "$M1_EVIDENCE_DIR/plans/platform-$stamp.actions.txt" || true)"
# Policy-content integrity binding: the metadata records the SHA-256 of the
# EXACT policy file that authorized this plan at plan time; the apply gate
# requires byte equality (and a committed working tree) before revalidating
# the saved plan against it — an edited or substituted policy can never
# silently re-authorize a saved plan.
policy_sha="$(shasum -a 256 "$M1_REPO_ROOT/$M1_SAFE_PLAN_POLICY" | awk '{print $1}')"
jq -n \
  --arg run_tag "$M1_RUN_TAG" --arg commit "$commit" --arg operator "$operator" \
  --arg plan "$plan_file" --arg plan_json "$plan_json" --arg plan_sha "$plan_sha" \
  --arg lineage "$state_lineage" --argjson serial "$state_serial" \
  --arg safe_plan "$safe_plan" --argjson import_updates "$import_updates" --argjson changes "$changes_total" \
  --arg safe_plan_policy "$M1_SAFE_PLAN_POLICY" --arg policy_sha "$policy_sha" \
  --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{plan:$plan, plan_json:$plan_json, plan_sha256:$plan_sha, commit:$commit, operator:$operator,
    state_lineage:$lineage, state_serial:$serial, safe_plan:$safe_plan,
    safe_plan_policy:$safe_plan_policy, safe_plan_policy_sha256:$policy_sha,
    proposed_import_updates:$import_updates, non_noop_changes:$changes,
    terraform_version:$tv, bucket:$bucket, state_key:$key,
    applied:false, apply_evidence:null, timestamp:$timestamp}' \
  --arg tv "$M1_TERRAFORM_VERSION" --arg bucket "$M1_TF_STATE_BUCKET" --arg key "$M1_PLATFORM_KEY" \
  > "$M1_EVIDENCE_DIR/plans/platform-$stamp.metadata.json"

[[ "$safe_plan" == "PASS" ]] \
  && m1_evidence_record "plan complete safe_plan=PASS changes=$changes_total import_updates=$import_updates" \
  || m1_evidence_record "plan complete safe_plan=FAIL changes=$changes_total"

echo "Plan artifacts in $M1_EVIDENCE_DIR/plans/ (safe_plan=$safe_plan, changes=$changes_total)"
[[ "$safe_plan" == "PASS" ]]
