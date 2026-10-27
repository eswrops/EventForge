#!/usr/bin/env bash
# M1-LOCAL Phase 2 — READ-ONLY OCI inventory and import reconciliation.
# Discovers the live eight-resource estate and reconciles it one-to-one
# against the reviewed OCIDs recorded in
# docs/acceptance/m1b-bootstrap/import-safety.md §1. Writes a discovery
# bundle to the protected evidence directory. Never mutates anything.
set -uo pipefail

# shellcheck source=scripts/local/lib-m1.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-m1.sh"

m1_init_evidence
m1_evidence_record "OCI inventory start (run $M1_RUN_TAG)"

fail_gate() { m1_check FAIL "$1" "${*:2}"; m1_evidence_record "GATE FAIL: $1"; exit 1; }
note() { printf 'NOTE  %s\n' "$*"; }

m1_verify_terraform_bin \
  && m1_check PASS "terraform-pinned" "v$M1_TERRAFORM_VERSION" \
  || fail_gate terraform-pinned "wrong binary"
m1_verify_auth_mode \
  && m1_check PASS "auth-apikey-profile" "profile $M1_OCI_PROFILE" \
  || fail_gate auth-apikey-profile "invalid authentication"

tenancy="$(awk -F= '/^tenancy=/{print $2; exit}' "$(m1_oci_config_file)")"

# Reviewed OCIDs (import-safety.md §1, M1B capture) -----------------------------
REVIEWED_VCN="ocid1.vcn.oc1.ap-hyderabad-1.amaaaaaatiosumiaz4zvhbqaopq7ljp4yq7gftrwdy2zmveizdmv62xvd6ca"
REVIEWED_SUBNET_APP="ocid1.subnet.oc1.ap-hyderabad-1.aaaaaaaawemcohc6vzzqwkv3hbq3mcpl3wf3bslzb5wmheixtitqcoqiddra"
REVIEWED_SUBNET_LB="ocid1.subnet.oc1.ap-hyderabad-1.aaaaaaaargdyoju3emyheunr6di75z2tl74khyf7tem6hwj5x5tmxt44q2bq"
REVIEWED_SUBNET_MYSQL="ocid1.subnet.oc1.ap-hyderabad-1.aaaaaaaaipwpkmvnxdzw2yduccugoq6pkojn7lpd3izpewyusyvi7ywp7ewa"
REVIEWED_VM1="ocid1.instance.oc1.ap-hyderabad-1.anuhsljrtiosumiceyilvbiclo7kynsdnzozmoeziwmsjdrhdwigvw5ibc4a"
REVIEWED_VM2="ocid1.instance.oc1.ap-hyderabad-1.anuhsljrtiosumicl5kpn6r7suoqgn4osm6pu3r7rrszwib3yuaeb65x7ooa"
REVIEWED_MYSQL="ocid1.mysqldbsystem.oc1.ap-hyderabad-1.aaaaaaaaes3clz2baohp34kuulobnhrp3cnz33bicso6r4syj7npztnvj2gq"
REVIEWED_LB="ocid1.loadbalancer.oc1.ap-hyderabad-1.aaaaaaaa4by2dj7zniovxz327ieyws33wcsxfu2rcu6dasnuk5f6yljmihvq"

read_oci_json() { # read_oci_json <varname> <oci args...>
  local __var="$1"; shift
  local out
  out="$(oci "$@" "${M1_OCI_REGION_ARGS[@]}" 2>"$M1_EVIDENCE_DIR/logs/last-oci-error.txt")" || { printf -v "$__var" ''; return 1; }
  if [[ -z "$out" ]] || ! jq -e . >/dev/null 2>&1 <<<"$out"; then
    printf -v "$__var" ''
    return 1
  fi
  printf -v "$__var" '%s' "$out"
}

# Pre-initialized so shellcheck sees the printf -v targets; read_oci_json
# always assigns (empty on failure).
comps_json="" vcn_json="" subnets_json="" insts_json="" vnics_json=""
mysql_json="" lb_json="" rt_json="" sl_json=""

bundle="$M1_EVIDENCE_DIR/oci-inventory.json"

# Compartments ------------------------------------------------------------------
read_oci_json comps_json iam compartment list --compartment-id "$tenancy" --all \
  || fail_gate compartments "cannot list compartments"
test_comp="$(jq -r '.data[] | select(.name == "Test") | .id' <<<"$comps_json")"
[[ -n "$test_comp" ]] || fail_gate compartments "Test compartment not found"
m1_check PASS "compartments" "tenancy root + Test compartment discovered"

# VCN -----------------------------------------------------------------------------
read_oci_json vcn_json network vcn get --vcn-id "$REVIEWED_VCN" \
  || fail_gate vcn "reviewed VCN not found live (drift!)"
vcn_cidrs="$(jq -c '.data."cidr-blocks"' <<<"$vcn_json")"
vcn_name="$(jq -r '.data."display-name"' <<<"$vcn_json")"
m1_check PASS "vcn-reconciled" "$vcn_name $vcn_cidrs"

# Subnets ----------------------------------------------------------------------------
read_oci_json subnets_json network subnet list --compartment-id "$tenancy" --vcn-id "$REVIEWED_VCN" --all \
  || fail_gate subnets "cannot list VCN subnets"
declare -A SUBNET_EXPECT=(
  [app]="$REVIEWED_SUBNET_APP"
  [lb]="$REVIEWED_SUBNET_LB"
  [mysql]="$REVIEWED_SUBNET_MYSQL"
)
subnet_report=""
for role in app lb mysql; do
  ocid="${SUBNET_EXPECT[$role]}"
  row="$(jq -r --arg ocid "$ocid" '.data[] | select(.id == $ocid)
    | [.id, ."display-name", ."cidr-block", ."route-table-id", (."security-list-ids" | join(","))] | @tsv' <<<"$subnets_json")"
  [[ -n "$row" ]] || fail_gate "subnet-$role" "reviewed $role subnet OCID not found under the reviewed VCN"
  subnet_report+="$role	$row"$'\n'
  m1_check PASS "subnet-$role" "$(awk -F'\t' '{print $2 " " $3}' <<<"$row")"
done

# Instances ------------------------------------------------------------------------------
read_oci_json insts_json compute instance list --compartment-id "$test_comp" --all \
  || fail_gate instances "cannot list Test-compartment instances"
declare -A VM_EXPECT=([vm1]="$REVIEWED_VM1" [vm2]="$REVIEWED_VM2")
vm_report=""
for vm in vm1 vm2; do
  ocid="${VM_EXPECT[$vm]}"
  row="$(jq -r --arg ocid "$ocid" '.data[] | select(.id == $ocid)
    | [.id, ."display-name", ."lifecycle-state", ."availability-domain", ."shape", (."shape-config"."ocpus"|tostring), (."shape-config"."memory-in-gbs"|tostring)] | @tsv' <<<"$insts_json")"
  [[ -n "$row" ]] || fail_gate "instance-$vm" "reviewed $vm OCID not found live"
  inst_id="$(awk -F'\t' '{print $1}' <<<"$row")"
  read_oci_json vnics_json compute instance list-vnics --instance-id "$inst_id" \
    || fail_gate "instance-$vm" "cannot read VNICs"
  vnic="$(jq -c '.data[0]' <<<"$vnics_json")"
  vnic_nsgs="$(jq -r '."nsg-ids" | join(",")' <<<"$vnic")"
  vnic_subnet="$(jq -r '."subnet-id"' <<<"$vnic")"
  vnic_ip="$(jq -r '."private-ip"' <<<"$vnic")"
  [[ "$vnic_subnet" == "$REVIEWED_SUBNET_APP" ]] \
    || m1_check FAIL "instance-$vm-vnic" "primary VNIC subnet is not the reviewed app subnet: $vnic_subnet"
  vm_report+="$vm	$row	$vnic_ip	$vnic_nsgs"$'\n'
  m1_check PASS "instance-$vm" "$(awk -F'\t' '{print $2 " " $3 " " $5}' <<<"$row") primary=$vnic_ip nsgs=${vnic_nsgs:-none}"
done

# MySQL ------------------------------------------------------------------------------------
read_oci_json mysql_json mysql db-system get --db-system-id "$REVIEWED_MYSQL" \
  || fail_gate mysql "reviewed MySQL DB system not found live"
m1_check PASS "mysql-reconciled" \
  "$(jq -r '.data."display-name" + " " + .data."lifecycle-state" + " shape=" + .data."shape-name" + " subnet=" + .data."subnet-id"' <<<"$mysql_json")"
jq '{display_name:.data."display-name", lifecycle_state:.data."lifecycle-state", shape:.data."shape-name",
     subnet_id:.data."subnet-id", mysql_version:.data."mysql-version", port:.data.port,
     ip_address:.data."ip-address", backup_policy:.data."backup-policy"}' <<<"$mysql_json" \
  > "$M1_EVIDENCE_DIR/mysql-inspect.json"

# Load balancer --------------------------------------------------------------------------------
read_oci_json lb_json lb load-balancer get --load-balancer-id "$REVIEWED_LB" \
  || fail_gate lb "reviewed load balancer not found live"
lb_shape="$(jq -r '.data."shape-name"' <<<"$lb_json")"
lb_subnets="$(jq -c '.data."subnet-ids"' <<<"$lb_json")"
m1_check PASS "lb-reconciled" "shape=$lb_shape subnets=$lb_subnets"
read_oci_json lb_listeners_json lb listener list --load-balancer-id "$REVIEWED_LB" \
  || lb_listeners_json='{"data":[]}'
jq -c '.data // []' <<<"$lb_listeners_json" > "$M1_EVIDENCE_DIR/lb-listeners.json"

# Shared network references (read-only inputs; never declared by platform) ----------------------
rt_ids="$(jq -r '.data[] | ."route-table-id"' <<<"$subnets_json" | sort -u)"
sl_ids="$(jq -r '.data[] | ."security-list-ids"[]' <<<"$subnets_json" | sort -u)"
for rt in $rt_ids; do
  if read_oci_json rt_json network route-table get --rt-id "$rt"; then
    m1_check PASS "shared-route-table" "$(jq -r '.data."display-name"' <<<"$rt_json") $rt"
  else
    fail_gate shared-route-table "cannot read shared route table $rt — not treated as absence"
  fi
done
for sl in $sl_ids; do
  if read_oci_json sl_json network security-list get --security-list-id "$sl"; then
    m1_check PASS "shared-security-list" "$(jq -r '.data."display-name"' <<<"$sl_json") $sl"
  else
    fail_gate shared-security-list "cannot read shared security list $sl — not treated as absence"
  fi
done

# Discovery bundle (protected evidence) -----------------------------------------------------------
jq -n \
  --arg tenancy "$tenancy" --arg test_compartment "$test_comp" \
  --argjson vcn "$vcn_json" \
  --argjson subnets "$subnets_json" \
  --argjson instances "$insts_json" \
  --argjson mysql "$mysql_json" \
  --argjson lb "$lb_json" \
  --argjson lb_listeners "$(jq -c '.data // []' <<<"$lb_listeners_json")" \
  --arg vm_report "${vm_report%$'\n'}" \
  --arg subnet_report "${subnet_report%$'\n'}" \
  --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{timestamp:$timestamp, tenancy:$tenancy, test_compartment:$test_compartment,
    vcn:$vcn, subnets:$subnets, instances:$instances,
    mysql:$mysql, load_balancer:$lb, lb_listeners:$lb_listeners,
    vm_report:$vm_report, subnet_report:$subnet_report}' > "$bundle"
chmod 600 "$bundle"

m1_evidence_record "OCI inventory complete PASS=$m1_pass_count FAIL=$m1_fail_count"
printf '\nInventory reconciled: %d PASS, %d FAIL — bundle in %s\n' "$m1_pass_count" "$m1_fail_count" "$bundle"
[[ "$m1_fail_count" -eq 0 ]]
