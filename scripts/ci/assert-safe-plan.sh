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
# reveal public 8080/3306 ingress.
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
  def unknown_ingress:
    .change.after_unknown as $unknown |
    ($unknown.source? == true or $unknown.destination? == true or $unknown.tcp_options? == true or
      $unknown.tcp_options.destination_port_range? == true or $unknown.tcp_options.destination_port_range.min? == true or
      $unknown.tcp_options.destination_port_range.max? == true);
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

