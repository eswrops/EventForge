#!/usr/bin/env bash
# M1-LOCAL — verify the tracked import configuration against a live OCI
# discovery bundle (read-only, offline). The eight imported-resource
# declarations are TRACKED in infra/platform/imported_resources.tf; the
# account-specific discovery values (OCIDs, private addresses, ADs, images)
# live in the git-ignored infra/platform/imported.auto.tfvars. This script
# compares every pinned OCID and attribute against the evidence bundle
# produced by m1-oci-inventory.sh, verifies the tracked/ignored split, and
# enforces the import-safety structure (prevent_destroy, no NSG attachments,
# no broad ignores, scope).
#
#   m1-verify-import-config.sh <oci-inventory.json>
set -uo pipefail

# shellcheck source=scripts/local/lib-m1.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-m1.sh"

# Counters live in the sourced library; re-declared here for shellcheck.
m1_pass_count="${m1_pass_count:-0}"
m1_fail_count="${m1_fail_count:-0}"

if [[ $# -ne 1 || ! -f "$1" ]]; then
  echo "usage: m1-verify-import-config.sh <oci-inventory.json>" >&2
  exit 64
fi

bundle="$1"
cfg="$M1_REPO_ROOT/infra/platform/imported_resources.tf"
imported_tfvars="$M1_REPO_ROOT/infra/platform/imported.auto.tfvars"
tfvars="$M1_REPO_ROOT/infra/platform/terraform.auto.tfvars"

fail_gate() { m1_check FAIL "$1" "${*:2}"; }
tf() { "$M1_TERRAFORM_BIN" "$@"; }

# ------------------------------------------------------------- tracked/ignored split
[[ -f "$cfg" ]] || { fail_gate config "imported_resources.tf missing"; printf 'FATAL\n'; exit 1; }
[[ -f "$imported_tfvars" ]] || { fail_gate imported-tfvars "imported.auto.tfvars missing (discovery values)"; printf 'FATAL\n'; exit 1; }
git -C "$M1_REPO_ROOT" ls-files --error-unmatch "infra/platform/imported_resources.tf" >/dev/null 2>&1 \
  && m1_check PASS "declarations-tracked" "imported_resources.tf is tracked (clean-checkout reproducibility)" \
  || fail_gate declarations-tracked "imported_resources.tf must be tracked by Git"
if git -C "$M1_REPO_ROOT" ls-files --error-unmatch "infra/platform/imported.auto.tfvars" >/dev/null 2>&1; then
  fail_gate values-ignored "imported.auto.tfvars must never be tracked (live OCIDs/addresses)"
else
  m1_check PASS "values-ignored" "discovery values stay in the git-ignored imported.auto.tfvars"
fi

# ---------------------------------------------------------------- structure
block_count="$(grep -cE '^resource ' "$cfg")"
pd_count="$(grep -cE 'prevent_destroy = true' "$cfg")"
[[ "$block_count" -eq 7 && "$pd_count" -eq "$block_count" ]] \
  && m1_check PASS "prevent_destroy" "present in all $block_count resource blocks (8 addresses via for_each)" \
  || fail_gate prevent_destroy "blocks=$block_count prevent_destroy=$pd_count (must be equal and nonzero)"

if grep -nE 'nsg_ids' "$cfg" | grep -qv '#'; then
  fail_gate no-nsg-attachment "nsg_ids present in the import configuration"
else
  m1_check PASS "no-nsg-attachment" "no NSG attached during initial import"
fi

# Exactly the eight addresses — nothing else declared, no out-of-scope subnets.
declared="$(grep -oE '^resource "[^"]+" "[^"]+"' "$cfg" | sed 's/resource //; s/"//g')"
expected_declared="$(printf '%s\n' \
  'oci_core_vcn existing' 'oci_core_subnet app' 'oci_core_subnet lb' 'oci_core_subnet mysql' \
  'oci_core_instance api' 'oci_mysql_mysql_db_system existing' 'oci_load_balancer_load_balancer existing')"
[[ "$declared" == "$expected_declared" ]] \
  && m1_check PASS "resource-scope" "exactly the 7 resource blocks (8 addresses via for_each)" \
  || fail_gate resource-scope "unexpected declarations:"$'\n'"$declared"

if grep -q 'postgresmax-public-subnet' "$cfg"; then
  fail_gate scope-leak "out-of-scope postgresmax-public-subnet referenced"
else
  m1_check PASS "scope-leak" "out-of-scope subnet not referenced"
fi

# Narrow ignores only.
ic="$(grep -oE 'ignore_changes[[:space:]]*=[[:space:]]*\[[^]]*\]' "$cfg")"
expected_ic_count=2
[[ "$(grep -cE '^[[:space:]]*ignore_changes[[:space:]]*=' "$cfg")" -eq "$expected_ic_count" ]] \
  && m1_check PASS "ignore-changes-scope" "$expected_ic_count narrowly scoped ignores" \
  || fail_gate ignore-changes-scope "expected exactly $expected_ic_count ignore_changes assignments"
grep -q '\[metadata, agent_config, availability_config\]' <<<"$ic" \
  && m1_check PASS "instance-ignore-changes" "template scope preserved" \
  || fail_gate instance-ignore-changes "instance ignore_changes drifted"
grep -q '\[admin_username, admin_password\]' <<<"$ic" \
  && m1_check PASS "mysql-ignore-changes" "write-only credential pair only (no broad ignore)" \
  || fail_gate mysql-ignore-changes "MySQL ignore_changes drifted"

# ---------------------------------------------------------------- identity cross-check
vcn_id="$(jq -r '.vcn.data.id' "$bundle")"
sub_app="$(jq -r '.subnets.data[] | select(."display-name"=="rust-api-test-public-subnet") | .id' "$bundle")"
sub_lb="$(jq -r '.subnets.data[] | select(."display-name"=="rust-api-lb-public-subnet") | .id' "$bundle")"
sub_db="$(jq -r '.subnets.data[] | select(."display-name"=="rust-api-db-private-subnet") | .id' "$bundle")"
rt_live="$(jq -r '[.subnets.data[] | ."route-table-id"] | unique | .[0]' "$bundle")"
rt_count="$(jq -r '[.subnets.data[] | ."route-table-id"] | unique | length' "$bundle")"
vm1_img="$(jq -r '.instances.data[] | select(."display-name"=="rust-api-test") | .["source-details"]["image-id"]' "$bundle")"
vm2_img="$(jq -r '.instances.data[] | select(."display-name"=="rust-api-worker") | .["source-details"]["image-id"]' "$bundle")"
vm_shape="$(jq -r '.instances.data[0].shape' "$bundle")"
vm1_ad="$(jq -r '.instances.data[] | select(."display-name"=="rust-api-test") | ."availability-domain"' "$bundle")"
vm1_fd="$(jq -r '.instances.data[] | select(."display-name"=="rust-api-test") | ."fault-domain"' "$bundle")"
vm2_fd="$(jq -r '.instances.data[] | select(."display-name"=="rust-api-worker") | ."fault-domain"' "$bundle")"
vm1_ip="$(jq -r '.vm_report | split("\n")[] | select(startswith("vm1\t")) | split("\t")[8]' "$bundle")"
mysql_shape="$(jq -r '.mysql.data."shape-name"' "$bundle")"
mysql_ad="$(jq -r '.mysql.data."availability-domain"' "$bundle")"
mysql_subnet="$(jq -r '.mysql.data."subnet-id"' "$bundle")"
mysql_backup_enabled="$(jq -r '.mysql.data."backup-policy"."is-enabled"' "$bundle")"
mysql_backup_days="$(jq -r '.mysql.data."backup-policy"."retention-in-days"' "$bundle")"
mysql_backup_window="$(jq -r '.mysql.data."backup-policy"."window-start-time"' "$bundle")"
mysql_pitr="$(jq -r '.mysql.data."backup-policy"."pitr-policy"."is-enabled"' "$bundle")"
lb_shape="$(jq -r '.load_balancer.data."shape-name"' "$bundle")"
lb_min="$(jq -r '.load_balancer.data."shape-details"."minimum-bandwidth-in-mbps"' "$bundle")"
lb_max="$(jq -r '.load_balancer.data."shape-details"."maximum-bandwidth-in-mbps"' "$bundle")"
lb_listeners="$(jq -r '[.load_balancer_listeners[]?] | length' "$bundle")"
compartment="$(jq -r '.test_compartment' "$bundle")"
vcn_compartment="$(jq -r '.vcn.data."compartment-id"' "$bundle")"

check_ocid() { # check_ocid <name> <file> <expected>
  local name="$1" file="$2" expected="$3" found=""
  [[ -n "$expected" ]] || { fail_gate "$name" "empty expectation — bundle field missing; refusing to pass"; return; }
  found="$(grep -oF "$expected" "$file" | head -1)"
  [[ "$found" == "$expected" ]] \
    && m1_check PASS "$name" "matches discovery bundle" \
    || fail_gate "$name" "expected $expected not pinned in $(basename "$file")"
}

# VCN/subnet OCIDs are carried by tfvars variables (checked below); the import
# executor binds the exact reviewed OCIDs at import time and verifies state IDs.
check_ocid vm1-image "$imported_tfvars" "$vm1_img"
check_ocid vm2-image "$imported_tfvars" "$vm2_img"
check_ocid route-table-pinned "$imported_tfvars" "$rt_live"
sl_in_scope="$(grep -oE 'ocid1\.securitylist\.oc1\.[a-z0-9.-]+' "$imported_tfvars" | sort -u | wc -l | tr -d ' ')"
if [[ "$sl_in_scope" -eq 3 ]]; then
  while IFS= read -r sl; do
    if grep -qF "$sl" "$imported_tfvars"; then
      m1_check PASS "security-list-pinned" "${sl##*.}"
    else
      fail_gate security-list-pinned "in-scope SL not pinned: $sl"
    fi
  done < <(jq -r '.subnets.data[]
             | select(."display-name" != "postgresmax-public-subnet")
             | ."security-list-ids"[]' "$bundle" | sort -u)
else
  fail_gate security-list-scope "expected 3 pinned SLs, found $sl_in_scope"
fi
[[ "$rt_count" -eq 1 ]] \
  && m1_check PASS "route-table-unique" "all subnets share one route table" \
  || fail_gate route-table-unique "$rt_count distinct route tables — configuration must be re-derived"

# VCN/subnet/compartment OCIDs are deliberately carried by tfvars variables
# (the configuration references var.*), never duplicated in imported_resources.tf.
grep -q 'var.compartment_ocid' "$cfg" && grep -q 'var.vcn_compartment_ocid' "$cfg" \
  && m1_check PASS "config-var-refs" "compute + VCN compartment references via variables" \
  || fail_gate config-var-refs "expected var.compartment_ocid / var.vcn_compartment_ocid references"
check_ocid compartment-compute "$tfvars" "$compartment"
check_ocid vcn-compartment "$tfvars" "$vcn_compartment"

# tfvars coordinates must match the bundle too.
check_ocid tfvars-vcn "$tfvars" "$vcn_id"
check_ocid tfvars-subnet-app "$tfvars" "$sub_app"
check_ocid tfvars-subnet-lb "$tfvars" "$sub_lb"
check_ocid tfvars-subnet-mysql "$tfvars" "$sub_db"
check_ocid tfvars-compartment "$tfvars" "$compartment"
check_ocid tfvars-vcn-compartment "$tfvars" "$vcn_compartment"

# Attribute-level checks.
grep -qE "shape_name[[:space:]]*= \"$mysql_shape\"" "$cfg" \
  && m1_check PASS "mysql-shape" "$mysql_shape" || fail_gate mysql-shape "not pinned as $mysql_shape"
grep -qF '"'"$vm_shape"'"' "$imported_tfvars" \
  && m1_check PASS "vm-shape" "$vm_shape" || fail_gate vm-shape "not pinned"
grep -qF "\"$vm1_ad\"" "$imported_tfvars" && grep -qF "\"$vm1_fd\"" "$imported_tfvars" \
  && grep -qF "\"$vm2_fd\"" "$imported_tfvars" \
  && m1_check PASS "vm-placement" "AD/FD match discovery" || fail_gate vm-placement "AD/FD drift"
grep -qF "$vm1_ip" "$imported_tfvars" \
  && m1_check PASS "vm1-private-ip" "$vm1_ip" || fail_gate vm1-private-ip "not pinned"
grep -qF "\"$mysql_ad\"" "$imported_tfvars" && [[ "$mysql_ad" == "wFMs:AP-HYDERABAD-1-AD-1" ]] \
  && m1_check PASS "mysql-placement" "$mysql_ad" || fail_gate mysql-placement "AD drift"
check_ocid mysql-subnet "$tfvars" "$mysql_subnet"
grep -qE 'subnet_id[[:space:]]*= var.mysql_subnet_ocid' "$cfg" \
  && m1_check PASS "mysql-subnet-ref" "var.mysql_subnet_ocid" \
  || fail_gate mysql-subnet-ref "expected var.mysql_subnet_ocid reference"

[[ "$mysql_backup_enabled" == "true" && "$mysql_backup_days" == "1" \
   && "$mysql_backup_window" == "09:27" && "$mysql_pitr" == "false" ]] \
  && grep -qE 'is_enabled[[:space:]]*= true' "$cfg" \
  && grep -qE 'retention_in_days[[:space:]]*= 1([[:space:]]|$)' "$cfg" \
  && grep -qE 'window_start_time[[:space:]]*= "09:27"' "$cfg" \
  && grep -qE 'pitr_policy[[:space:]]*\{[[:space:]]*is_enabled = false[[:space:]]*\}' "$cfg" \
  && m1_check PASS "mysql-backup-policy" "enabled/1-day/09:27/no-PITR pinned as live" \
  || fail_gate mysql-backup-policy "backup policy does not match live configuration"

[[ "$lb_shape" == "flexible" && "$lb_min" == "10" && "$lb_max" == "10" ]] \
  && grep -q 'minimum_bandwidth_in_mbps = 10' "$cfg" && grep -q 'maximum_bandwidth_in_mbps = 10' "$cfg" \
  && m1_check PASS "lb-shape" "flexible 10–10 Mbps as live" \
  || fail_gate lb-shape "does not match live configuration"
[[ "$lb_listeners" -eq 0 ]] \
  && m1_check PASS "lb-no-listeners" "live LB has no listeners; config declares none" \
  || fail_gate lb-no-listeners "live LB has listeners — re-derive configuration before import"

# Offline validation of the composed configuration.
if tf -chdir="$M1_REPO_ROOT/infra/platform" validate >/dev/null 2>&1; then
  m1_check PASS "terraform-validate" "configuration valid"
else
  fail_gate terraform-validate "configuration invalid"
fi

printf '\nImport-config verification: %d PASS, %d FAIL (bundle: %s)\n' \
  "$m1_pass_count" "$m1_fail_count" "$bundle"
[[ "$m1_fail_count" -eq 0 ]]
