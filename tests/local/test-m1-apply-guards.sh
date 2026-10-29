#!/usr/bin/env bash
# Offline BEHAVIORAL tests for m1-platform-apply.sh: the plan/metadata/approval
# triangle, approval consumption on failure, and stale-state rejection are
# exercised end-to-end against stub terraform and oci binaries. Never touches
# a real backend, the OCI API, or local state files; all artifacts live in a
# scratch directory.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail() { echo "TEST FAIL: $1" >&2; exit 1; }

# Operator-local backend coordinates the lib expects on disk (git-ignored in
# a real checkout; synthesized here for CI).
env_value() { # env_value <name> — evaluate scripts/local/m1-local.env defaults
  (
    source "$repo_root/scripts/local/m1-local.env" >/dev/null 2>&1
    eval "$(printf 'printf %%s "${%s}"' "$1")"
  )
}
if [[ ! -f "$repo_root/infra/platform/backend.hcl" ]]; then
  bucket="$(env_value M1_TF_STATE_BUCKET)"
  namespace="$(env_value M1_OCI_NAMESPACE)"
  printf '# test backend coordinates\nbucket    = "%s"\nnamespace = "%s"\nkey       = "platform/terraform.tfstate"\nregion    = "ap-hyderabad-1"\nauth      = "APIKey"\nconfig_file_profile = "DEFAULT"\n' \
    "$bucket" "$namespace" > "$repo_root/infra/platform/backend.hcl"
  cleanup_backend=1
else
  cleanup_backend=0
fi
cleanup() {
  [[ "$cleanup_backend" == 1 ]] && rm -f "$repo_root/infra/platform/backend.hcl"
  rm -rf "$work"
}
trap cleanup EXIT

# ---------------------------------------------------------------- stub binaries
stub_bin="$work/bin"
mkdir -p "$stub_bin"

# terraform stub: version pin, default workspace, controllable state pull and apply.
cat > "$stub_bin/terraform" <<EOF
#!/usr/bin/env bash
state_file="\$STUB_STATE_FILE"
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    version) echo "Terraform v1.12.2"; echo "on darwin_arm64"; exit 0 ;;
    -chdir=*) ;;
    workspace) [[ "\${2:-}" == show ]] && { echo default; exit 0; } ;;
    state) [[ "\${2:-}" == pull ]] && { cat "\$state_file"; exit 0; } ;;
    show) [[ "\${2:-}" == -json ]] && { cat "\${3}.json"; exit 0; } ;;
    apply) [[ -n "\${STUB_APPLY_MARKER:-}" ]] && : > "\$STUB_APPLY_MARKER"; [[ "\${STUB_APPLY_RC:-0}" == 1 ]] && { echo "stub apply failure" >&2; exit 1; }; exit 0 ;;
  esac
  shift
done
echo "unexpected terraform invocation: \$*" >&2
exit 99
EOF
chmod +x "$stub_bin/terraform"

# stub state + kms key come from the pinned env file so the stub matches the
# library's expectations without hardcoding operator coordinates here.
KMS_KEY="$(env_value M1_EXPECTED_KMS_KEY_ID)"
export KMS_KEY

# oci stub: healthy bucket/CMK, no lock objects, platform key present.
cat > "$stub_bin/oci" <<EOF
#!/usr/bin/env bash
[[ -n "\${STUB_OCI_LOG:-}" ]] && printf '%s\n' "\$*" >> "\$STUB_OCI_LOG"
case "\$1 \$2 \$3" in
  "os bucket get")   printf '{"data":{"public-access-type":"NoPublicAccess","versioning":"Enabled","kms-key-id":"%s"}}' "\$KMS_KEY"; exit 0 ;;
  "kms management key") printf '{"data":{"lifecycle-state":"ENABLED"}}'; exit 0 ;;
  "os object head")  exit 0 ;;
  "os object list")  printf '{"data":[]}'; exit 0 ;;
  "network nsg rules") printf '{"data":[{"id":"%s","source":"%s","direction":"INGRESS","protocol":"6"}]}' "\${STUB_RULE_ID:-0DE088}" "\${STUB_RULE_SOURCE:-49.207.214.221/32}"; exit 0 ;;
  "mysql db-system get") printf '{"data":{"lifecycle-state":"ACTIVE","nsg-ids":[],"display-name":"rust-api-heatwave"}}'; exit 0 ;;
esac
echo "unexpected oci invocation: \$*" >&2
exit 99
EOF
chmod +x "$stub_bin/oci"

export PATH="$stub_bin:$PATH"
export M1_TERRAFORM_BIN="$stub_bin/terraform"
export M1_EVIDENCE_ROOT="$work/evidence"
export M1_RUN_TAG="apply-guard-test"
export OCI_CLI_CONFIG="$work/oci-config"
printf '[DEFAULT]\nuser=ocid1.user.oc1..test\nfingerprint=aa:bb\ntenancy=ocid1.tenancy.oc1..test\nregion=ap-hyderabad-1\nkey_file=%s/test.pem\n' "$work" > "$OCI_CLI_CONFIG"
export M1_APPLY_APPROVED_BY="test-operator"

commit="$(git -C "$repo_root" rev-parse HEAD)"
stub_state="$work/state.json"
printf '{"lineage":"test-lineage-1","serial":10,"outputs":{}}' > "$stub_state"
export STUB_STATE_FILE="$stub_state"
export STUB_APPLY_MARKER="$work/apply-was-invoked"
export STUB_OCI_LOG="$work/oci-calls.log"
unset STUB_APPLY_RC || true

make_artifacts() { # make_artifacts <plan-file> <metadata-file> <record-file> [lineage] [safe_plan_policy] [gate-marker] [plan-json-fixture]
  local plan="$1" meta="$2" record="$3" lineage="${4:-test-lineage-1}"
  local policy="${5:-scripts/ci/platform-safe-plan-policy.json}" gate="${6:-PLATFORM-APPLY}"
  local plan_json="${7:-$repo_root/tests/ci/fixtures/plan-noop.json}"
  # A pre-existing plan file/.json (e.g. from make_ssh_plan) is authoritative —
  # only the SHA binding is computed here, never a rewrite of plan content.
  [[ -f "$plan" ]] || printf 'PLANBYTES-%s' "$RANDOM" > "$plan"
  [[ -f "$plan.json" ]] || cp "$plan_json" "$plan.json"
  local sha policy_sha
  sha="$(shasum -a 256 "$plan" | awk '{print $1}')"
  policy_sha=""
  [[ -f "$repo_root/$policy" ]] && policy_sha="$(shasum -a 256 "$repo_root/$policy" | awk '{print $1}')"
  jq -n --arg plan "$plan" --arg sha "$sha" --arg commit "$commit" \
    --arg lineage "$lineage" --argjson serial 10 --arg policy "$policy" --arg policy_sha "$policy_sha" \
    '{plan:$plan, plan_json:($plan + ".json"), plan_sha256:$sha, commit:$commit,
      operator:"test-operator", state_lineage:$lineage, state_serial:$serial,
      safe_plan:"PASS", safe_plan_policy:(if $policy == "" then null else $policy end),
      safe_plan_policy_sha256:(if $policy_sha == "" then null else $policy_sha end),
      proposed_import_updates:0, non_noop_changes:0,
      terraform_version:"1.12.2", bucket:"b", state_key:"k",
      applied:false, apply_evidence:null, timestamp:"2026-10-27T00:00:00Z"}' > "$meta"
  printf 'GATE: %s\nAPPROVER: test-operator\nCOMMIT: %s\nPLAN_SHA256: %s\n' "$gate" "$commit" "$sha" > "$record"
}

run_apply() { # run_apply <plan> <meta> <record>
  "$repo_root/scripts/local/m1-platform-apply.sh" "$1" "$2" "$3" >"$work/out.log" 2>"$work/err.log"
}

refused_before_apply() { # refused_before_apply [--allow-live-reads] <label> <plan> <meta> <record>
  # Asserts refusal, no stub apply invocation, and (for refusals that fire
  # BEFORE the live-guard phase — the default) no stubbed live OCI call at
  # all. Refusals that legitimately occur after the read-only live guards
  # (e.g. an offline contract recheck inside a dedicated block) pass
  # --allow-live-reads; the stub oci still exits 99 on ANY invocation shape
  # it does not implement, all of which are read-only, so a mutating call
  # would fail the run outright.
  local allow_live_reads=0
  if [[ "$1" == "--allow-live-reads" ]]; then allow_live_reads=1; shift; fi
  local label="$1"
  rm -f "$STUB_APPLY_MARKER" "$STUB_OCI_LOG"
  if run_apply "$2" "$3" "$4" 2>/dev/null; then
    fail "$label: expected refusal, but the apply script exited 0"
  fi
  if [[ -e "$STUB_APPLY_MARKER" ]]; then
    fail "$label: REFUSED but the terraform apply was still invoked"
  fi
  if [[ "$allow_live_reads" -eq 0 && -s "$STUB_OCI_LOG" ]]; then
    fail "$label: REFUSED but stubbed live OCI calls occurred: $(head -3 "$STUB_OCI_LOG")"
  fi
}

# 1. Happy path: consistent plan+metadata+record+state → apply succeeds.
plan="$work/plan.tfplan"; meta="$work/meta.json"; record="$work/record.md"
make_artifacts "$plan" "$meta" "$record"
run_apply "$plan" "$meta" "$record" || { cat "$work/err.log"; fail "consistent artifacts must apply"; }
[[ "$(jq -r .applied "$meta")" == "true" ]] || fail "metadata must be marked applied after success"
echo "ok: SHA-bound apply with written approval record"

# 2. Replay: the same plan/metadata/record cannot apply twice.
if run_apply "$plan" "$meta" "$record" 2>/dev/null; then fail "applied plan must be refused on replay"; fi
grep -q "already applied" "$work/err.log" || { cat "$work/err.log"; fail "replay refusal message missing"; }
echo "ok: replay refused"

# 3. Unrelated saved plan cannot be substituted: metadata names plan A, caller passes plan B.
make_artifacts "$work/plan-a.tfplan" "$work/meta-a.json" "$record"
make_artifacts "$work/plan-b.tfplan" "$work/meta-b.json" "$record"
run_apply "$work/plan-b.tfplan" "$work/meta-a.json" "$record" 2>/dev/null \
  && fail "substituted plan must be refused"
grep -q "metadata names a different plan" "$work/err.log" || fail "plan-path mismatch refusal missing"
echo "ok: unrelated saved plan refused"

# 4. Tampered plan: content changed after review → SHA mismatch.
make_artifacts "$work/plan-t.tfplan" "$work/meta-t.json" "$work/record-t.md"
printf 'TAMPERED' >> "$work/plan-t.tfplan"
run_apply "$work/plan-t.tfplan" "$work/meta-t.json" "$work/record-t.md" 2>/dev/null \
  && fail "tampered plan must be refused"
grep -q "plan content changed since review" "$work/err.log" || fail "sha mismatch refusal missing"
echo "ok: tampered plan refused"

# 5. Approval env attestation must match the record's APPROVER line.
make_artifacts "$work/plan-v.tfplan" "$work/meta-v.json" "$work/record-v.md"
M1_APPLY_APPROVED_BY="someone-else" run_apply "$work/plan-v.tfplan" "$work/meta-v.json" "$work/record-v.md" 2>/dev/null \
  && fail "env attestation mismatch must be refused"
grep -q "does not match the record's APPROVER" "$work/err.log" || fail "approver mismatch refusal missing"
echo "ok: approval attestation enforced"

# 6. Stale state identity: remote state moved since the plan.
make_artifacts "$work/plan-s.tfplan" "$work/meta-s.json" "$work/record-s.md"
printf '{"lineage":"OTHER-lineage","serial":11,"outputs":{}}' > "$stub_state"
run_apply "$work/plan-s.tfplan" "$work/meta-s.json" "$work/record-s.md" 2>/dev/null \
  && fail "stale state identity must be refused"
grep -q "remote state moved since the plan" "$work/err.log" || fail "stale state refusal missing"
printf '{"lineage":"test-lineage-1","serial":10,"outputs":{}}' > "$stub_state"
echo "ok: stale/mismatched state identity refused"

# 7. Failed apply consumes the approval: same record can never re-authorize.
make_artifacts "$work/plan-f.tfplan" "$work/meta-f.json" "$work/record-f.md"
STUB_APPLY_RC=1 run_apply "$work/plan-f.tfplan" "$work/meta-f.json" "$work/record-f.md" 2>/dev/null \
  && fail "stubbed apply failure must propagate"
grep -q "record is consumed" "$work/err.log" || fail "failed apply must consume the approval record"
[[ "$(jq -r .applied "$work/meta-f.json")" == "true" ]] || fail "failed apply must mark metadata consumed"
jq -r .apply_evidence "$work/meta-f.json" | grep -q "FAILED" || fail "metadata must record the failure"
if run_apply "$work/plan-f.tfplan" "$work/meta-f.json" "$work/record-f.md" 2>/dev/null; then
  fail "failed apply must not be re-runnable under the same approval"
fi
grep -q "already applied" "$work/err.log" || fail "consumed approval must refuse replay"
echo "ok: failed apply consumes its approval record"

# 8–17. Content-driven approval-gate dispatch: the required gate marker is
# derived from the SAVED PLAN'S ACTUAL CHANGES (independent classification),
# never from metadata.safe_plan_policy alone. A tampered, missing, or stale
# metadata policy can no longer route a dedicated-gate plan through the
# general gate; unknown/inconsistent policy identity fails closed with no
# fallback; every refusal must stop BEFORE the terraform apply invocation
# (asserted via the stub apply marker). Every plan class — including general
# PLATFORM-APPLY — has its saved plan revalidated against the reviewed policy
# at apply time.
ssh_policy="scripts/ci/platform-safe-plan-ssh-update-policy.json"
generic_policy="scripts/ci/platform-safe-plan-policy.json"

make_ssh_plan() { # make_ssh_plan <plan-file> — reviewed one-rule /32 update + rule/NSG ids
  local plan="$1"
  cp "$repo_root/tests/ci/fixtures/plan-ssh-base.json" "$plan"
  jq -c '.resource_changes[0].change.before.id = "0DE088"
       | .resource_changes[0].change.after.id = "0DE088"
       | .resource_changes[0].change.before.network_security_group_id = "ocid1.networksecuritygroup.oc1.ap-hyderabad-1.testnsg"
       | .resource_changes[0].change.after.network_security_group_id = "ocid1.networksecuritygroup.oc1.ap-hyderabad-1.testnsg"' \
    "$plan" > "$plan.aug" && mv "$plan.aug" "$plan"
  cp "$plan" "$plan.json"
}

# 8. SSH-class plan (metadata consistent) under a general PLATFORM-APPLY record → refused.
make_ssh_plan "$work/plan-ssh.tfplan"
make_artifacts "$work/plan-ssh.tfplan" "$work/meta-ssh.json" "$work/record-ssh-generic.md" \
  test-lineage-1 "$ssh_policy" PLATFORM-APPLY
refused_before_apply "SSH plan vs general record" "$work/plan-ssh.tfplan" "$work/meta-ssh.json" "$work/record-ssh-generic.md"
grep -q "GATE: SSH-SOURCE-UPDATE" "$work/err.log" || { cat "$work/err.log"; fail "SSH gate refusal message missing"; }
[[ "$(jq -r .applied "$work/meta-ssh.json")" == "false" ]] || fail "refused SSH plan must not be marked applied"
echo "ok: SSH-class plan refuses the general PLATFORM-APPLY record (case A-negative)"

# 9/A. SSH-class plan under the dedicated record with a matching live source → applies.
make_ssh_plan "$work/plan-ssh2.tfplan"
make_artifacts "$work/plan-ssh2.tfplan" "$work/meta-ssh2.json" "$work/record-ssh2.md" \
  test-lineage-1 "$ssh_policy" SSH-SOURCE-UPDATE
rm -f "$STUB_APPLY_MARKER"
run_apply "$work/plan-ssh2.tfplan" "$work/meta-ssh2.json" "$work/record-ssh2.md" \
  || { cat "$work/err.log"; fail "SSH-gated plan must apply under GATE: SSH-SOURCE-UPDATE"; }
grep -q "ssh-update-live-before" "$work/out.log" || fail "live SSH precondition gate missing from apply output"
[[ -e "$STUB_APPLY_MARKER" ]] || fail "valid SSH plan must reach the terraform apply"
[[ "$(jq -r .applied "$work/meta-ssh2.json")" == "true" ]] || fail "applied SSH plan must be marked applied"
echo "ok: case A — SSH-SOURCE-UPDATE gate applies the reviewed rotation end-to-end"

# 10/I. Live SSH rule source moved since review → stale plan refused (fail closed, before apply).
make_ssh_plan "$work/plan-ssh3.tfplan"
make_artifacts "$work/plan-ssh3.tfplan" "$work/meta-ssh3.json" "$work/record-ssh3.md" \
  test-lineage-1 "$ssh_policy" SSH-SOURCE-UPDATE
rm -f "$STUB_APPLY_MARKER"
STUB_RULE_SOURCE="49.207.199.199/32" run_apply "$work/plan-ssh3.tfplan" "$work/meta-ssh3.json" "$work/record-ssh3.md" 2>/dev/null \
  && fail "stale live SSH source must be refused"
[[ -e "$STUB_APPLY_MARKER" ]] && fail "stale live SSH source must stop before the apply"
grep -q "re-plan and re-review" "$work/err.log" || { cat "$work/err.log"; fail "stale live SSH refusal message missing"; }
echo "ok: case I — stale live SSH source refuses the rotation apply before apply"

# 11. Saved SSH plan diverging from the dedicated policy → refused offline, before any live access.
make_artifacts "$work/plan-ssh-bad.tfplan" "$work/meta-ssh-bad.json" "$work/record-ssh-bad.md" \
  test-lineage-1 "$ssh_policy" SSH-SOURCE-UPDATE
cp "$repo_root/tests/ci/fixtures/plan-ssh-wrong-target.json" "$work/plan-ssh-bad.tfplan.json"
refused_before_apply --allow-live-reads "SSH plan-policy divergence" "$work/plan-ssh-bad.tfplan" "$work/meta-ssh-bad.json" "$work/record-ssh-bad.md"
grep -q "does not match the dedicated SSH-SOURCE-UPDATE policy" "$work/err.log" \
  || { cat "$work/err.log"; fail "SSH plan-contract refusal message missing"; }
echo "ok: SSH plan diverging from the reviewed policy refused offline"

# B. Same SSH plan with metadata policy switched to GENERIC + PLATFORM-APPLY
# record → REFUSED: content-driven dispatch derives SSH-SOURCE-UPDATE from the
# plan itself; metadata cannot downgrade the gate (fail closed, no fallback).
make_ssh_plan "$work/plan-ssh-b.tfplan"
make_artifacts "$work/plan-ssh-b.tfplan" "$work/meta-ssh-b.json" "$work/record-ssh-b.md" \
  test-lineage-1 "$generic_policy" PLATFORM-APPLY
refused_before_apply "metadata policy downgrade (SSH)" "$work/plan-ssh-b.tfplan" "$work/meta-ssh-b.json" "$work/record-ssh-b.md"
grep -q "INCONSISTENT POLICY IDENTITY" "$work/err.log" \
  || { cat "$work/err.log"; fail "metadata-downgrade refusal message missing"; }
echo "ok: case B — metadata policy downgraded to generic cannot route an SSH plan through PLATFORM-APPLY"

# C. Same SSH plan with the metadata policy field ABSENT → REFUSED (unknown identity).
make_ssh_plan "$work/plan-ssh-c.tfplan"
make_artifacts "$work/plan-ssh-c.tfplan" "$work/meta-ssh-c.json" "$work/record-ssh-c.md" \
  test-lineage-1 "$ssh_policy" SSH-SOURCE-UPDATE
jq 'del(.safe_plan_policy)' "$work/meta-ssh-c.json" > "$work/meta-ssh-c.tmp" && mv "$work/meta-ssh-c.tmp" "$work/meta-ssh-c.json"
refused_before_apply "absent metadata policy (SSH)" "$work/plan-ssh-c.tfplan" "$work/meta-ssh-c.json" "$work/record-ssh-c.md"
grep -q "POLICY IDENTITY" "$work/err.log" \
  || { cat "$work/err.log"; fail "policy-identity refusal message missing"; }
grep -q "the accepted set is FIXED" "$work/err.log" \
  || { cat "$work/err.log"; fail "fail-closed policy-identity wording missing"; }
echo "ok: case C — absent metadata policy identity refused (no fallback)"

# D. MySQL retest plan with metadata policy changed to GENERIC + PLATFORM-APPLY
# record → REFUSED: the protected MySQL NSG update always requires
# GATE: MYSQL-NSG-RETEST.
make_artifacts "$work/plan-mysql-b.tfplan" "$work/meta-mysql-b.json" "$work/record-mysql-b.md" \
  test-lineage-1 "$generic_policy" PLATFORM-APPLY "$repo_root/tests/ci/fixtures/plan-mysql-retest-base.json"
refused_before_apply "metadata policy downgrade (MySQL)" "$work/plan-mysql-b.tfplan" "$work/meta-mysql-b.json" "$work/record-mysql-b.md"
grep -q "INCONSISTENT POLICY IDENTITY" "$work/err.log" \
  || { cat "$work/err.log"; fail "MySQL metadata-downgrade refusal message missing"; }
echo "ok: case D — metadata policy downgraded to generic cannot route a MySQL retest plan through PLATFORM-APPLY"

# E. Generic policy + unrelated PROTECTED resource update → REFUSED by the
# apply-time generic policy recheck (metadata.safe_plan=PASS is not evidence).
make_artifacts "$work/plan-protected.tfplan" "$work/meta-protected.json" "$work/record-protected.md" \
  test-lineage-1 "$generic_policy" PLATFORM-APPLY
jq -n '{resource_changes:[{address:"oci_core_instance.api[\"vm1\"]",type:"oci_core_instance",
  change:{actions:["update"],before:{display_name:"rust-api-test"},after:{display_name:"renamed"},after_unknown:{}}}]}' \
  > "$work/plan-protected.tfplan.json"
refused_before_apply --allow-live-reads "protected-import update under generic policy" "$work/plan-protected.tfplan" "$work/meta-protected.json" "$work/record-protected.md"
grep -q "does not match the reviewed generic policy" "$work/err.log" \
  || { cat "$work/err.log"; fail "generic policy recheck refusal message missing"; }
echo "ok: case E — protected-import update refused by the apply-time generic policy recheck"

# F. General platform plan + correct generic policy + reviewed change → PASSES.
make_artifacts "$work/plan-generic.tfplan" "$work/meta-generic.json" "$work/record-generic.md" \
  test-lineage-1 "$generic_policy" PLATFORM-APPLY "$repo_root/tests/ci/fixtures/plan-allowed.json"
rm -f "$STUB_APPLY_MARKER"
run_apply "$work/plan-generic.tfplan" "$work/meta-generic.json" "$work/record-generic.md" \
  || { cat "$work/err.log"; fail "general plan with reviewed change must apply"; }
grep -q "platform-policy-recheck" "$work/out.log" || fail "generic apply-time policy recheck gate missing"
[[ -e "$STUB_APPLY_MARKER" ]] || fail "valid general plan must reach the terraform apply"
echo "ok: case F — general PLATFORM-APPLY plan revalidated and applied end-to-end"

# G. Source-commit or plan-SHA mismatch → REFUSED before apply (SHA case is test 4).
make_artifacts "$work/plan-commit.tfplan" "$work/meta-commit.json" "$work/record-commit.md"
jq '.commit = "0000000000000000000000000000000000000000"' "$work/meta-commit.json" > "$work/meta-commit.tmp" \
  && mv "$work/meta-commit.tmp" "$work/meta-commit.json"
refused_before_apply "commit mismatch" "$work/plan-commit.tfplan" "$work/meta-commit.json" "$work/record-commit.md"
grep -q "repository moved since review" "$work/err.log" || { cat "$work/err.log"; fail "commit mismatch refusal message missing"; }
echo "ok: case G(round-2) — changed source-commit refused before apply (plan SHA: case 4)"

# 18–24. Round-3 policy-identity hardening: fixed allowlist, historical
# Scope-A, policy-content integrity. Case mapping: A = test 1 (generic plan +
# default policy applies under the fixed allowlist); G = case 9/A (valid SSH
# plan + dedicated policy + SSH-SOURCE-UPDATE record applies); H = round-2
# case B (SSH plan with downgraded metadata refused); J = round-2 case D
# (MySQL plan with downgraded metadata refused).
scope_a_policy="scripts/ci/platform-safe-plan-scope-a-policy.json"
retest_policy="scripts/ci/platform-safe-plan-mysql-retest-policy.json"

make_mysql_plan() { # make_mysql_plan <plan-file> — reviewed one-entry nsg_ids update + db-system id
  local plan="$1"
  cp "$repo_root/tests/ci/fixtures/plan-mysql-retest-base.json" "$plan"
  jq -c '.resource_changes[0].change.before.id = "ocid1.mysqldbsystem.oc1.ap-hyderabad-1.testdb"
       | .resource_changes[0].change.after.id = "ocid1.mysqldbsystem.oc1.ap-hyderabad-1.testdb"' \
    "$plan" > "$plan.aug" && mv "$plan.aug" "$plan"
  cp "$plan" "$plan.json"
}

# B. Scope-A metadata routed through PLATFORM-APPLY → REFUSED (historical policy).
make_artifacts "$work/plan-scopeA.tfplan" "$work/meta-scopeA.json" "$work/record-scopeA.md" \
  test-lineage-1 "$scope_a_policy" PLATFORM-APPLY
jq -n '{resource_changes:[{address:"oci_core_instance.api[\"vm1\"]",type:"oci_core_instance",
  change:{actions:["update"],
    before:{display_name:"rust-api-test",create_vnic_details:[{nsg_ids:[],subnet_id:"sn-app"}]},
    after:{display_name:"rust-api-test",create_vnic_details:[{nsg_ids:["ocid1.networksecuritygroup.oc1.ap-hyderabad-1.app"],subnet_id:"sn-app"}]},
    after_unknown:{}}}]}' > "$work/plan-scopeA.tfplan.json"
refused_before_apply "Scope-A under the general gate" "$work/plan-scopeA.tfplan" "$work/meta-scopeA.json" "$work/record-scopeA.md"
grep -q "HISTORICAL POLICY" "$work/err.log" \
  || { cat "$work/err.log"; fail "Scope-A historical refusal message missing"; }
echo "ok: case B — Scope-A policy refused under the general PLATFORM-APPLY gate"

# C. Scope-A plan with an unauthorized attribute changed → REFUSED by the
# RETAINED scope-A checker (its attribute contract must stay intact for any
# future dedicated Scope-A class). Canonical fixtures: the base change set
# passes; the display_name (non-NSG attribute) change is refused.
"$repo_root/scripts/ci/assert-safe-plan-scope-a.sh" --policy "$repo_root/$scope_a_policy" \
  "$repo_root/tests/ci/fixtures/plan-scopea-base.json" >/dev/null 2>&1 \
  || fail "case C: scope-A checker must still accept the reviewed attribute-only change set (positive control)"
if "$repo_root/scripts/ci/assert-safe-plan-scope-a.sh" --policy "$repo_root/$scope_a_policy" \
     "$repo_root/tests/ci/fixtures/plan-scopea-non-nsg-attr.json" >/dev/null 2>&1; then
  fail "case C: scope-A checker must refuse an unauthorized attribute change"
fi
echo "ok: case C — unauthorized Scope-A attribute change refused by the retained checker"

# D. Arbitrary M1_SAFE_PLAN_POLICY override with matching metadata → REFUSED:
# the accepted set is fixed literals, never taken from the environment.
override_policy="scripts/ci/policy-not-in-allowlist.json"
make_artifacts "$work/plan-override.tfplan" "$work/meta-override.json" "$work/record-override.md" \
  test-lineage-1 "$override_policy" PLATFORM-APPLY
M1_SAFE_PLAN_POLICY="$override_policy" refused_before_apply "env policy override" \
  "$work/plan-override.tfplan" "$work/meta-override.json" "$work/record-override.md"
grep -q "UNKNOWN OR INCONSISTENT POLICY IDENTITY" "$work/err.log" \
  || { cat "$work/err.log"; fail "env-override refusal message missing"; }
grep -q "never taken from the environment" "$work/err.log" \
  || { cat "$work/err.log"; fail "fixed-allowlist wording missing"; }
echo "ok: case D — M1_SAFE_PLAN_POLICY override cannot reclassify the plan"

# E. Unknown policy path in metadata → REFUSED.
make_artifacts "$work/plan-unknown.tfplan" "$work/meta-unknown.json" "$work/record-unknown.md" \
  test-lineage-1 "scripts/ci/policy-not-in-allowlist.json" PLATFORM-APPLY
refused_before_apply "unknown policy path" "$work/plan-unknown.tfplan" "$work/meta-unknown.json" "$work/record-unknown.md"
grep -q "UNKNOWN OR INCONSISTENT POLICY IDENTITY" "$work/err.log" \
  || { cat "$work/err.log"; fail "unknown-path refusal message missing"; }
echo "ok: case E — unknown policy path refused (no fallback)"

# F. Reviewed policy content modified after plan generation → REFUSED by the
# SHA-256 equality gate (uncommitted-edit gate asserted by source contract).
make_artifacts "$work/plan-policysha.tfplan" "$work/meta-policysha.json" "$work/record-policysha.md"
jq '.safe_plan_policy_sha256 = "0000000000000000000000000000000000000000000000000000000000000000"' \
  "$work/meta-policysha.json" > "$work/meta-policysha.tmp" && mv "$work/meta-policysha.tmp" "$work/meta-policysha.json"
refused_before_apply "policy content drift" "$work/plan-policysha.tfplan" "$work/meta-policysha.json" "$work/record-policysha.md"
grep -q "REVIEWED POLICY CONTENT CHANGED" "$work/err.log" \
  || { cat "$work/err.log"; fail "policy-integrity refusal message missing"; }
echo "ok: case F — policy content modified after plan generation refused"

# I. Valid MySQL retest plan + dedicated policy + MYSQL-NSG-RETEST record →
# PASS through the existing guarded path (offline contract, values, live
# ACTIVE + before-value, apply).
make_mysql_plan "$work/plan-mysql-ok.tfplan"
make_artifacts "$work/plan-mysql-ok.tfplan" "$work/meta-mysql-ok.json" "$work/record-mysql-ok.md" \
  test-lineage-1 "$retest_policy" MYSQL-NSG-RETEST
rm -f "$STUB_APPLY_MARKER" "$STUB_OCI_LOG"
run_apply "$work/plan-mysql-ok.tfplan" "$work/meta-mysql-ok.json" "$work/record-mysql-ok.md" \
  || { cat "$work/err.log"; fail "valid MySQL retest plan must apply under GATE: MYSQL-NSG-RETEST"; }
grep -q "retest-plan-contract" "$work/out.log" || fail "retest offline contract gate missing"
grep -q "retest-live-before" "$work/out.log" || fail "retest live before-value gate missing"
[[ -e "$STUB_APPLY_MARKER" ]] || fail "valid MySQL retest plan must reach the terraform apply"
echo "ok: case I — MYSQL-NSG-RETEST gate applies the reviewed retest plan end-to-end"

echo "M1-LOCAL apply-guard behavioral tests passed"
