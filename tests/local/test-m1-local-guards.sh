#!/usr/bin/env bash
# Offline tests for the M1-LOCAL guard library and script contracts.
# Never contacts OCI or Cloudflare and never runs real terraform operations;
# external calls are satisfied with stubs.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
lib="$repo_root/scripts/local/lib-m1.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail() { echo "TEST FAIL: $1" >&2; exit 1; }

# Load the library in a scratch environment (repo-root detection stays real;
# evidence writes are redirected into the scratch dir).
export M1_EVIDENCE_DIR="$work/evidence"
export M1_EVIDENCE_ROOT="$work/evidence-root"
# shellcheck source=scripts/local/lib-m1.sh
source "$lib"

# ------------------------------------------------------------- terraform pin
stub_tf() { # stub_tf <version-string>
  local dir="$work/tf-$1" bin
  mkdir -p "$dir"
  bin="$dir/terraform"
  printf '#!/bin/sh\necho "Terraform v%s"\necho "on darwin_arm64"\n' "$1" > "$bin"
  chmod +x "$bin"
  printf '%s' "$bin"
}
tf_ok="$(stub_tf "1.12.2")"
tf_bad="$(stub_tf "1.13.1")"
m1_verify_terraform_bin "$tf_ok" || fail "pinned terraform 1.12.2 must be accepted"
if m1_verify_terraform_bin "$tf_bad" 2>/dev/null; then fail "terraform 1.13.1 must be rejected"; fi
if m1_verify_terraform_bin "$work/absent" 2>/dev/null; then fail "missing terraform must be rejected"; fi
echo "ok: pinned terraform"

# ------------------------------------------------------------- auth modes
fake_config="$work/oci-config"
cat > "$fake_config" <<EOF
[DEFAULT]
user=ocid1.user.oc1..test
fingerprint=aa:bb
tenancy=ocid1.tenancy.oc1..test
region=ap-hyderabad-1
key_file=$work/test.pem
EOF
if OCI_CLI_CONFIG="$fake_config" OCI_RESOURCE_PRINCIPAL_VERSION=1 m1_verify_auth_mode 2>/dev/null; then
  fail "resource-principal env must be rejected"
fi
if OCI_CLI_CONFIG="$fake_config" OCI_CLI_AUTH=instance_principal m1_verify_auth_mode 2>/dev/null; then
  fail "instance-principal auth must be rejected"
fi
if OCI_CLI_CONFIG="$fake_config" OCI_PROFILE=OTHER m1_verify_auth_mode 2>/dev/null; then
  fail "conflicting profile must be rejected"
fi
OCI_CLI_CONFIG="$fake_config" m1_verify_auth_mode || fail "clean API-key DEFAULT config must be accepted"
printf '[DEFAULT]\n' > "$work/empty-config"
if OCI_CLI_CONFIG="$work/nope" m1_verify_auth_mode 2>/dev/null; then fail "missing config must be rejected"; fi
echo "ok: auth-mode guards"

# ------------------------------------------------------------- locking retained
M1_TEST_ENV=() m1_verify_locking_retained -lock=true plan || fail "-lock=true must be accepted"
if TF_CLI_ARGS_apply="-lock=false" m1_verify_locking_retained 2>/dev/null; then
  fail "TF_CLI_ARGS -lock=false must be rejected"
fi
if m1_verify_locking_retained "-lock=false" 2>/dev/null; then fail "explicit -lock=false arg must be rejected"; fi
m1_verify_locking_retained || fail "clean environment must pass"
echo "ok: locking guards"

# ------------------------------------------------------------- recovery refusal
if m1_verify_no_recovery_invocation "state push -force /tmp/x" 2>/dev/null; then
  fail "state push must be refused"
fi
if m1_verify_no_recovery_invocation "terraform force-unlock 1234" 2>/dev/null; then
  fail "force-unlock must be refused"
fi
m1_verify_no_recovery_invocation "plan -out=x" || fail "normal args must pass recovery guard"
echo "ok: recovery guards"

# ------------------------------------------------------------- backend config
good_backend="$work/backend-good.hcl"
cat > "$good_backend" <<'EOF'
bucket    = "eventforge-tfstate-prod"
namespace = "axrq1dasyz3y"
key       = "platform/terraform.tfstate"
region    = "ap-hyderabad-1"
auth      = "APIKey"
config_file_profile = "DEFAULT"
EOF
m1_verify_backend_config "$good_backend" "platform/terraform.tfstate" || fail "correct backend.hcl must pass"
sed 's|platform/terraform.tfstate|other/terraform.tfstate|' "$good_backend" > "$work/backend-bad-key.hcl"
if m1_verify_backend_config "$work/backend-bad-key.hcl" "platform/terraform.tfstate" 2>/dev/null; then
  fail "wrong state key must be rejected"
fi
sed 's|ap-hyderabad-1|ap-mumbai-1|' "$good_backend" > "$work/backend-bad-region.hcl"
if m1_verify_backend_config "$work/backend-bad-region.hcl" "platform/terraform.tfstate" 2>/dev/null; then
  fail "wrong region must be rejected"
fi
echo "ok: backend config guards"

# ------------------------------------------------------------- tracked sensitive files
scratch_repo="$work/repo"
git init -q "$scratch_repo"
mkdir -p "$scratch_repo/infra/platform"
touch "$scratch_repo/infra/platform/backend.hcl"
(cd "$scratch_repo" && git add infra/platform/backend.hcl)
if m1_refuse_tracked_sensitive_files "$scratch_repo" 2>/dev/null; then
  fail "tracked backend.hcl must be rejected"
fi
git -C "$scratch_repo" rm -q --cached infra/platform/backend.hcl
rm -f "$scratch_repo/infra/platform/backend.hcl"
touch "$scratch_repo/infra/platform/imported.auto.tfvars"
(cd "$scratch_repo" && git add infra/platform/imported.auto.tfvars)
if m1_refuse_tracked_sensitive_files "$scratch_repo" 2>/dev/null; then
  fail "tracked imported.auto.tfvars (live discovery values) must be rejected"
fi
rm "$scratch_repo/infra/platform/imported.auto.tfvars"
# Synthetic marker built by concatenation: a real key literal here would trip
# the repo-wide tracked-secret scan in scripts/acceptance/run.sh.
# Synthetic key built by concatenation so no tracked line contains a
# real key literal (scripts/acceptance/run.sh scans tracked content):
fixture_key="-----BEGIN RSA PRIVATE KE"
printf -- '%sY-----\nabc\n%sY-----\n' "$fixture_key" "$fixture_key" > "$scratch_repo/secret.tfvars"
(cd "$scratch_repo" && git add secret.tfvars && git -c user.email=t@t -c user.name=t commit -qm x)
if m1_refuse_tracked_sensitive_files "$scratch_repo" 2>/dev/null; then :; else
  : # handled below; the private-key scan must reject regardless of extension
fi
m1_refuse_tracked_sensitive_files "$scratch_repo" 2>/dev/null && fail "tracked private key material must be rejected"
rm "$scratch_repo/secret.tfvars"
(cd "$scratch_repo" && git add -A && git -c user.email=t@t -c user.name=t commit -qm y)
m1_refuse_tracked_sensitive_files "$scratch_repo" || fail "clean repo must pass hygiene"
echo "ok: repo hygiene guards"

# ------------------------------------------------------------- dormant workflows
wf_dir="$work/workflows"
mkdir -p "$wf_dir"
for wf in terraform-plan.yml terraform-apply.yml frontend.yml oci-preflight.yml \
          oci-backend-validation.yml oci-wif-exchange-probe.yml oidc-claim-inspection.yml; do
  printf 'name: %s\non:\n  workflow_dispatch:\njobs: {}\n' "${wf%.yml}" > "$wf_dir/$wf"
done
m1_verify_workflows_dormant "$wf_dir" || fail "dispatch-only workflows must pass"
printf 'name: x\non:\n  push:\n  workflow_dispatch:\njobs: {}\n' > "$wf_dir/terraform-apply.yml"
if m1_verify_workflows_dormant "$wf_dir" 2>/dev/null; then
  fail "auto-firing terraform-apply trigger must be rejected"
fi
printf 'name: x\non:\n  schedule:\n    - cron: "0 * * * *"\njobs: {}\n' > "$wf_dir/terraform-plan.yml"
if m1_verify_workflows_dormant "$wf_dir" 2>/dev/null; then
  fail "scheduled terraform-plan trigger must be rejected"
fi
m1_verify_workflows_dormant "$repo_root/.github/workflows" || fail "real repo workflows must stay dormant"
echo "ok: dormant workflow guards"

# ------------------------------------------------------------- plan summaries / metadata
policy="$repo_root/scripts/ci/platform-safe-plan-policy.json"
plan="$work/plan.json"
cat > "$plan" <<'EOF'
{"resource_changes":[
  {"address":"oci_core_network_security_group.lb","type":"oci_core_network_security_group",
   "change":{"actions":["create"],"after":{"display_name":"eventforge-lb-nsg"},"after_unknown":{}}},
  {"address":"oci_core_vcn.existing","type":"oci_core_vcn",
   "change":{"actions":["update"],"after":{},"after_unknown":{}}},
  {"address":"oci_core_subnet.app","type":"oci_core_subnet",
   "change":{"actions":["no-op"],"after":{},"after_unknown":{}}}
]}
EOF
summary="$(m1_plan_action_summary "$plan")"
[[ "$(grep -c . <<<"$summary")" -eq 2 ]] || fail "action summary must list exactly the 2 non-no-op changes"
grep -q 'oci_core_vcn.existing	update' <<<"$summary" || fail "action summary must include the vcn update"
updates="$(m1_plan_import_updates "$plan" "$policy")"
grep -q '^oci_core_vcn.existing' <<<"$updates" || fail "import-updates list must include the protected vcn update"
[[ "$(grep -c . <<<"$updates")" -eq 1 ]] || fail "import-updates list must not contain the new NSG create"
grep -q 'display_name' <<<"$summary" && fail "summary must never contain attribute values"
echo "ok: plan summary guards"

# ------------------------------------------------------------- state metadata
printf '{"lineage":"abc-123","serial":7,"outputs":{}}' > "$work/state.json"
read -r lineage serial <<<"$(m1_state_meta "$work/state.json")"
[[ "$lineage" == "abc-123" && "$serial" == "7" ]] || fail "state metadata extraction"
echo "ok: state metadata"

# ------------------------------------------------------------- approval records
record="$work/record.md"
cat > "$record" <<'EOF'
GATE: OCI-IMPORT
APPROVER: test-operator
COMMIT: deadbeef
- oci_core_vcn.existing
- oci_mysql_mysql_db_system.existing
EOF
m1_verify_approval_record "$record" "OCI-IMPORT" "deadbeef" "oci_core_vcn.existing" \
  || fail "complete approval record must pass"
if m1_verify_approval_record "$work/missing.md" "OCI-IMPORT" 2>/dev/null; then
  fail "missing approval record must be refused"
fi
grep -v 'COMMIT' "$record" > "$work/record-nocommit.md"
if m1_verify_approval_record "$work/record-nocommit.md" "OCI-IMPORT" "deadbeef" 2>/dev/null; then
  fail "record lacking a required binding must be refused"
fi
if m1_verify_approval_record "$record" "PLATFORM-APPLY" "deadbeef" 2>/dev/null; then
  fail "record with wrong gate marker must be refused"
fi
printf 'GATE: X\n' > "$work/record-noapprover.md"
if m1_verify_approval_record "$work/record-noapprover.md" "X" 2>/dev/null; then
  fail "record lacking APPROVER must be refused"
fi
echo "ok: approval record guards"

# ------------------------------------------------------------- script contracts
for script in m1-preflight.sh m1-platform-init.sh m1-platform-plan.sh m1-platform-apply.sh \
              m1-verify.sh m1-oci-inventory.sh m1-platform-imports.sh; do
  [[ -x "$repo_root/scripts/local/$script" ]] || fail "$script must be executable"
  bash -n "$repo_root/scripts/local/$script" || fail "$script must parse"
done
if grep -q -- '-auto-approve' "$repo_root/scripts/local/m1-platform-apply.sh"; then
  grep -q -- '-auto-approve is prohibited' "$repo_root/scripts/local/m1-platform-apply.sh" \
    || fail "apply must actively reject -auto-approve"
fi
if grep -Eq -- '-migrate-state|-reconfigure|-force-copy' "$repo_root/scripts/local/m1-platform-init.sh" \
   && ! grep -q 'never permitted' "$repo_root/scripts/local/m1-platform-init.sh"; then
  fail "init migration flags must be actively refused"
fi
grep -q 'state push' "$repo_root/scripts/local/m1-platform-apply.sh" \
  && grep -q 'force-unlock' "$repo_root/scripts/local/m1-platform-apply.sh" \
  && fail "apply must not reference state-recovery commands" || true
grep -q 'M1_IMPORT_APPROVED_BY' "$repo_root/scripts/local/m1-platform-imports.sh" \
  || fail "import script must require explicit operator approval"
grep -q 'm1_verify_approval_record' "$repo_root/scripts/local/m1-platform-imports.sh" \
  || fail "import script must verify a written approval record (not env-only authorization)"
grep -q 'm1_verify_approval_record' "$repo_root/scripts/local/m1-platform-apply.sh" \
  || fail "apply script must verify a written approval record (not env-only authorization)"
grep -q 'M1_EXTRA_VAR_FILE' "$repo_root/scripts/local/m1-platform-imports.sh" \
  || fail "import script must support a protected operator secret source"
if grep -q -- '-auto-approve' "$repo_root/scripts/local/m1-platform-plan.sh"; then
  fail "plan script must not reference -auto-approve"
fi
echo "ok: script contracts"

# ------------------------------------------------------------- import declarations tracked
# Declarative reproducibility: the eight imported production resources must be
# declared in tracked Terraform source with the full import-safety contract.
import_cfg="$repo_root/infra/platform/imported_resources.tf"
git -C "$repo_root" ls-files --error-unmatch "infra/platform/imported_resources.tf" >/dev/null 2>&1 \
  || fail "imported_resources.tf must be tracked (missing declarations would recreate production resources)"
[[ -f "$import_cfg" ]] || fail "imported_resources.tf missing from the checkout"
blocks="$(grep -cE '^resource ' "$import_cfg")"
[[ "$blocks" -eq 7 ]] || fail "import config must declare exactly the 7 blocks (8 addresses)"
pd="$(grep -cE 'prevent_destroy = true' "$import_cfg")"
[[ "$pd" -eq 7 ]] || fail "every imported block must carry prevent_destroy"
# NSG attachment state after the Scope-A execution (2026-10-28): the app NSG
# is declared for both instance primary VNICs and the lb NSG for the load
# balancer; the MySQL db-NSG line is FORBIDDEN while blocker B5 stands (the
# service rejects NSG updates on this DB system — re-add it only after B5 is
# resolved), and nothing else may reference NSGs.
app_nsg="$(grep -cE '^[[:space:]]*nsg_ids = \[oci_core_network_security_group\.app\.id\]$' "$import_cfg" || true)"
lb_nsg="$(grep -cE '^[[:space:]]*network_security_group_ids = \[oci_core_network_security_group\.lb\.id\]$' "$import_cfg" || true)"
[[ "$app_nsg" -eq 1 && "$lb_nsg" -eq 1 ]] \
  || fail "import config must carry the app and lb Scope-A NSG associations"
db_nsg="$(grep -cE 'nsg_ids[[:space:]]*= \[oci_core_network_security_group\.db\.id\]' "$import_cfg" || true)"
[[ "$db_nsg" -eq 0 ]] \
  || fail "MySQL db-NSG declaration is forbidden while blocker B5 stands (service rejects NSG updates)"
other_nsg="$(grep -nE 'nsg_ids|network_security_group_ids' "$import_cfg" \
  | grep -vE '^[0-9]+:[[:space:]]*#' \
  | grep -cvE 'nsg_ids[[:space:]]*= \[oci_core_network_security_group\.app\.id\]$|network_security_group_ids[[:space:]]*= \[oci_core_network_security_group\.lb\.id\]$' || true)"
[[ "$other_nsg" -eq 0 ]] || fail "unexpected NSG references in the import config"
if git -C "$repo_root" ls-files --error-unmatch "infra/platform/imported.auto.tfvars" >/dev/null 2>&1; then
  fail "imported.auto.tfvars (live OCIDs/private addresses) must never be tracked"
fi
echo "ok: tracked import declarations"

# ------------------------------------------------------------- local ingress guards
grep -q 'enable_api_ingress=true is refused' "$repo_root/scripts/local/m1-platform-plan.sh" \
  || fail "plan script must refuse enable_api_ingress=true inputs"
grep -q 'no-ingress-creates' "$repo_root/scripts/local/m1-platform-plan.sh" \
  || fail "plan script must scan the plan for API-ingress resources"
grep -q 'record is consumed' "$repo_root/scripts/local/m1-platform-apply.sh" \
  || fail "apply script must consume the approval record on failure"
[[ -x "$repo_root/tests/local/test-m1-apply-guards.sh" ]] || fail "apply-guard behavioral tests must be executable"
bash -n "$repo_root/tests/local/test-m1-apply-guards.sh" || fail "apply-guard tests must parse"
echo "ok: local ingress/approval guards"

# ------------------------------------------------------- drift verification repair
# Platform-drift-verification-repair regressions (2026-10-28): resource_drift
# is inspected explicitly, plan JSON is structure-validated, state-key probes
# are classified, and raw state is compared against live MySQL nsg_ids.
policy="$repo_root/scripts/ci/platform-safe-plan-policy.json"

# (9) A genuinely clean plan passes structure validation and classifies empty.
clean_plan="$work/clean-plan.json"
cat > "$clean_plan" <<'EOF'
{"format_version":"1.2","terraform_version":"1.12.2","errored":false,
 "resource_changes":[],"resource_drift":[],"output_changes":{},
 "prior_state":{"values":{"root_module":{"resources":[]}}}}
EOF
m1_plan_structure_ok "$clean_plan" || fail "a well-formed clean plan must pass structure validation"
drift_out="$(m1_classify_drift "$clean_plan" "$policy")"
[[ -z "$drift_out" ]] || fail "clean plan must classify as empty, got: $drift_out"
echo "ok: clean plan passes (regression 9)"

# (1) Empty resource_changes with nonempty resource_drift must NOT read clean —
# Terraform 1.12 omits empty resource_changes entirely, so resource_drift is
# the authoritative drift signal.
drift_only_plan="$work/drift-only-plan.json"
cat > "$drift_only_plan" <<'EOF'
{"format_version":"1.2","terraform_version":"1.12.2","errored":false,
 "resource_drift":[{"address":"oci_mysql_mysql_db_system.existing","mode":"managed","type":"oci_mysql_mysql_db_system","name":"existing","provider_name":"registry.terraform.io/oracle/oci",
   "change":{"actions":["update"],"before":{"nsg_ids":["ocid1.networksecuritygroup.oc1.test"],"time_updated":"a"},"after":{"nsg_ids":[],"time_updated":"b"},"after_unknown":{}}}],
 "output_changes":{},"prior_state":{"values":{"root_module":{"resources":[]}}}}
EOF
m1_plan_structure_ok "$drift_only_plan" || fail "plan with omitted empty resource_changes must pass structure validation"
drift_out="$(m1_classify_drift "$drift_only_plan" "$policy")"
[[ "$(grep -c $'^CRITICAL\toci_mysql_mysql_db_system\.existing\t' <<<"$drift_out")" -eq 1 ]] \
  || fail "empty resource_changes with nonempty resource_drift must classify as CRITICAL, got: $drift_out"
echo "ok: resource_drift inspected explicitly (regression 1)"

# (3) Budget computed drift is reported as EXPECTED_COMPUTED; any non-computed
# budget attribute (or unknown resource) is UNKNOWN.
budget_plan="$work/budget-plan.json"
cat > "$budget_plan" <<'EOF'
{"format_version":"1.2","terraform_version":"1.12.2","errored":false,
 "resource_drift":[
  {"address":"oci_budget_budget.monthly","mode":"managed","type":"oci_budget_budget","name":"monthly","provider_name":"registry.terraform.io/oracle/oci",
   "change":{"actions":["update"],"before":{"actual_spend":null,"forecasted_spend":null,"time_spend_computed":null,"time_updated":"a","amount":5},"after":{"actual_spend":0,"forecasted_spend":0,"time_spend_computed":"t","time_updated":"b","amount":5},"after_unknown":{}}}],
 "output_changes":{},"prior_state":{"values":{"root_module":{"resources":[]}}}}
EOF
drift_out="$(m1_classify_drift "$budget_plan" "$policy")"
grep -q $'^EXPECTED_COMPUTED\toci_budget_budget\.monthly\tactual_spend,forecasted_spend,time_spend_computed,time_updated$' <<<"$drift_out" \
  || fail "budget computed drift must be EXPECTED_COMPUTED with exact attributes, got: $drift_out"
jq '.resource_drift[0].change.after.amount = 9' "$budget_plan" > "$work/budget-amount-plan.json"
drift_out="$(m1_classify_drift "$work/budget-amount-plan.json" "$policy")"
grep -q $'^UNKNOWN\toci_budget_budget\.monthly\t' <<<"$drift_out" \
  || fail "a changed budget amount must be UNKNOWN, got: $drift_out"
echo "ok: budget computed drift reported (regression 3)"

# UNKNOWN: drift on an unprotected, non-budget resource must fail classification.
cat > "$work/unknown-plan.json" <<'EOF'
{"format_version":"1.2","terraform_version":"1.12.2","errored":false,
 "resource_drift":[{"address":"oci_budget_alert_rule.actual_75","mode":"managed","type":"oci_budget_alert_rule","name":"actual_75","provider_name":"registry.terraform.io/oracle/oci",
   "change":{"actions":["update"],"before":{"threshold":75},"after":{"threshold":80},"after_unknown":{}}}],
 "output_changes":{},"prior_state":{"values":{"root_module":{"resources":[]}}}}
EOF
drift_out="$(m1_classify_drift "$work/unknown-plan.json" "$policy")"
grep -q $'^UNKNOWN\toci_budget_alert_rule\.actual_75\t' <<<"$drift_out" \
  || fail "unprotected resource drift must be UNKNOWN, got: $drift_out"

# (7) Malformed or mistyped plan JSON must fail structure validation.
printf '{"resource_changes":' > "$work/truncated.json"
m1_plan_structure_ok "$work/truncated.json" 2>/dev/null && fail "truncated plan JSON must fail"
printf '{"format_version":"1.2","errored":true,"prior_state":{}}' > "$work/errored.json"
m1_plan_structure_ok "$work/errored.json" 2>/dev/null && fail "errored plan must fail"
printf '{"format_version":"1.2","errored":false,"prior_state":{},"resource_drift":{}}' > "$work/wrongtype.json"
m1_plan_structure_ok "$work/wrongtype.json" 2>/dev/null && fail "mistyped resource_drift must fail"
echo "ok: malformed plan JSON fails (regression 7)"

# (2) Raw-state vs live MySQL nsg_ids comparison: mismatch fails, agreement
# passes, and incomplete inputs fail closed.
state_json="$work/state.json"; live_json="$work/live.json"
DB_NSG="ocid1.networksecuritygroup.oc1.ap-hyderabad-1.aaaaaaaay3iipwy7weycrbdb7slmiu44mmhvnxsrizrrs2w7dpag5wur6hga"
printf '{"resources":[{"mode":"managed","type":"oci_mysql_mysql_db_system","name":"existing","instances":[{"attributes":{"id":"ocid1.mysqldbsystem.oc1.test","nsg_ids":["%s"]}}]}]}' "$DB_NSG" > "$state_json"
printf '{"data":{"lifecycle-state":"ACTIVE","nsg-ids":[]}}' > "$live_json"
rc=0; out="$(m1_mysql_nsg_state_live_agree "$state_json" "$live_json")" || rc=$?
[[ "$rc" -eq 1 ]] || fail "state/live NSG mismatch must fail (rc=1), got rc=$rc: $out"
grep -qF "state=[$DB_NSG] live=[]" <<<"$out" || fail "mismatch must report both values, got: $out"
printf '{"data":{"lifecycle-state":"ACTIVE","nsg-ids":["%s"]}}' "$DB_NSG" > "$live_json"
m1_mysql_nsg_state_live_agree "$state_json" "$live_json" >/dev/null \
  || fail "agreeing state/live nsg_ids must pass"
printf '{"resources":[]}' > "$state_json"
if m1_mysql_nsg_state_live_agree "$state_json" "$live_json" 2>/dev/null; then
  fail "state without the MySQL resource must fail closed (rc=2)"
fi
echo "ok: state/live NSG comparison (regression 2)"

# (4,5,6) State-key presence classification: a stubbed `oci` proves that
# 403/500/timeout/unparseable HEAD outcomes are NEVER classified as absence.
oci_stub_dir="$work/stub-bin"; mkdir -p "$oci_stub_dir"
stub_oci() { # stub_oci <exit-code> <stderr-body>
  {
    printf '#!/bin/sh\ncat >/dev/null\n'
    printf "printf '%%s' '%s' >&2\n" "$2"
    printf 'exit %s\n' "$1"
  } > "$oci_stub_dir/oci"
  chmod +x "$oci_stub_dir/oci"
}
run_status() { ( PATH="$oci_stub_dir:$PATH" m1_state_key_status "platform/terraform.tfstate" ); }
stub_oci 0 '' ; [[ "$(run_status)" == "exists" ]] || fail "HEAD rc=0 must classify exists"
stub_oci 1 '{"code":"ObjectNotFound","message":"not found","status":404}'
[[ "$(run_status)" == "absent" ]] || fail "HEAD 404 must classify absent (authoritative 404 only)"
stub_oci 1 '{"code":"NotAuthenticated","message":"denied","status":403}'
[[ "$(run_status)" == "auth" ]] || fail "HEAD 403 must classify auth, never absent (regression 4)"
stub_oci 1 '{"code":"InternalError","message":"boom","status":500}'
[[ "$(run_status)" == "service" ]] || fail "HEAD 500 must classify service, never absent (regression 5)"
stub_oci 1 '{"code":"TooManyRequests","message":"throttled","status":429}'
[[ "$(run_status)" == "service" ]] || fail "HEAD 429 must classify service"
stub_oci 7 'curl: (28) Connection timed out after 30000 milliseconds'
[[ "$(run_status)" == "timeout" ]] || fail "connection timeout must classify timeout"
stub_oci 1 'unparseable gibberish without status'
[[ "$(run_status)" == "malformed" ]] || fail "unparseable HEAD response must classify malformed"
echo "ok: state-key classification (regressions 4,5,6)"

# (6) The verify/init/plan/preflight scripts must consume the classifier and
# fail closed on absence-for-established-deployment and unknown classifications.
verify_sh="$repo_root/scripts/local/m1-verify.sh"
grep -q 'm1_state_key_status "$M1_PLATFORM_KEY"' "$verify_sh" \
  || fail "verify must classify the platform state key"
grep -q 'platform state key $M1_PLATFORM_KEY is ABSENT while the platform deployment is established' "$verify_sh" \
  || fail "verify must fail on absent platform state for an established deployment"
grep -q 'presence UNKNOWN (OCI probe classified' "$verify_sh" \
  || fail "verify must fail closed on unknown state-key classifications"
grep -q 'm1_mysql_nsg_state_live_agree' "$verify_sh" \
  || fail "verify must run the independent state/live NSG comparison"
for script in m1-platform-init.sh m1-platform-plan.sh m1-preflight.sh; do
  grep -q 'm1_state_key_status' "$repo_root/scripts/local/$script" \
    || fail "$script must classify the platform state key (no failed HEAD as absence)"
done
echo "ok: scripts consume the state-key classifier (regression 6)"

# (8) A normal refreshing plan is required: -refresh=false and -refresh-only
# are refused wherever a reviewed plan is produced or applied.
m1_verify_refreshing_plan -lock=true -input=false || fail "plain plan args must pass the refreshing-plan guard"
if m1_verify_refreshing_plan -refresh=false 2>/dev/null; then fail "-refresh=false must be refused"; fi
if m1_verify_refreshing_plan -refresh-only 2>/dev/null; then fail "-refresh-only must be refused"; fi
if TF_CLI_ARGS_plan="-refresh=false" m1_verify_refreshing_plan 2>/dev/null; then
  fail "TF_CLI_ARGS_plan -refresh=false must be refused"
fi
for script in m1-platform-plan.sh m1-platform-apply.sh; do
  grep -q 'm1_verify_refreshing_plan "\$@"' "$repo_root/scripts/local/$script" \
    || fail "$script must enforce the refreshing-plan contract"
done
grep -q 'm1_verify_refreshing_plan' "$repo_root/scripts/local/m1-verify.sh" \
  && fail "verify's refresh-only assessment must not be constrained by the normal-plan guard (it is deliberately refresh-only)" || true
grep -q 'UNACCEPTABLE DRIFT' "$verify_sh" || fail "verify must fail acceptance on CRITICAL/UNKNOWN drift"
grep -q 'acknowledged computed drift only' "$verify_sh" \
  || fail "verify must report expected computed drift as acknowledged, never silent zero"
echo "ok: refreshing-plan contract (regression 8)"

# (4, retest) The dedicated MYSQL-NSG-RETEST gate: separate approval marker,
# offline plan recheck, and live before/after preconditions in the apply path.
apply_sh="$repo_root/scripts/local/m1-platform-apply.sh"
grep -q 'required_gate="MYSQL-NSG-RETEST"' "$apply_sh" \
  || fail "apply must select the separate MYSQL-NSG-RETEST gate for retest plans"
grep -q 'assert-safe-plan-scope-a.sh" --policy "$M1_REPO_ROOT/$M1_MYSQL_RETEST_POLICY' "$apply_sh" \
  || fail "apply must revalidate the saved plan against the dedicated retest policy"
grep -q 'retest-live-active' "$apply_sh" && grep -q 'retest-live-before' "$apply_sh" \
  || fail "apply must check live MySQL ACTIVE and the reviewed before-value nsg_ids"
grep -q 'M1_MYSQL_RETEST_POLICY=' "$repo_root/scripts/local/m1-local.env" \
  || fail "m1-local.env must name the dedicated retest policy"
grep -q 'retest' "$repo_root/tests/ci/run.sh" \
  || fail "retest fixture tests must stay wired into the CI test runner"
echo "ok: MYSQL-NSG-RETEST gate contracts (regression 10: retest path)"

# (10) No existing acceptance guards regress: the policy files referenced by
# the repaired gates stay intact and valid.
jq -e '.protected_imports | type == "array"' "$policy" >/dev/null \
  || fail "general safe-plan policy must stay intact"
jq -e '.allow[0].expected_attribute_values_before.nsg_ids == []' \
  "$repo_root/scripts/ci/platform-safe-plan-mysql-retest-policy.json" >/dev/null \
  || fail "retest policy before-value contract must stay intact"

echo "M1-LOCAL guard tests passed"
