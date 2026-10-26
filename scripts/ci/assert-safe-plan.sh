#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: assert-safe-plan.sh <terraform-plan-json>" >&2
  exit 64
fi

plan="$1"

# Imported resources are protected outside this check, but block every delete
# and replacement at CI level as a second independent guardrail.
if jq -e '
  .resource_changes[]?
  | select((.change.actions | index("delete")) != null)
' "$plan" >/dev/null; then
  echo "Refusing plan containing delete or replacement actions:" >&2
  jq -r '.resource_changes[]? | select((.change.actions | index("delete")) != null) | "- \(.address): \(.change.actions | join(","))"' "$plan" >&2
  exit 1
fi

# Reject a newly planned 8080 or 3306 TCP rule open to the entire Internet.
if jq -e '
  .resource_changes[]?
  | select(.type == "oci_core_network_security_group_security_rule")
  | .change.after
  | select((.source? == "0.0.0.0/0" or .destination? == "0.0.0.0/0"))
  | .tcp_options? | .destination_port_range? | select(.min == 8080 or .min == 3306 or .max == 8080 or .max == 3306)
' "$plan" >/dev/null; then
  echo "Refusing public 8080/3306 NSG rule." >&2
  exit 1
fi

