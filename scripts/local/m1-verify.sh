#!/usr/bin/env bash
# M1-LOCAL verification — READ-ONLY live acceptance after apply (or any time).
# Verifies NSGs/rules, existing-resource safety, ingress-disabled, alarms,
# budget, state inventory, and produces a read-only drift assessment
# (terraform plan -refresh-only, never applied).
# A failed OCI listing is NEVER treated as absence (fail closed).
set -uo pipefail

# shellcheck source=scripts/local/lib-m1.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-m1.sh"

# Counters live in the sourced library; re-declared here for shellcheck.
m1_pass_count="${m1_pass_count:-0}"
m1_fail_count="${m1_fail_count:-0}"

m1_init_evidence
m1_evidence_record "verify start (run $M1_RUN_TAG)"

root="$M1_REPO_ROOT/infra/platform"
state_pull="$M1_EVIDENCE_DIR/state/platform-verify-pull.tfstate"
# Pre-initialized so shellcheck sees the printf -v targets; read_oci_json
# always assigns (empty on failure).
nsg_list_json="" one_rules_json="" rules_json="" vm_json="" mysql_json=""
lb_json="" lb_get_json="" alarms_json="" budgets_json="" alerts_json=""

fail_gate() { m1_check FAIL "$1" "${*:2}"; m1_evidence_record "GATE FAIL: $1"; }
note() { printf 'NOTE  %s\n' "$*"; }

# Every live read goes through here: valid JSON or an explicit failure.
# CLI 3.95 prints NOTHING (rc=0) for a list command with zero items — that is
# an empty dataset, not a failure. Non-zero rc or non-JSON output fails closed.
read_oci_json() { # read_oci_json <varname> <oci args...>
  local __var="$1"; shift
  local out
  out="$(oci "$@" "${M1_OCI_REGION_ARGS[@]}" 2>/dev/null)" || { printf -v "$__var" ''; return 1; }
  if [[ -z "$out" ]]; then
    printf -v "$__var" '{"data":[]}'
    return 0
  fi
  if ! jq -e . >/dev/null 2>&1 <<<"$out"; then
    printf -v "$__var" ''
    return 1
  fi
  printf -v "$__var" '%s' "$out"
}

# Base guards -----------------------------------------------------------------
m1_verify_terraform_bin \
  && m1_check PASS "terraform-pinned" "v$M1_TERRAFORM_VERSION" \
  || fail_gate terraform-pinned "wrong binary"
m1_verify_auth_mode \
  && m1_check PASS "auth-apikey-profile" "profile $M1_OCI_PROFILE" \
  || fail_gate auth-apikey-profile "invalid authentication"
m1_verify_locking_retained "$@" \
  && m1_check PASS "locking-retained" "locking retained" \
  || fail_gate locking-retained "lock disabling refused"
if [[ -d "$root/.terraform" ]]; then
  m1_verify_workspace_default "$M1_TERRAFORM_BIN" "$root" \
    && m1_check PASS "workspace-default" "default" \
    || fail_gate workspace-default "non-default workspace"
else
  note "workspace check pending platform init"
fi

compartment="$(awk -F'=' '/^compartment_ocid/{gsub(/[ "]/,"",$2); print $2}' "$root/terraform.auto.tfvars" 2>/dev/null)"
vcn="$(awk -F'=' '/^vcn_ocid/{gsub(/[ "]/,"",$2); print $2}' "$root/terraform.auto.tfvars" 2>/dev/null)"
vcn_compartment_root="$(awk -F'=' '/^tenancy_ocid/{gsub(/[ "]/,"",$2); print $2}' "$root/terraform.auto.tfvars" 2>/dev/null)"
live_ready=1
if [[ -z "$compartment" || -z "$vcn" ]]; then
  live_ready=0
  note "ignored infra/platform/terraform.auto.tfvars lacks compartment/VCN coordinates — live checks skipped (expected before Phase 2 preparation)"
fi

if [[ "$live_ready" -eq 1 ]]; then
  # 1–2. NSGs, rules, and public exposure -------------------------------------
  # Rules are listed PER NSG (--nsg-id); results are aggregated.
  nsg_fail=""
  nsg_ocids=()
  nsg_listing_ok=1
  read_oci_json nsg_list_json network nsg list --compartment-id "$compartment" || nsg_listing_ok=0
  if [[ "$nsg_listing_ok" -eq 1 ]]; then
    for nsg in lb app db; do
      ocid="$(jq -r --arg n "eventforge-${nsg}-nsg" \
        '[.data[]? | select(."display-name" == $n and ."lifecycle-state" == "AVAILABLE")][0].id // empty' \
        <<<"$nsg_list_json")"
      if [[ -n "$ocid" ]]; then
        nsg_ocids+=("$ocid")
      else
        nsg_fail+="eventforge-${nsg}-nsg missing/not-AVAILABLE "
      fi
    done
  else
    fail_gate nsgs "NSG listing failed (auth/permission) — not treated as absence"
  fi
  if [[ "$nsg_listing_ok" -eq 1 ]]; then
    if [[ -z "$nsg_fail" ]]; then
      m1_check PASS "nsgs" "lb/app/db NSGs AVAILABLE"
    elif [[ "${#nsg_ocids[@]}" -eq 0 ]]; then
      note "no eventforge NSGs yet (expected pre-apply; PLATFORM-APPLY creates them)"
    else
      fail_gate nsgs "PARTIAL APPLY: $nsg_fail"
    fi
  fi

  # Aggregate rules across the expected NSGs (empty pre-apply is a valid result).
  rules_json='{"data":[]}'
  rules_ok=1
  if [[ "${#nsg_ocids[@]}" -eq 3 ]]; then
    for id in "${nsg_ocids[@]}"; do
      if read_oci_json one_rules_json network nsg rules list --nsg-id "$id"; then
        rules_json="$(jq -n --argjson a "$rules_json" --argjson b "$one_rules_json" '{data: ($a.data + $b.data)}')"
      else
        rules_ok=0
      fi
    done
  fi

  if [[ "$rules_ok" -eq 1 && "${#nsg_ocids[@]}" -eq 3 ]]; then
    rules_total="$(jq '[.data[]?] | length' <<<"$rules_json")"
    rules_lb_app="$(jq '[.data[]? | select(."description" == "API traffic only from EventForge load balancer")] | length' <<<"$rules_json")"
    [[ "${rules_lb_app:-0}" -ge 1 ]] \
      && m1_check PASS "nsg-rules" "$rules_total NSG rules; LB→app ingress present" \
      || { [[ "$rules_total" -eq 0 ]] \
            && note "no NSG rules yet (expected pre-apply)" \
            || fail_gate nsg-rules "expected NSG rules missing ($rules_total total)"; }
    public_exposure="$(jq -r '
      [.data[]?
       | select(."source-type" == "CIDR_BLOCK" and ."source" == "0.0.0.0/0")
       | select((."tcp-options"."destination-port-range"."min" == 8080)
             or (."tcp-options"."destination-port-range"."max" == 8080)
             or (."tcp-options"."destination-port-range"."min" == 3306)
             or (."tcp-options"."destination-port-range"."max" == 3306))
       | ."description"] | join(",")' <<<"$rules_json")"
    [[ -z "$public_exposure" ]] \
      && m1_check PASS "no-public-8080-3306" "no public API/DB NSG rule" \
      || fail_gate no-public-8080-3306 "PUBLIC EXPOSURE: $public_exposure"
  elif [[ "$rules_ok" -eq 0 ]]; then
    fail_gate nsg-rules "NSG rules listing failed — not treated as absence"
    fail_gate no-public-8080-3306 "NSG rules listing failed — exposure state unknown"
  fi

  # 3–4. Existing VMs and MySQL ------------------------------------------------
  vm_bad=""
  for display in rust-api-test rust-api-worker; do
    if read_oci_json vm_json compute instance list --compartment-id "$compartment" --display-name "$display"; then
      state="$(jq -r '.data[0]."lifecycle-state" // "ABSENT"' <<<"$vm_json")"
      [[ "$state" == "RUNNING" ]] || vm_bad+="$display=$state "
    else
      vm_bad+="$display=LISTING_FAILED "
    fi
  done
  [[ -z "$vm_bad" ]] \
    && m1_check PASS "vms-running" "rust-api-test + rust-api-worker RUNNING" \
    || fail_gate vms-running "VM health: $vm_bad"

  if read_oci_json mysql_json mysql db-system list --compartment-id "$compartment"; then
    mysql_state="$(jq -r '[.data[]? | select(."display-name" == "rust-api-heatwave")][0]."lifecycle-state" // "ABSENT"' <<<"$mysql_json")"
    [[ "$mysql_state" == "ACTIVE" ]] \
      && m1_check PASS "mysql-active" "rust-api-heatwave ACTIVE" \
      || fail_gate mysql-active "MySQL lifecycle-state: $mysql_state"
  else
    fail_gate mysql-active "MySQL listing failed — not treated as absence"
  fi

  # 6–7. LB present, no public API listener ------------------------------------
  # Listeners are read from the load-balancer GET (no dedicated list command).
  if read_oci_json lb_json lb load-balancer list --compartment-id "$compartment"; then
    lb_json_sel="$(jq -c '[.data[]? | select(."display-name" == "rust-api-public-lb")][0] // empty' <<<"$lb_json")"
    if [[ -n "$lb_json_sel" ]]; then
      lb_ocid="$(jq -r '.id' <<<"$lb_json_sel")"
      if read_oci_json lb_get_json lb load-balancer get --load-balancer-id "$lb_ocid"; then
        m1_check PASS "lb-present" "$(jq -r '.data."display-name" + " shape=" + .data."shape-name"' <<<"$lb_get_json")"
        listener_names="$(jq -r '[.data.listeners | keys[]?] | join(",")' <<<"$lb_get_json")"
        [[ -z "$listener_names" ]] \
          && m1_check PASS "no-public-listener" "no LB listeners (API ingress disabled)" \
          || fail_gate no-public-listener "unexpected LB listeners: $listener_names"
      else
        fail_gate lb-present "load-balancer GET failed — listener state unknown"
      fi
    else
      fail_gate lb-present "rust-api-public-lb not found"
      note "listener check skipped — LB absent"
    fi
  else
    fail_gate lb-present "load-balancer listing failed — not treated as absence"
  fi

  # 8. Monitoring alarms ---------------------------------------------------------
  # Zero alarms is a valid pre-apply state; disabled or missing-named alarms
  # post-apply are a gate failure.
  if read_oci_json alarms_json monitoring alarm list --compartment-id "$compartment"; then
    alarms="$(jq -r '[.data[]? | select(."display-name" | startswith("eventforge-")) | "\(.["display-name"])=\(.["is-enabled"])"] | join(",")' <<<"$alarms_json")"
    enabled_count="$(grep -o '=true' <<<"$alarms" | grep -c true || true)"
    disabled_count="$(grep -o '=false' <<<"$alarms" | grep -c false || true)"
    if [[ "$enabled_count" -ge 2 && "$disabled_count" -eq 0 ]]; then
      m1_check PASS "alarms-enabled" "$alarms"
    elif [[ -z "$alarms" ]]; then
      note "no eventforge alarms yet (expected pre-apply; PLATFORM-APPLY creates them)"
    else
      fail_gate alarms-enabled "expected 2+ enabled eventforge alarms, got: $alarms"
    fi
  else
    fail_gate alarms-enabled "alarm listing failed — not treated as absence"
  fi

  # 9. Budget and alert rules -------------------------------------------------------
  # OCI budgets are managed at the tenancy ROOT compartment (targets name the
  # tracked compartment), so the budget is looked up there.
  if read_oci_json budgets_json budgets budget budget list --compartment-id "$vcn_compartment_root"; then
    budget_id="$(jq -r '[.data[]? | select(."display-name" == "eventforge-monthly")][0].id // empty' <<<"$budgets_json")"
    if [[ -n "$budget_id" ]]; then
      if read_oci_json alerts_json budgets budget alert-rule list --budget-id "$budget_id"; then
        alerts="$(jq '[.data[]?] | length' <<<"$alerts_json")"
        [[ "${alerts:-0}" -ge 3 ]] \
          && m1_check PASS "budget" "eventforge-monthly (tenancy root) with $alerts alert rules" \
          || fail_gate budget "budget exists but alert rules: ${alerts:-0} (expected >=3)"
      else
        fail_gate budget "alert-rule listing failed — not treated as absence"
      fi
    else
      note "no eventforge-monthly budget yet (expected pre-apply; PLATFORM-APPLY creates it)"
    fi
  else
    fail_gate budget "budget listing failed — not treated as absence"
  fi
fi

# 10–11. Terraform state inventory ----------------------------------------------------
if m1_object_exists "$M1_PLATFORM_KEY"; then
  if "$M1_TERRAFORM_BIN" -chdir="$root" state pull > "$state_pull" 2>"$M1_EVIDENCE_DIR/logs/verify-pull.err" && [[ -s "$state_pull" ]]; then
    read -r lineage serial <<<"$(m1_state_meta "$state_pull")"
    m1_check PASS "state-readable" "lineage=$lineage serial=$serial"
    "$M1_TERRAFORM_BIN" -chdir="$root" state list > "$M1_EVIDENCE_DIR/state/platform-addresses.txt" 2>/dev/null
    addresses="$(grep -c . "$M1_EVIDENCE_DIR/state/platform-addresses.txt" || true)"
    m1_check PASS "state-inventory" "$addresses addresses recorded in evidence"
    if grep -q '^oci_core_vcn\.existing$' "$M1_EVIDENCE_DIR/state/platform-addresses.txt"; then
      m1_check PASS "imports-present" "imported VCN found in state"
    else
      note "imports not yet in state — import phases pending"
    fi
    if grep -Eq '^oci_load_balancer_(backend_set|listener|certificate)|^cloudflare_dns_record|^tls_private_key' "$M1_EVIDENCE_DIR/state/platform-addresses.txt"; then
      fail_gate ingress-resources "API-ingress resources found in state while enable_api_ingress must stay false"
    else
      m1_check PASS "ingress-disabled" "no API certificate/listener/backend/DNS resources in state"
    fi
  else
    fail_gate state-readable "could not pull platform state"
  fi
else
  note "platform state key absent — state checks pending imports"
fi

# Read-only drift assessment -----------------------------------------------------------
if [[ "$live_ready" -eq 1 && -d "$root/.terraform" ]] && m1_object_exists "$M1_PLATFORM_KEY"; then
  drift_plan="$M1_EVIDENCE_DIR/plans/verify-refresh-only.json"
  if "$M1_TERRAFORM_BIN" -chdir="$root" plan -refresh-only -input=false -lock=true -out="$M1_EVIDENCE_DIR/plans/verify-refresh-only.tfplan" \
       >"$M1_EVIDENCE_DIR/logs/verify-refresh.log" 2>&1 \
     && "$M1_TERRAFORM_BIN" -chdir="$root" show -json "$M1_EVIDENCE_DIR/plans/verify-refresh-only.tfplan" > "$drift_plan" 2>/dev/null; then
    drift="$(jq -r '(.resource_changes // [])[] | select(.change.actions != ["no-op"]) | "\(.address): \(.change.actions | join(","))"' "$drift_plan")"
    if [[ -z "$drift" ]]; then
      m1_check PASS "drift" "refresh-only reconciliation: clean"
    else
      fail_gate drift "drift reported (investigate line-by-line, never auto-correct):"$'\n'"$drift"
    fi
  else
    fail_gate drift "refresh-only plan could not be produced (see logs/verify-refresh.log)"
  fi
else
  note "drift assessment pending platform init/imports"
fi

m1_evidence_record "verify complete PASS=$m1_pass_count FAIL=$m1_fail_count"
printf '\nVerify result: %d PASS, %d FAIL — evidence in %s\n' "$m1_pass_count" "$m1_fail_count" "$M1_EVIDENCE_DIR"
[[ "$m1_fail_count" -eq 0 ]]
