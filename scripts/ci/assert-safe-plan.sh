#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 || "$1" != "--policy" ]]; then
  echo "usage: assert-safe-plan.sh --policy <safe-plan-policy.json> <terraform-plan-json>" >&2
  exit 64
fi

policy="$2"
plan="$3"

# Optional jq iterators turn a truncated plan into an empty, apparently-safe
# plan. Validate the entire document before evaluating any policy rules.
if ! jq -e '
  def valid_actions:
    type == "array" and length > 0 and
    all(.[]; type == "string" and (. as $action | ["no-op", "create", "update", "delete", "read"] | index($action) != null)) and
    ((index("no-op") == null) or . == ["no-op"]);
  type == "object" and (.resource_changes | type == "array") and
  all(.resource_changes[];
    type == "object" and (.address | type == "string" and length > 0) and
    (.type | type == "string" and length > 0) and (.change | type == "object") and
    (.change.actions | valid_actions) and
    (.change | has("after")) and (.change.after == null or (.change.after | type == "object")) and
    ((.change.after_unknown? // {}) | type == "object")
  )
' "$plan" >/dev/null; then
  echo "Terraform plan JSON is invalid or incomplete." >&2
  exit 64
fi

if ! jq -e '
  def valid_actions:
    type == "array" and length > 0 and all(.[]; type == "string" and (. as $action | ["create", "update", "delete", "read"] | index($action) != null));
  def valid_regex: type == "string" and length > 0 and (try test("") catch false);
  type == "object" and (.allow | type == "array") and (.protected_imports | type == "array") and
  all(.protected_imports[]; valid_regex) and
  all(.allow[];
    type == "object" and (.address_regex | valid_regex) and (.actions | valid_actions) and
    ((.allow_delete? // false) | type == "boolean") and ((.allow_import_update? // false) | type == "boolean")
  )
' "$policy" >/dev/null; then
  echo "Safe-plan policy is invalid." >&2
  exit 64
fi

# Default deny: every non-no-op must match a reviewed address/action pair.
# Unknown security-rule attributes are unsafe because a later apply could
# reveal public 8080/3306 ingress. Exception: on a CREATE, an unknown
# source/destination that the pinned source_type/destination_type proves to be
# a NETWORK_SECURITY_GROUP reference (an id created in the same apply) is
# deterministic from the reviewed configuration. An unknown CIDR source, any
# unknown port range, and any unknown on updates remain fatal.
violations="$(jq -r --slurpfile policy "$policy" '
  def action_key: .change.actions | join(",");
  def matching_rules($address): [$policy[0].allow[] | select(.address_regex as $pattern | ($address | test($pattern)))];
  def is_protected($address): $policy[0].protected_imports | any(. as $pattern | ($address | test($pattern)));
  def is_security_rule: .type == "oci_core_network_security_group_security_rule";
  def public_protected_port:
    .change.after as $after |
    (($after.source? == "0.0.0.0/0" or $after.destination? == "0.0.0.0/0") and
      (($after.tcp_options.destination_port_range.min? == 8080) or ($after.tcp_options.destination_port_range.max? == 8080) or
       ($after.tcp_options.destination_port_range.min? == 3306) or ($after.tcp_options.destination_port_range.max? == 3306)));
  def nsg_ref_unknown:
    # Direction-aware: on INGRESS rules only SOURCE (and ports) can expose the
    # resource; destination is an egress-only field the provider nulls at
    # apply, so its unknown is inert (and vice versa for EGRESS). An unknown
    # exposure-relevant endpoint is acceptable ONLY on a CREATE whose pinned
    # *_type proves a NETWORK_SECURITY_GROUP reference created in the same
    # apply. Unknown CIDR endpoints and any unknown on updates stay fatal.
    (.change.actions == ["create"]) and
    (
      (.change.after.direction == "INGRESS" and
         .change.after_unknown.source? == true and .change.after.source_type == "NETWORK_SECURITY_GROUP") or
      (.change.after.direction == "EGRESS" and
         .change.after_unknown.destination? == true and .change.after.destination_type == "NETWORK_SECURITY_GROUP") or
      (.change.after.direction == "INGRESS" and .change.after_unknown.destination? == true) or
      (.change.after.direction == "EGRESS" and .change.after_unknown.source? == true)
    );
  def port_range_unknown($dpr):
    ($dpr | type) == "boolean" and $dpr == true or
    ((($dpr | type) == "object") and ($dpr.min? == true or $dpr.max? == true));
  def unknown_ingress:
    .change.after_unknown as $unknown |
    (nsg_ref_unknown | not) and
    (($unknown.source? == true) or ($unknown.destination? == true) or ($unknown.tcp_options? == true) or
     (($unknown.tcp_options | type) == "object" and
       (port_range_unknown($unknown.tcp_options.destination_port_range?))) or
     (($unknown.tcp_options | type) == "array" and
       any(.[];
            ((if type == "object" then . else {} end) as $to |
             (($to.destination_port_range? // []) | any(.; port_range_unknown(.)))))));
  .resource_changes[] | select(.change.actions != ["no-op"]) | . as $change |
  (matching_rules(.address) | map(select((.actions | join(",")) == ($change | action_key)))) as $matches |
  if (is_security_rule and unknown_ingress) then "unknown-ingress-attributes\t\(.address)\t\(action_key)"
  elif (is_security_rule and public_protected_port) then "public-api-or-db-port\t\(.address)\t\(action_key)"
  elif ($matches | length) == 0 then "unapproved-change\t\(.address)\t\(action_key)"
  elif ((.change.actions | index("delete")) != null and ($matches | any(.allow_delete == true) | not)) then "delete-or-replacement\t\(.address)\t\(action_key)"
  elif (is_protected($change.address) and (.change.actions != ["update"] or ($matches | any(.allow_import_update == true) | not))) then "protected-import-change\t\(.address)\t\(action_key)"
  else empty end
' "$plan")"

if [[ -n "$violations" ]]; then
  echo "Refusing unsafe Terraform plan:" >&2
  while IFS=$'\t' read -r reason address actions; do
    printf '%s: %s (%s)\n' "$reason" "$address" "$actions" >&2
  done <<<"$violations"
  exit 1
fi

echo "Terraform plan matches the reviewed safe-plan policy."

