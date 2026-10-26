#!/usr/bin/env bash
set -euo pipefail

: "${OCI_COMPARTMENT_OCID:?Set OCI_COMPARTMENT_OCID to the EventForge compartment OCID.}"
: "${MYSQL_PRIVATE_IP:=10.0.3.18}"

command -v oci >/dev/null || { echo "OCI CLI is required." >&2; exit 127; }
command -v jq >/dev/null || { echo "jq is required." >&2; exit 127; }

failures=0
check() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    printf 'PASS  %s: %s\n' "$label" "$actual"
  else
    printf 'FAIL  %s: expected %s, found %s\n' "$label" "$expected" "$actual" >&2
    failures=$((failures + 1))
  fi
}

instances="$(oci compute instance list --compartment-id "$OCI_COMPARTMENT_OCID" --lifecycle-state RUNNING --all)"
e2_count="$(jq '[.data[] | select(.shape | test("E2\\.1\\.Micro$"))] | length' <<<"$instances")"
check "running E2.1.Micro instances" 2 "$e2_count"

# Boot volumes can be ATTACHED/IN_USE; count allocated volume size rather than
# only AVAILABLE volumes. Do not consume more than the reported 100 GB of the
# 200 GB Always Free allocation before this foundation is applied.
boot_volumes="$(oci bv boot-volume list --compartment-id "$OCI_COMPARTMENT_OCID" --all)"
allocated_boot_gb="$(jq '[.data[] | select(."lifecycle-state" != "TERMINATED") | ."size-in-gbs"] | add // 0' <<<"$boot_volumes")"
if (( allocated_boot_gb <= 100 )); then
  printf 'PASS  boot volume allocation: %s GB (within 100 GB used / 200 GB cap baseline)\n' "$allocated_boot_gb"
else
  printf 'FAIL  boot volume allocation: %s GB (exceeds 100 GB used baseline)\n' "$allocated_boot_gb" >&2
  failures=$((failures + 1))
fi

load_balancers="$(oci lb load-balancer list --compartment-id "$OCI_COMPARTMENT_OCID" --all)"
flex_10_count="$(jq '[.data[] | select(."lifecycle-state" == "ACTIVE") | select(."shape-name" == "flexible") | select(."shape-details"."minimum-bandwidth-in-mbps" == 10 and ."shape-details"."maximum-bandwidth-in-mbps" == 10)] | length' <<<"$load_balancers")"
check "active 10 Mbps flexible load balancers" 1 "$flex_10_count"

mysql="$(oci mysql db-system list --compartment-id "$OCI_COMPARTMENT_OCID" --all)"
mysql_matches="$(jq --arg ip "$MYSQL_PRIVATE_IP" '[.data[] | select(."lifecycle-state" == "ACTIVE") | select(."ip-address" == $ip) | select(."shape-name" | startswith("MySQL.Free"))] | length' <<<"$mysql")"
check "active MySQL.Free at ${MYSQL_PRIVATE_IP}" 1 "$mysql_matches"

heatwave_state="$(jq --arg ip "$MYSQL_PRIVATE_IP" -r '[.data[] | select(."ip-address" == $ip) | ."heat-wave-cluster"."lifecycle-state"] | first // "not-reported"' <<<"$mysql")"
printf 'INFO  HeatWave.Free cluster state: %s (not required for initial provisioning)\n' "$heatwave_state"

if (( failures > 0 )); then
  echo "OCI preflight failed; do not apply Terraform until the inventory discrepancy is resolved." >&2
  exit 1
fi

echo "OCI free-tier preflight passed. Existing resources are eligible for import; no compute or DB provisioning is required."

