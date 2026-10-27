#!/usr/bin/env bash
# M1-LOCAL Phase 3 — import execution (RUNS ONLY AFTER OCI-IMPORT APPROVAL).
#
#   M1_IMPORT_APPROVED_BY="<approver as written in the record>" \
#   [M1_EXTRA_VAR_FILE=/path/to/0600-vault-vars.tfvars] \
#   scripts/local/m1-platform-imports.sh
#
# Authorization is NOT granted by the environment variable alone: the committed
# approval record docs/acceptance/m1-local/approvals/oci-import-approval.md
# must exist, carry the "GATE: OCI-IMPORT" marker, this exact commit, all eight
# addresses, and an APPROVER: line matching M1_IMPORT_APPROVED_BY.
#
# Imports the eight reviewed existing resources into platform/terraform.tfstate
# in dependency order, one at a time, verifying each state entry before the
# next. Imports change only Terraform state — never OCI resources. No apply,
# no retry (rule 11), no state recovery, locking retained throughout.
set -uo pipefail

# shellcheck source=scripts/local/lib-m1.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-m1.sh"

if [[ -z "${M1_IMPORT_APPROVED_BY:-}" ]]; then
  echo "Refusing to import: set M1_IMPORT_APPROVED_BY to the APPROVER recorded in docs/acceptance/m1-local/approvals/oci-import-approval.md" >&2
  exit 1
fi

m1_init_evidence
m1_evidence_record "import execution start (run $M1_RUN_TAG) approved by: $M1_IMPORT_APPROVED_BY"

root="$M1_REPO_ROOT/infra/platform"
backend_hcl="$root/backend.hcl"
approval_record="$M1_REPO_ROOT/docs/acceptance/m1-local/approvals/oci-import-approval.md"

fail_gate() { m1_check FAIL "$1" "${*:2}"; m1_evidence_record "GATE FAIL: $1"; m1_exit_gate_failed; }
note() { printf 'NOTE  %s\n' "$*"; }

commit="$(git -C "$M1_REPO_ROOT" rev-parse HEAD)"

# Approval record gate (not env-var-only authorization) ----------------------
if m1_verify_approval_record "$approval_record" "OCI-IMPORT" \
     "$commit" \
     "oci_core_vcn.existing" "oci_core_subnet.app" "oci_core_subnet.lb" "oci_core_subnet.mysql" \
     'oci_core_instance.api["vm1"]' 'oci_core_instance.api["vm2"]' \
     "oci_mysql_mysql_db_system.existing" "oci_load_balancer_load_balancer.existing"; then
  record_approver="$(awk -F': ' '/^APPROVER:/{print $2; exit}' "$approval_record")"
  [[ "$record_approver" == "$M1_IMPORT_APPROVED_BY" ]] \
    && m1_check PASS "approval-record" "OCI-IMPORT approved by $record_approver (commit-bound)" \
    || fail_gate approval-record "M1_IMPORT_APPROVED_BY does not match the record's APPROVER line"
else
  fail_gate approval-record \
    "invalid or missing approval record ($approval_record): it must contain 'GATE: OCI-IMPORT', commit $commit, all eight addresses, and an APPROVER: line"
fi

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
m1_verify_workspace_default "$M1_TERRAFORM_BIN" "$root" \
  && m1_check PASS "workspace-default" "default" \
  || fail_gate workspace-default "non-default workspace"

# MySQL admin credentials: prefer a protected operator-local secret source
# (M1_EXTRA_VAR_FILE, outside the repository, mode 0600). A repo-local
# terraform.tfvars is a checked last resort: mode 0600, git-ignored, never
# logged. Values are never displayed by this script.
var_args=()
if [[ -n "${M1_EXTRA_VAR_FILE:-}" ]]; then
  [[ -f "$M1_EXTRA_VAR_FILE" ]] || fail_gate mysql-credentials "M1_EXTRA_VAR_FILE does not exist: $M1_EXTRA_VAR_FILE"
  perms="$(stat -f '%Lp' "$M1_EXTRA_VAR_FILE")"
  [[ "$perms" == "600" || "$perms" == "400" ]] \
    || fail_gate mysql-credentials "M1_EXTRA_VAR_FILE must be mode 0600 (got $perms): $M1_EXTRA_VAR_FILE"
  case "$M1_EXTRA_VAR_FILE" in
    "$M1_REPO_ROOT"|"$M1_REPO_ROOT"/*)
      fail_gate mysql-credentials "M1_EXTRA_VAR_FILE must live outside the repository (protected operator source, e.g. /Users/eswr/secure/secrets/)" ;;
  esac
  if git -C "$M1_REPO_ROOT" ls-files --error-unmatch "$M1_EXTRA_VAR_FILE" >/dev/null 2>&1; then
    fail_gate mysql-credentials "M1_EXTRA_VAR_FILE is tracked by Git"
  fi
  grep -q '^mysql_admin_username' "$M1_EXTRA_VAR_FILE" \
    || fail_gate mysql-credentials "M1_EXTRA_VAR_FILE lacks mysql_admin_username"
  grep -q '^mysql_admin_password' "$M1_EXTRA_VAR_FILE" \
    || fail_gate mysql-credentials "M1_EXTRA_VAR_FILE lacks mysql_admin_password"
  var_args=(-var-file="$M1_EXTRA_VAR_FILE")
  m1_check PASS "mysql-credentials" "operator secret source loaded ($(basename "$M1_EXTRA_VAR_FILE"), contents never displayed)"
elif [[ -f "$root/terraform.tfvars" ]]; then
  perms="$(stat -f '%Lp' "$root/terraform.tfvars")"
  [[ "$perms" == "600" || "$perms" == "400" ]] \
    || fail_gate mysql-credentials "repo terraform.tfvars must be mode 0600 (got $perms)"
  grep -q '^mysql_admin_username' "$root/terraform.tfvars" \
    || fail_gate mysql-credentials "terraform.tfvars must carry operator-vault MySQL admin values before importing (write-only; never logged)"
  var_args=()
  m1_check PASS "mysql-credentials" "repo terraform.tfvars (last resort; mode 0600 verified)"
else
  fail_gate mysql-credentials \
    "no MySQL credential source: set M1_EXTRA_VAR_FILE to a 0600 operator-vault var file (preferred) or create 0600 git-ignored infra/platform/terraform.tfvars"
fi

# Import plan: address<TAB>OCID, dependency order (VCN → subnets → VMs → MySQL → LB).
# OCIDs are the reviewed ones reconciled live in Phase 2 (imports.md).
imports=(
  'oci_core_vcn.existing	ocid1.vcn.oc1.ap-hyderabad-1.amaaaaaatiosumiaz4zvhbqaopq7ljp4yq7gftrwdy2zmveizdmv62xvd6ca'
  'oci_core_subnet.app	ocid1.subnet.oc1.ap-hyderabad-1.aaaaaaaawemcohc6vzzqwkv3hbq3mcpl3wf3bslzb5wmheixtitqcoqiddra'
  'oci_core_subnet.lb	ocid1.subnet.oc1.ap-hyderabad-1.aaaaaaaargdyoju3emyheunr6di75z2tl74khyf7tem6hwj5x5tmxt44q2bq'
  'oci_core_subnet.mysql	ocid1.subnet.oc1.ap-hyderabad-1.aaaaaaaaipwpkmvnxdzw2yduccugoq6pkojn7lpd3izpewyusyvi7ywp7ewa'
  'oci_core_instance.api["vm1"]	ocid1.instance.oc1.ap-hyderabad-1.anuhsljrtiosumiceyilvbiclo7kynsdnzozmoeziwmsjdrhdwigvw5ibc4a'
  'oci_core_instance.api["vm2"]	ocid1.instance.oc1.ap-hyderabad-1.anuhsljrtiosumicl5kpn6r7suoqgn4osm6pu3r7rrszwib3yuaeb65x7ooa'
  'oci_mysql_mysql_db_system.existing	ocid1.mysqldbsystem.oc1.ap-hyderabad-1.aaaaaaaaes3clz2baohp34kuulobnhrp3cnz33bicso6r4syj7npztnvj2gq'
  'oci_load_balancer_load_balancer.existing	ocid1.loadbalancer.oc1.ap-hyderabad-1.aaaaaaaa4by2dj7zniovxz327ieyws33wcsxfu2rcu6dasnuk5f6yljmihvq'
)

state_file="$M1_EVIDENCE_DIR/state/platform-post-imports.tfstate"

import_index=0
for row in "${imports[@]}"; do
  import_index=$((import_index + 1))
  address="${row%%	*}"
  ocid="${row#*	}"
  echo "--- import $address"

  # Raw state JSON has no top-level address; rebuild it from type/name and the
  # instance index_key (map keys are quoted, e.g. oci_core_instance.api["vm1"]).
  addr_of() { # addr_of <state-json> <address> → prints the resource's real OCI id
    jq -r --arg a "$2" '
      .resources[]
      | . as $r
      | $r.instances[]
      | (if (has("index_key") and .index_key != null)
          then "\($r.type).\($r.name)[\(.index_key | tojson)]"
          else "\($r.type).\($r.name)" end) as $addr
      | select($addr == $a)
      | .attributes.id // empty
    ' "$1" | head -1
  }

  exists_in_state="$("$M1_TERRAFORM_BIN" -chdir="$root" state list 2>/dev/null | grep -cFx "$address" || true)"

  if [[ "$exists_in_state" -ge 1 ]]; then
    # Partially completed earlier run: accept ONLY if the recorded ID matches
    # the reviewed OCID exactly; never import twice.
    pulled_probe="$M1_EVIDENCE_DIR/state/platform-resume-probe.json"
    "$M1_TERRAFORM_BIN" -chdir="$root" state pull > "$pulled_probe" 2>/dev/null && chmod 600 "$pulled_probe"
    existing_id="$(addr_of "$pulled_probe" "$address")"
    [[ "$existing_id" == "$ocid" ]] \
      || fail_gate "import-duplicate" \
           "$address already in state with a DIFFERENT id ($existing_id) — refusing; operator must reconcile manually"
    m1_check PASS "import-$address" "already imported by a prior partial run; state ID verified against the reviewed OCID"
    m1_evidence_record "resume: $address already in state, id verified = $ocid"
    continue
  fi
  [[ "$exists_in_state" -eq 0 ]] || fail_gate "import-duplicate" "multiple state entries for $address"

  import_log="$M1_EVIDENCE_DIR/logs/import-$(echo "$address" | tr -c 'a-zA-Z0-9._-' '_').log"
  if ! "$M1_TERRAFORM_BIN" -chdir="$root" import -input=false -lock=true "${var_args[@]}" "$address" "$ocid" >"$import_log" 2>&1; then
    tail -30 "$import_log" >&2
    fail_gate "import-$address" \
      "import FAILED — STOP (rule 11): preserve $import_log; the failure may be recorded in remote state; inspect before any operator decision"
  fi

  # Verify the state entry and that the real OCI ID was recorded.
  pulled="$M1_EVIDENCE_DIR/state/platform-after-$(echo "$address" | tr -c 'a-zA-Z0-9._-' '_').json"
  if ! "$M1_TERRAFORM_BIN" -chdir="$root" state pull > "$pulled" 2>>"$import_log" || [[ ! -s "$pulled" ]]; then
    fail_gate "import-verify-$address" "state pull failed right after importing $address"
  fi
  chmod 600 "$pulled"
  real_id="$(addr_of "$pulled" "$address")"
  [[ "$real_id" == "$ocid" ]] \
    || fail_gate "import-verify-$address" "state entry ID mismatch: got ${real_id:-<none>}"
  dupes="$("$M1_TERRAFORM_BIN" -chdir="$root" state list 2>/dev/null | grep -cFx "$address")"
  [[ "$dupes" -eq 1 ]] || fail_gate "import-verify-$address" "duplicate state address after import"

  # Preserve the current remote state version (object versioning is on in the
  # bucket; this is an additional local snapshot per import).
  history_dir="$M1_EVIDENCE_DIR/state/platform-post-imports-history"
  mkdir -p "$history_dir"
  cp "$pulled" "$history_dir/$(printf '%02d' "$import_index")-$address.json"
  m1_check PASS "import-$address" "state entry verified, real OCI ID recorded"
  m1_evidence_record "imported $address = $ocid"
done

cp "$pulled" "$state_file"

# Refresh-only reconciliation -------------------------------------------------
refresh_json="$M1_EVIDENCE_DIR/plans/post-import-refresh.json"
if "$M1_TERRAFORM_BIN" -chdir="$root" plan -refresh-only -input=false -lock=true \
     -out="$M1_EVIDENCE_DIR/plans/post-import-refresh.tfplan" >"$M1_EVIDENCE_DIR/logs/post-import-refresh.log" 2>&1 \
   && "$M1_TERRAFORM_BIN" -chdir="$root" show -json "$M1_EVIDENCE_DIR/plans/post-import-refresh.tfplan" > "$refresh_json" 2>/dev/null; then
  drift="$(jq -r '(.resource_changes // [])[] | select(.change.actions != ["no-op"]) | "\(.address): \(.change.actions | join(","))"' "$refresh_json")"
  if [[ -z "$drift" ]]; then
    m1_check PASS "post-import-reconciliation" "refresh-only: clean (no resource changes)"
  else
    fail_gate post-import-reconciliation "drift reported — investigate every line before any normal plan:"$'\n'"$drift"
  fi
else
  fail_gate post-import-reconciliation "refresh-only plan failed — inspect logs/post-import-refresh.log"
fi

m1_evidence_record "all eight imports verified; reconciliation clean"
echo "Import phase complete — evidence in $M1_EVIDENCE_DIR"
echo "Next: scripts/local/m1-platform-plan.sh (never applying it before review)"
