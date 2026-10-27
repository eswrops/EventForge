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
if [[ ! -f "$repo_root/infra/platform/backend.hcl" ]]; then
  # shellcheck source=scripts/local/m1-local.env
  bucket="$(grep '^M1_TF_STATE_BUCKET=' "$repo_root/scripts/local/m1-local.env" | cut -d= -f2 | tr -d '"')"
  namespace="$(grep '^M1_OCI_NAMESPACE=' "$repo_root/scripts/local/m1-local.env" | cut -d= -f2 | tr -d '"')"
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
    apply) [[ "\${STUB_APPLY_RC:-0}" == 1 ]] && { echo "stub apply failure" >&2; exit 1; }; exit 0 ;;
  esac
  shift
done
echo "unexpected terraform invocation: \$*" >&2
exit 99
EOF
chmod +x "$stub_bin/terraform"

# stub state + kms key come from the pinned env file so the stub matches the
# library's expectations without hardcoding operator coordinates here.
KMS_KEY="$(grep '^M1_EXPECTED_KMS_KEY_ID=' "$repo_root/scripts/local/m1-local.env" | cut -d= -f2 | tr -d '"')"
export KMS_KEY

# oci stub: healthy bucket/CMK, no lock objects, platform key present.
cat > "$stub_bin/oci" <<EOF
#!/usr/bin/env bash
case "\$1 \$2 \$3" in
  "os bucket get")   printf '{"data":{"public-access-type":"NoPublicAccess","versioning":"Enabled","kms-key-id":"%s"}}' "\$KMS_KEY"; exit 0 ;;
  "kms management key") printf '{"data":{"lifecycle-state":"ENABLED"}}'; exit 0 ;;
  "os object head")  exit 0 ;;
  "os object list")  printf '{"data":[]}'; exit 0 ;;
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
unset STUB_APPLY_RC || true

make_artifacts() { # make_artifacts <plan-file> <metadata-file> <record-file> [lineage]
  local plan="$1" meta="$2" record="$3" lineage="${4:-test-lineage-1}"
  printf 'PLANBYTES-%s' "$RANDOM" > "$plan"
  local sha
  sha="$(shasum -a 256 "$plan" | awk '{print $1}')"
  jq -n --arg plan "$plan" --arg sha "$sha" --arg commit "$commit" \
    --arg lineage "$lineage" --argjson serial 10 \
    '{plan:$plan, plan_json:($plan + ".json"), plan_sha256:$sha, commit:$commit,
      operator:"test-operator", state_lineage:$lineage, state_serial:$serial,
      safe_plan:"PASS", proposed_import_updates:0, non_noop_changes:0,
      terraform_version:"1.12.2", bucket:"b", state_key:"k",
      applied:false, apply_evidence:null, timestamp:"2026-10-27T00:00:00Z"}' > "$meta"
  printf 'GATE: PLATFORM-APPLY\nAPPROVER: test-operator\nCOMMIT: %s\nPLAN_SHA256: %s\n' "$commit" "$sha" > "$record"
}

run_apply() { # run_apply <plan> <meta> <record>
  "$repo_root/scripts/local/m1-platform-apply.sh" "$1" "$2" "$3" >"$work/out.log" 2>"$work/err.log"
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

echo "M1-LOCAL apply-guard behavioral tests passed"
