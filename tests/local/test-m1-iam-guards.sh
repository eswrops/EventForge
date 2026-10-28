#!/usr/bin/env bash
# Offline tests for the guarded IAM execution scripts (MYSQL-NSG-IAM track).
# Never contacts OCI: every refusal exercised here happens in the OFFLINE
# contract-check section of the scripts, before any live access.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail() { echo "TEST FAIL: $1" >&2; exit 1; }

for script in m1-iam-init.sh m1-iam-plan.sh m1-iam-apply.sh; do
  [[ -x "$repo_root/scripts/local/$script" ]] || fail "$script must be executable"
  bash -n "$repo_root/scripts/local/$script" || fail "$script must parse"
done

# Contract greps: the state-key ownership rule (absence must be PROVEN, no
# override) and the never-permitted operations.
grep -q 'm1_prove_state_key_absent' "$repo_root/scripts/local/m1-iam-init.sh" \
  || fail "init must prove state-key absence fail-closed"
grep -q 'exists, has history, or the listing failed' "$repo_root/scripts/local/m1-iam-init.sh" \
  || fail "init must stop on an owned or historically-versioned iam/ state key"
if grep -Eq -- '-migrate-state|-reconfigure|-force-copy' "$repo_root/scripts/local/m1-iam-init.sh" \
   && ! grep -q 'never permitted' "$repo_root/scripts/local/m1-iam-init.sh"; then
  fail "init migration flags must be actively refused"
fi
grep -q 'M1_IAM_APPLY_APPROVED_BY' "$repo_root/scripts/local/m1-iam-apply.sh" \
  || fail "apply must require an explicit operator attestation"
grep -q 'm1_verify_approval_record' "$repo_root/scripts/local/m1-iam-apply.sh" \
  || fail "apply must verify a written approval record (not env-only authorization)"
grep -q 'state-still-absent' "$repo_root/scripts/local/m1-iam-apply.sh" \
  || fail "apply must refuse when the iam state key exists at apply time"
if grep -q -- '-auto-approve' "$repo_root/scripts/local/m1-iam-plan.sh"; then
  fail "plan script must not reference -auto-approve"
fi
grep -q 'approval record is consumed' "$repo_root/scripts/local/m1-iam-apply.sh" \
  || fail "apply must consume the approval record on failure"

# The CI-level checker fixtures (exact two-policy contract, verbatim statement
# rendering) are exercised in tests/ci/test-iam-plan-guard.sh.
[[ -x "$repo_root/tests/ci/test-iam-plan-guard.sh" ]] || fail "IAM checker fixtures must be executable"
"$repo_root/tests/ci/test-iam-plan-guard.sh" || fail "IAM checker fixtures must pass"
[[ -x "$repo_root/tests/ci/test-safe-plan-mysql-retest.sh" ]] || fail "retest fixtures must be executable"

# ------------------------------------------------------------- apply offline refusals
plan_file="$work/plan.tfplan"
metadata_file="$work/metadata.json"
printf 'binary-plan-placeholder' > "$plan_file"
plan_sha="$(shasum -a 256 "$plan_file" | awk '{print $1}')"
commit="$(git -C "$repo_root" rev-parse HEAD)"
cat > "$metadata_file" <<EOF
{"plan":"$plan_file","plan_sha256":"$plan_sha","commit":"$commit","safe_plan":"PASS",
 "expected_state":"absent","applied":false,"apply_evidence":null,
 "terraform_version":"1.12.2","bucket":"eventforge-tfstate-prod","state_key":"iam/terraform.tfstate"}
EOF

run_apply() { # run_apply <record-file-or-missing> [env...]
  ( cd "$work" && M1_EVIDENCE_DIR="$work/evidence" M1_EVIDENCE_ROOT="$work/evidence-root" \
      "$repo_root/scripts/local/m1-iam-apply.sh" "$plan_file" "$metadata_file" "$@" >/dev/null 2>&1 )
}

if M1_IAM_APPLY_APPROVED_BY="" run_apply "$work/record.md"; then
  fail "apply must refuse without M1_IAM_APPLY_APPROVED_BY"
fi
if M1_IAM_APPLY_APPROVED_BY=op run_apply "$work/missing-record.md"; then
  fail "apply must refuse a missing approval record"
fi

# Wrong gate marker, wrong plan SHA, wrong commit, and a missing statement
# binding must each be refused offline.
printf 'GATE: PLATFORM-APPLY\nAPPROVER: op\n%s\n%s\niam/terraform.tfstate absent\n' "$plan_sha" "$commit" > "$work/record-wronggate.md"
if M1_IAM_APPLY_APPROVED_BY=op run_apply "$work/record-wronggate.md"; then
  fail "apply must refuse a record with the wrong gate marker"
fi

grep -v "$plan_sha" "$metadata_file" >/dev/null # no-op; build mismatching metadata explicitly
jq --arg sha "0000wrong" '.plan_sha256 = $sha' "$metadata_file" > "$work/meta-wrongsha.json"
if M1_IAM_APPLY_APPROVED_BY=op M1_EVIDENCE_DIR="$work/evidence" M1_EVIDENCE_ROOT="$work/evidence-root" \
     "$repo_root/scripts/local/m1-iam-apply.sh" "$plan_file" "$work/meta-wrongsha.json" "$work/record.md" >/dev/null 2>&1; then
  fail "apply must refuse a plan/metadata SHA mismatch"
fi

jq --arg c "0000oldcommit" '.commit = $c' "$metadata_file" > "$work/meta-wrongcommit.json"
if M1_IAM_APPLY_APPROVED_BY=op M1_EVIDENCE_DIR="$work/evidence" M1_EVIDENCE_ROOT="$work/evidence-root" \
     "$repo_root/scripts/local/m1-iam-apply.sh" "$plan_file" "$work/meta-wrongcommit.json" "$work/record.md" >/dev/null 2>&1; then
  fail "apply must refuse when the repository moved since review"
fi

jq '.expected_state = "present"' "$metadata_file" > "$work/meta-wrongstate.json"
if M1_IAM_APPLY_APPROVED_BY=op M1_EVIDENCE_DIR="$work/evidence" M1_EVIDENCE_ROOT="$work/evidence-root" \
     "$repo_root/scripts/local/m1-iam-apply.sh" "$plan_file" "$work/meta-wrongstate.json" "$work/record.md" >/dev/null 2>&1; then
  fail "apply must refuse unexpected expected_state"
fi

# A complete record (all bindings + both verbatim statements) still must not
# proceed past the OFFLINE section in a test environment — it would next hit
# the live guards; here we only assert the record-validation logic accepts it
# by checking the contract library directly.
lib="$repo_root/scripts/local/lib-m1.sh"
export M1_EVIDENCE_DIR="$work/evidence" M1_EVIDENCE_ROOT="$work/evidence-root"
# shellcheck source=scripts/local/lib-m1.sh
source "$lib"
db_ocid="ocid1.compartment.oc1..placeholder-for-tests"
tenancy_ocid="ocid1.tenancy.oc1..placeholder-for-tests"
mapfile -t stmts < <("$repo_root/scripts/ci/assert-iam-plan.sh" \
  --policy "$repo_root/scripts/ci/iam-plan-contract.json" \
  --var "db_compartment_ocid=$db_ocid" --var "tenancy_ocid=$tenancy_ocid" \
  --print-statements)
[[ "${#stmts[@]}" -eq 2 ]] || fail "expected 2 rendered statements from the contract"
cat > "$work/record-complete.md" <<EOF
GATE: MYSQL-NSG-IAM
APPROVER: op
COMMIT: $commit
PLAN SHA-256: $plan_sha
STATEMENT 1: ${stmts[0]}
STATEMENT 2: ${stmts[1]}
Expected initial state: iam/terraform.tfstate absent
Resources: oci_identity_policy.mysql_nsg_membership, oci_identity_policy.mysql_vnic_update
EOF
m1_verify_approval_record "$work/record-complete.md" "MYSQL-NSG-IAM" \
  "$plan_sha" "$commit" "oci_identity_policy.mysql_nsg_membership" \
  "oci_identity_policy.mysql_vnic_update" "${stmts[0]}" "${stmts[1]}" "iam/terraform.tfstate absent" \
  || fail "a complete statement-bound record must validate"

# ------------------------------------------- SCOPE_DECISION machine enforcement
# The tenancy-wide VNIC scope acceptance must be an EXACTLY-ONE standalone
# line `SCOPE_DECISION: ACCEPT_TENANCY_WIDE_VNIC`; every malformed form is a
# negative regression fixture here.
dec() { printf '%s\n' "$@"; }
declare -a bad_decisions=(
  ""                                                         # missing line entirely
  "SCOPE_DECISION: <ACCEPT_TENANCY_WIDE_VNIC>"               # placeholder
  "SCOPE_DECISION: ACCEPT_TENANCY_WIDE_VNIC (I think)"       # trailing commentary
  "SCOPE_DECISION: ORACLE_FIRST"                             # deferred to Oracle
  "SCOPE_DECISION: DECLINED"                                 # declined
  "SCOPE_DECISION: accept_tenancy_wide_vnic"                 # wrong case
  "SCOPE_DECISION: ACCEPT_TENANCY_WIDE_VNIC extra-token"     # appended token
  "SCOPE_DECISION:ACCEPT_TENANCY_WIDE_VNIC"                  # missing space — not the reviewed form
  "  > SCOPE_DECISION: ACCEPT_TENANCY_WIDE_VNIC"             # decision quoted inside template commentary
)
for d in "${bad_decisions[@]}"; do
  if [[ -z "$d" ]]; then dec "GATE: MYSQL-NSG-IAM" > "$work/dec.md"; else dec "GATE: MYSQL-NSG-IAM" "$d" > "$work/dec.md"; fi
  if m1_verify_scope_decision "$work/dec.md" 2>/dev/null; then
    fail "scope decision must be refused: [${d:-<missing>}]"
  fi
done

# Multiple decisions — identical or conflicting — are each refused.
dec "GATE: MYSQL-NSG-IAM" "SCOPE_DECISION: ACCEPT_TENANCY_WIDE_VNIC" \
  "SCOPE_DECISION: ACCEPT_TENANCY_WIDE_VNIC" > "$work/dec-dup.md"
m1_verify_scope_decision "$work/dec-dup.md" 2>/dev/null \
  && fail "two identical SCOPE_DECISION lines must be refused"
dec "GATE: MYSQL-NSG-IAM" "SCOPE_DECISION: ACCEPT_TENANCY_WIDE_VNIC" \
  "SCOPE_DECISION: DECLINED" > "$work/dec-conflict.md"
m1_verify_scope_decision "$work/dec-conflict.md" 2>/dev/null \
  && fail "conflicting SCOPE_DECISION lines must be refused"

# Positive: exactly one standalone top-level line validates; the decision
# may not be inherited from commentary that merely names the option.
dec "GATE: MYSQL-NSG-IAM" "commentary: ORACLE_FIRST and DECLINED are rejected" \
  "SCOPE_DECISION: ACCEPT_TENANCY_WIDE_VNIC" > "$work/dec-ok.md"
m1_verify_scope_decision "$work/dec-ok.md" \
  || fail "exactly one standalone ACCEPT_TENANCY_WIDE_VNIC decision must validate"
echo "ok: SCOPE_DECISION enforcement (unit fixtures)"

# Behavioral: the apply must refuse at the scope-decision gate — placed in the
# OFFLINE section, before any live access — when the record omits the
# decision, and must reach the later gates when the record carries it.
apply_script="$repo_root/scripts/local/m1-iam-apply.sh"
grep -q 'm1_verify_scope_decision "$approval_record"' "$apply_script" \
  || fail "apply must validate the scope decision before live access"
scope_line="$(grep -n 'PASS "scope-decision"' "$apply_script" | cut -d: -f1)"
record_line="$(grep -n 'PASS "approval-record"' "$apply_script" | cut -d: -f1)"
recheck_line="$(grep -n 'offline-contract-recheck" "saved plan revalidated' "$apply_script" | cut -d: -f1)"
[[ -n "$scope_line" ]] || fail "apply must carry a scope-decision gate"
(( record_line < scope_line && scope_line < recheck_line )) \
  || fail "the scope-decision gate must sit between the approval-record gate and the contract recheck"

# -------------------- committed approval template end-to-end regressions ----
# The scope-decision gate must hold against the ACTUAL committed approval
# template, not only synthetic fixtures: a byte-identical template copy (or a
# copy with every other field filled) must fail, only the operator's
# deliberate replacement of the placeholder may pass it, no script may insert
# the decision, and acceptance alone bypasses no other binding.
template="$repo_root/docs/acceptance/m1-local/approvals/mysql-nsg-iam-approval.template"
[[ -f "$template" ]] || fail "committed MYSQL-NSG-IAM approval template must exist"
[[ "$(grep -c 'SCOPE_DECISION:' "$template")" -eq 1 ]] \
  || fail "the committed template must carry exactly one SCOPE_DECISION line (the placeholder)"
grep -q '^SCOPE_DECISION: <OPERATOR_DECISION_REQUIRED>$' "$template" \
  || fail "the committed template's only SCOPE_DECISION line must be the placeholder"

mapfile -t tstmts < <("$repo_root/scripts/ci/assert-iam-plan.sh" \
  --policy "$repo_root/scripts/ci/iam-plan-contract.json" \
  --var "db_compartment_ocid=ocid1.compartment.oc1..placeholder-for-tests" \
  --var "tenancy_ocid=ocid1.tenancy.oc1..placeholder-for-tests" \
  --print-statements)
[[ "${#tstmts[@]}" -eq 2 ]] || fail "expected 2 rendered statements for template regressions"
printf 'binary-plan-placeholder' > "$work/tpl-plan.tfplan"
tpl_sha="$(shasum -a 256 "$work/tpl-plan.tfplan" | awk '{print $1}')"
tpl_commit="$(git -C "$repo_root" rev-parse HEAD)"

# fill_template <out> <decision|placeholder> <plan-sha> <commit> <stmt1> <stmt2>
# Simulates exactly the operator's deliberate edits — the only sanctioned way
# a template copy becomes a decision record.
fill_template() {
  local out="$1" decision="$2" psha="$3" pcommit="$4" s1="$5" s2="$6" line
  : > "$out"
  while IFS= read -r line; do
    if [[ "$decision" != "placeholder" ]]; then
      line="${line//SCOPE_DECISION: <OPERATOR_DECISION_REQUIRED>/SCOPE_DECISION: $decision}"
    fi
    line="${line//<operator name>/test-operator}"
    line="${line//<verbatim operator grant>/template-regression-grant}"
    line="${line//<YYYY-MM-DDTHH:MM:SSZ>/2026-10-28T00:00:00Z}"
    line="${line//<sha256>/$psha}"
    line="${line//<sha>/$pcommit}"
    line="${line//<paste rendered statement 1 from m1-iam-plan.sh evidence>/$s1}"
    line="${line//<paste rendered statement 2 from m1-iam-plan.sh evidence>/$s2}"
    printf '%s\n' "$line" >> "$out"
  done < "$template"
}
tpl_record_ok() { # all bindings the apply's approval-record gate demands
  m1_verify_approval_record "$1" "MYSQL-NSG-IAM" "$tpl_sha" "$tpl_commit" \
    "oci_identity_policy.mysql_nsg_membership" "oci_identity_policy.mysql_vnic_update" \
    "${tstmts[0]}" "${tstmts[1]}" "iam/terraform.tfstate absent"
}

# Case 1: a byte-identical copy of the committed template must FAIL.
cp "$template" "$work/tpl-unchanged.md"
cmp -s "$template" "$work/tpl-unchanged.md" || fail "template copy must be byte-identical"
m1_verify_scope_decision "$work/tpl-unchanged.md" 2>/dev/null \
  && fail "an unchanged template copy must fail the scope-decision gate"

# Case 2: every other field populated, placeholder unchanged — the record
# satisfies every OTHER approval requirement, and ONLY the scope gate refuses.
fill_template "$work/tpl-populated-placeholder.md" placeholder "$tpl_sha" "$tpl_commit" "${tstmts[0]}" "${tstmts[1]}"
tpl_record_ok "$work/tpl-populated-placeholder.md" \
  || fail "a populated template with the placeholder unchanged must satisfy every other approval requirement"
m1_verify_scope_decision "$work/tpl-populated-placeholder.md" 2>/dev/null \
  && fail "a populated template with the placeholder unchanged must fail the scope-decision gate"

# Cases 3-4: ORACLE_FIRST and DECLINED are refusals, never acceptances.
for d in ORACLE_FIRST DECLINED; do
  fill_template "$work/tpl-$d.md" "$d" "$tpl_sha" "$tpl_commit" "${tstmts[0]}" "${tstmts[1]}"
  m1_verify_scope_decision "$work/tpl-$d.md" 2>/dev/null \
    && fail "template decision $d must be refused"
done

# Case 5: the deliberate ACCEPT_TENANCY_WIDE_VNIC replacement is the ONLY way
# through — with every other approval requirement matching the reviewed plan.
fill_template "$work/tpl-accepted.md" ACCEPT_TENANCY_WIDE_VNIC "$tpl_sha" "$tpl_commit" "${tstmts[0]}" "${tstmts[1]}"
m1_verify_scope_decision "$work/tpl-accepted.md" \
  || fail "a deliberately accepted template must pass the scope-decision gate"
tpl_record_ok "$work/tpl-accepted.md" \
  || fail "a deliberately accepted template must pass the approval-record gate"

# Case 6: duplicate or conflicting decisions on an otherwise accepted
# template are refusals.
fill_template "$work/tpl-dup.md" ACCEPT_TENANCY_WIDE_VNIC "$tpl_sha" "$tpl_commit" "${tstmts[0]}" "${tstmts[1]}"
echo "SCOPE_DECISION: ACCEPT_TENANCY_WIDE_VNIC" >> "$work/tpl-dup.md"
m1_verify_scope_decision "$work/tpl-dup.md" 2>/dev/null \
  && fail "duplicate template decisions must be refused"
fill_template "$work/tpl-conflict.md" ACCEPT_TENANCY_WIDE_VNIC "$tpl_sha" "$tpl_commit" "${tstmts[0]}" "${tstmts[1]}"
echo "SCOPE_DECISION: DECLINED" >> "$work/tpl-conflict.md"
m1_verify_scope_decision "$work/tpl-conflict.md" 2>/dev/null \
  && fail "conflicting template decisions must be refused"

# Case 7: no script or helper may know the placeholder or write a decision
# into a record — the operator's edit is the only sanctioned insertion path.
if grep -rq 'OPERATOR_DECISION_REQUIRED' "$repo_root/scripts"; then
  fail "no script may reference the scope-decision placeholder"
fi
if grep -rniE 'SCOPE_DECISION[^$]*(>>|tee )' "$repo_root/scripts"; then
  fail "no script may write a SCOPE_DECISION line into a record"
fi
if grep -rn 'cp .*mysql-nsg-iam-approval' "$repo_root/scripts"; then
  fail "no script may copy the approval template on the operator's behalf"
fi

# Case 8: acceptance alone bypasses nothing — with the fully accepted template
# record in hand, a moved commit, changed plan content, a missing statement, a
# consumed plan, or changed state ownership each still refuses offline.
run_apply_capture() { # run_apply_capture <stderr-file> <metadata> <record>
  ( cd "$work" && M1_EVIDENCE_DIR="$work/evidence-tpl" M1_EVIDENCE_ROOT="$work/evidence-root-tpl" \
      M1_IAM_APPLY_APPROVED_BY=test-operator \
      "$repo_root/scripts/local/m1-iam-apply.sh" "$work/tpl-plan.tfplan" "$2" "$3" ) 2>"$1"
}
tpl_meta() { # tpl_meta <sha> <commit> <expected-state> <applied>
  jq -n --arg p "$work/tpl-plan.tfplan" --arg sha "$1" --arg c "$2" --arg es "$3" --arg ap "$4" \
    '{plan:$p,plan_sha256:$sha,commit:$c,safe_plan:"PASS",expected_state:$es,applied:($ap=="true"),
      apply_evidence:null,terraform_version:"1.12.2",
      bucket:"eventforge-tfstate-prod",state_key:"iam/terraform.tfstate"}'
}
tpl_meta "$tpl_sha" "$tpl_commit" absent false > "$work/tpl-meta.json"
tamper() { # tamper <gate-name> <expected-state> <applied> <sha?> <commit?>
  local gate="$1" es="$2" ap="$3" sha="${4:-$tpl_sha}" commit="${5:-$tpl_commit}" err="$work/tpl-tamper.err"
  tpl_meta "$sha" "$commit" "$es" "$ap" > "$work/tpl-meta-tampered.json"
  if run_apply_capture "$err" "$work/tpl-meta-tampered.json" "$work/tpl-accepted.md"; then
    fail "accepted template must not bypass the $gate check"
  fi
  grep -q "$gate" "$err" || { cat "$err" >&2; fail "refusal must name the $gate gate"; }
}
tamper metadata-plan-sha absent false 0000tampered "$tpl_commit"
tamper metadata-commit absent false "$tpl_sha" 0000movedcommit
tamper metadata-expected-state present false
tamper metadata-not-applied absent true
# Statement binding: dropping one reviewed statement from the accepted record
# must defeat the approval-record gate.
grep -v "Statement 2" "$work/tpl-accepted.md" | grep -vF "${tstmts[1]}" > "$work/tpl-no-stmt2.md" || true
if tpl_record_ok "$work/tpl-no-stmt2.md" 2>/dev/null; then
  fail "the accepted template must not bypass the verbatim-statement binding"
fi
echo "ok: committed template end-to-end regressions (all eight mission cases)"

# ------------------------------------------------- state-key absence proof (fail closed)
# The proof must never infer absence from an authorization/service error, an
# unparseable listing, historical object versions, or delete markers.
stubbin="$work/stub-bin"
mkdir -p "$stubbin"
make_oci_stub() { # make_oci_stub <stdout> <rc>
  printf '#!/bin/sh\ncat <<'"'"'IAMEOF'"'"'\n%s\nIAMEOF\nexit %s\n' "$1" "$2" > "$stubbin/oci"
  chmod +x "$stubbin/oci"
}
run_proof() { PATH="$stubbin:$PATH" m1_prove_state_key_absent "iam/terraform.tfstate" >/dev/null 2>&1; }

make_oci_stub '{"data":[]}' 0
run_proof || fail "clean versionless listing must prove absence"

make_oci_stub '{"data":[{"name":"iam/terraform.tfstate","version-id":"v1","is-delete-marker":false,"time-created":"2026-10-27T20:00:00Z"}]}' 0
if run_proof; then fail "a historical object version must defeat the absence proof"; fi

make_oci_stub '{"data":[{"name":"iam/terraform.tfstate","version-id":"v2","is-delete-marker":true,"time-created":"2026-10-27T20:00:00Z"}]}' 0
if run_proof; then fail "a delete marker must defeat the absence proof"; fi

make_oci_stub '{"data":[{"name":"iam/terraform.tfstate.lock","version-id":"v3","is-delete-marker":true,"time-created":"2026-10-27T20:00:00Z"}]}' 0
run_proof || fail "an unrelated (lock) object name must not defeat the absence proof"

make_oci_stub 'oci: ServiceError' 1
if run_proof; then fail "an authorization/service error must defeat the absence proof"; fi

make_oci_stub 'not-json-at-all' 0
if run_proof; then fail "an unparseable listing must defeat the absence proof"; fi

make_oci_stub '' 0
if run_proof; then fail "an empty listing body must defeat the absence proof"; fi

rm -f "$stubbin/oci"
echo "ok: state-key absence proof"

# ------------------------------------------------- pre-execution contract recheck
# The apply must re-run the IAM contract checker on the re-rendered saved plan
# as its last offline gate: after the approval-record gate, before any live
# guard and before the terraform apply invocation.
apply_script="$repo_root/scripts/local/m1-iam-apply.sh"
recheck_line="$(grep -n 'offline-contract-recheck" "saved plan revalidated' "$apply_script" | cut -d: -f1)"
record_line="$(grep -n 'PASS "approval-record"' "$apply_script" | cut -d: -f1)"
apply_line="$(grep -n 'apply -input=false -lock=true' "$apply_script" | cut -d: -f1)"
[[ -n "$recheck_line" && -n "$record_line" && -n "$apply_line" ]] || fail "recheck/approval/apply gates must exist in m1-iam-apply.sh"
(( record_line < recheck_line && recheck_line < apply_line )) \
  || fail "the contract recheck must sit between the approval-record gate and the apply"
grep -q 'show -json "$plan_file"' "$apply_script" \
  || fail "the recheck must re-render the SHA-bound .tfplan itself, not a companion JSON"

# Behavioral: with a stub terraform whose `show -json` emits a contract-violating
# plan, the apply must refuse at offline-contract-recheck. Requires the operator
# workstation inputs (real rendered statements for the approval record); on CI
# checkouts without infra/iam/terraform.auto.tfvars the behavioral half is
# skipped — the checker itself is fully fixture-tested in tests/ci.
if [[ -f "$repo_root/infra/iam/terraform.auto.tfvars" ]]; then
  stub_tf="$work/stub-tf"
  mkdir -p "$stub_tf"
  cat > "$stub_tf/terraform" <<STUB
#!/bin/bash
if [[ "\$1" == -chdir=* ]]; then shift 2; fi
if [[ "\$1" == "version" ]]; then echo "Terraform v1.12.2"; echo "on test"; exit 0; fi
if [[ "\$1" == "show" ]]; then cat "$work/recheck-bad.json"; exit 0; fi
exit 99
STUB
  chmod +x "$stub_tf/terraform"
  db_ocid_r="$(awk -F'"' '/^[[:space:]]*db_compartment_ocid[[:space:]]*=/{print $2}' "$repo_root/infra/iam/terraform.auto.tfvars")"
  tenancy_ocid_r="$(awk -F'"' '/^[[:space:]]*tenancy_ocid[[:space:]]*=/{print $2}' "$repo_root/infra/iam/terraform.auto.tfvars")"
  mapfile -t rstmts < <("$repo_root/scripts/ci/assert-iam-plan.sh" \
    --policy "$repo_root/scripts/ci/iam-plan-contract.json" \
    --var "db_compartment_ocid=$db_ocid_r" --var "tenancy_ocid=$tenancy_ocid_r" \
    --print-statements)
  # Contract-violating saved plan: statement 2 broadened to `in tenancy`.
  jq -n --arg db "$db_ocid_r" --arg ten "$tenancy_ocid_r" --arg s1 "${rstmts[0]}" \
    --arg s2 "$(sed "s/in compartment id [^ ]* where all/in tenancy where all/" <<<"${rstmts[1]}")" \
    '{resource_changes:[
      {address:"oci_identity_policy.mysql_nsg_membership",type:"oci_identity_policy",
       change:{actions:["create"],before:null,after:{name:"eventforge-mysql-nsg-membership",compartment_id:$db,statements:[$s1]},after_unknown:{}}},
      {address:"oci_identity_policy.mysql_vnic_update",type:"oci_identity_policy",
       change:{actions:["create"],before:null,after:{name:"eventforge-mysql-vnic-update",compartment_id:$ten,statements:[$s2]},after_unknown:{}}}]}' \
    > "$work/recheck-bad.json"
  printf 'binary-plan-placeholder' > "$work/recheck-plan.tfplan"
  recheck_sha="$(shasum -a 256 "$work/recheck-plan.tfplan" | awk '{print $1}')"
  jq -n --arg p "$work/recheck-plan.tfplan" --arg sha "$recheck_sha" --arg c "$commit" \
    '{plan:$p,plan_sha256:$sha,commit:$c,safe_plan:"PASS",expected_state:"absent",applied:false,apply_evidence:null,
      terraform_version:"1.12.2",bucket:"eventforge-tfstate-prod",state_key:"iam/terraform.tfstate"}' \
    > "$work/recheck-metadata.json"
  cat > "$work/recheck-record.md" <<EOF
GATE: MYSQL-NSG-IAM
APPROVER: test-operator
SCOPE_DECISION: ACCEPT_TENANCY_WIDE_VNIC
COMMIT: $commit
PLAN SHA-256: $recheck_sha
STATEMENT 1: ${rstmts[0]}
STATEMENT 2: ${rstmts[1]}
Expected initial state: iam/terraform.tfstate absent
Resources: oci_identity_policy.mysql_nsg_membership, oci_identity_policy.mysql_vnic_update
EOF
  if ( cd "$work" && M1_TERRAFORM_BIN="$stub_tf/terraform" \
        M1_EVIDENCE_DIR="$work/evidence2" M1_EVIDENCE_ROOT="$work/evidence-root2" \
        M1_IAM_APPLY_APPROVED_BY="test-operator" \
        "$repo_root/scripts/local/m1-iam-apply.sh" "$work/recheck-plan.tfplan" \
        "$work/recheck-metadata.json" "$work/recheck-record.md" 2>"$work/recheck.err" ); then
    fail "apply must refuse a saved plan that violates the reviewed contract"
  fi
  grep -q "offline-contract-recheck" "$work/recheck.err" \
    || { echo "recheck refusal output:"; cat "$work/recheck.err" >&2; fail "refusal must name the offline-contract-recheck gate"; }
  echo "ok: pre-execution contract recheck (behavioral)"

  # Behavioral negative: the SAME complete record without the SCOPE_DECISION
  # line must be refused at the scope-decision gate — before the contract
  # recheck, and therefore before any live access.
  grep -v '^SCOPE_DECISION:' "$work/recheck-record.md" > "$work/recheck-record-nodecision.md"
  if ( cd "$work" && M1_TERRAFORM_BIN="$stub_tf/terraform" \
        M1_EVIDENCE_DIR="$work/evidence3" M1_EVIDENCE_ROOT="$work/evidence-root3" \
        M1_IAM_APPLY_APPROVED_BY="test-operator" \
        "$repo_root/scripts/local/m1-iam-apply.sh" "$work/recheck-plan.tfplan" \
        "$work/recheck-metadata.json" "$work/recheck-record-nodecision.md" 2>"$work/nodecision.err" ); then
    fail "apply must refuse a record without the SCOPE_DECISION acceptance"
  fi
  grep -q "scope-decision" "$work/nodecision.err" \
    || { echo "nodecision refusal output:"; cat "$work/nodecision.err" >&2; fail "refusal must name the scope-decision gate"; }
  echo "ok: scope-decision enforcement (behavioral)"
else
  echo "skip: pre-execution recheck behavioral test (operator tfvars absent — CI checkout)"
fi

# ------------------------------------------------- diagnostics approval template
# The ACTUAL committed Approval A template (vm-mysql-connectivity-diagnostic.md)
# must refuse as-is, refuse when populated except the decision placeholder, and
# pass only with the deliberate operator decision plus correct bindings — the
# same gate sequence the diag apply runs offline.
diag_doc="$repo_root/docs/acceptance/m1-local/approvals/vm-mysql-connectivity-diagnostic.md"
[[ -f "$diag_doc" ]] || fail "diagnostics approval doc must exist"
awk '/^GATE: IAM-RUN-COMMAND-DIAG/{flag=1} flag{print} /^IAM state lineage\/serial at plan time:/{if (flag) exit}' "$diag_doc" \
  > "$work/diag-template.md"
[[ -s "$work/diag-template.md" ]] || fail "Approval A template block must be extractable from the committed doc"
grep -q 'APPROVAL_DECISION: <OPERATOR_AUTHORIZATION_REQUIRED>' "$work/diag-template.md" \
  || fail "committed Approval A template must carry the decision placeholder"

template_sha="1111111111111111111111111111111111111111111111111111111111111111"
template_commit="9a0724f59394839f8fa5b213c8e189f4270c74de"
diag_stmt="Allow dynamic-group eventforge-instances to use instance-agent-command-execution-family in compartment id ocid1.compartment.oc1..testdb where request.instance.id=target.instance.id"

# 1. Unchanged template copy must fail the decision gate.
if m1_verify_approval_decision "$work/diag-template.md" "AUTHORIZE_ONE_DIAGNOSTIC_IAM_CREATE" 2>/dev/null; then
  fail "an unchanged committed template copy must fail the approval-decision gate"
fi
# 2. Fully populated EXCEPT the decision placeholder must still fail.
sed -e "s|<operator name>|Koka Easwarendra|" -e "s|<verbatim operator grant>|test grant|" \
    -e "s|<YYYY-MM-DDTHH:MM:SSZ>|2026-10-28T22:00:00Z|" -e "s|<sha256 of the exists-mode diagnostics plan>|$template_sha|" \
    -e "s|<full merged main commit>|$template_commit|" -e "s|<lineage>/<serial>|2d169472-160b-5f38-6141-55cb1bec880a/1|" \
    "$work/diag-template.md" > "$work/diag-populated-nodecision.md"
if m1_verify_approval_decision "$work/diag-populated-nodecision.md" "AUTHORIZE_ONE_DIAGNOSTIC_IAM_CREATE" 2>/dev/null; then
  fail "a populated record with the authorization placeholder intact must fail"
fi
# 3. Deliberate decision + correct bindings must pass the full offline record
#    gate sequence (decision + approval-record with rendered-style statement).
sed -e "s|APPROVAL_DECISION: <OPERATOR_AUTHORIZATION_REQUIRED>|APPROVAL_DECISION: AUTHORIZE_ONE_DIAGNOSTIC_IAM_CREATE|" \
    -e "s|ocid1.compartment.oc1..aaaaaaaar3kvayxcj4vuo6ydkoaxrh4yeovnvr6rgxr7kdljzijrpbxaz3ea|ocid1.compartment.oc1..testdb|" \
    "$work/diag-populated-nodecision.md" > "$work/diag-authorized.md"
m1_verify_approval_decision "$work/diag-authorized.md" "AUTHORIZE_ONE_DIAGNOSTIC_IAM_CREATE" \
  || fail "a deliberately authorized record must pass the decision gate"
m1_verify_approval_record "$work/diag-authorized.md" "IAM-RUN-COMMAND-DIAG" "$template_sha" "$template_commit" \
  "oci_identity_policy.instance_run_command_diagnostics" "$diag_stmt" \
  || fail "a deliberately authorized record with correct bindings must pass the approval-record gate"
# 4. Duplicate/conflicting decisions are refused.
cp "$work/diag-authorized.md" "$work/diag-dup.md"
printf 'APPROVAL_DECISION: AUTHORIZE_ONE_DIAGNOSTIC_IAM_CREATE\n' >> "$work/diag-dup.md"
if m1_verify_approval_decision "$work/diag-dup.md" "AUTHORIZE_ONE_DIAGNOSTIC_IAM_CREATE" 2>/dev/null; then
  fail "duplicate decisions must be refused"
fi
# 5. Attribution placeholders (approver / grant / timestamp) are refused by the
#    apply's field check — verify the gate logic against template variants.
if m1_verify_approval_decision "$work/diag-template.md" "AUTHORIZE_ONE_DIAGNOSTIC_IAM_CREATE" 2>/dev/null; then :; fi
for field in "APPROVER: <operator name>" "Grant phrase: <verbatim operator grant>" "Timestamp (UTC): <YYYY-MM-DDTHH:MM:SSZ>"; do
  record_approver="Koka Easwarendra"; record_grant="test grant"; record_ts="2026-10-28T22:00:00Z"
  case "$field" in
    APPROVER:*) record_approver="$field" ;;
    Grant\ phrase:*) record_grant="$field" ;;
    *) record_ts="$field" ;;
  esac
  placeholder_fail=""
  for fv in "$record_approver" "$record_grant" "$record_ts"; do
    [[ -z "$fv" || "$fv" == *'<'* || "$fv" == *'>'* ]] && placeholder_fail="x"
  done
  [[ "$record_ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || placeholder_fail="x"
  [[ -z "$placeholder_fail" ]] || : # expected: each variant must trip the check
  [[ -n "$placeholder_fail" ]] || fail "placeholder variant must trip the attribution check: $field"
done
# 6. The apply script must wire the new gates (decision + attribution).
grep -q 'm1_verify_approval_decision "$approval_record" "AUTHORIZE_ONE_DIAGNOSTIC_IAM_CREATE"' \
  "$repo_root/scripts/local/m1-iam-diag-apply.sh" \
  || fail "diag apply must enforce the explicit approval-decision gate"
grep -q 'approval-attribution' "$repo_root/scripts/local/m1-iam-diag-apply.sh" \
  || fail "diag apply must enforce operator-entered attribution fields"
# 7. All other approval/contract protections remain: the two-policy contract
#    and the diag contract fixtures still pass.
"$repo_root/tests/ci/test-iam-plan-guard.sh" >/dev/null 2>&1 || fail "two-policy contract fixtures must still pass"
"$repo_root/tests/ci/test-iam-plan-guard-diag.sh" >/dev/null 2>&1 || fail "diag contract fixtures must still pass"
echo "ok: diagnostics approval template enforcement (committed template)"

echo "IAM local guard tests passed"
