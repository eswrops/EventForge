GATE: PLATFORM-APPLY
APPROVER: Koka Easwarendra <easwarendra.ece@gmail.com>
DATE: 2026-10-28
COMMIT: a338ab0f657fa0139f511f3f6d6b571165c26ecc
PLAN_SHA256: 8cce2da3dc56e420070ebf6016c14f5eca4b5fe0b1f528ecdb58c796e949cfa6

Reviewed artifacts:
- docs/acceptance/m1-local/scope-a-network-execution-approval.md (Scope-A execution package)
- Saved plan + JSON + action summary: /Users/eswr/secure/evidence/m1local-20261027T194619Z/plans/
  (platform-20261027T194622Z.tfplan, mode 0600)
- Safe-plan results: PASS with scripts/ci/platform-safe-plan-scope-a-policy.json via
  scripts/ci/assert-safe-plan.sh AND attribute-level PASS via
  scripts/ci/assert-safe-plan-scope-a.sh (policy scripts/ci/platform-safe-plan-scope-a-policy.json)
- Action summary: exactly 4 updates, 0 creates, 0 deletes, 0 replacements, 0 ingress resources —
  oci_core_instance.api["vm1"], oci_core_instance.api["vm2"],
  oci_load_balancer_load_balancer.existing, oci_mysql_mysql_db_system.existing;
  only create_vnic_details.nsg_ids (both VMs), network_security_group_ids (LB),
  nsg_ids (MySQL) change; after_unknown empty (state lineage
  cdda242b-92c1-4371-5b43-495f3849fc4d, serial 10).
- Scope-A sequence state at approval: A0 serial-console recovery path proven for both VMs;
  A1 live operator source IP verified 49.207.214.221 = approved /32.
- Operator grant: "approved" (2026-10-28, in the Scope-A execution session, authorizing the
  documented A0→A6 procedure: plan regeneration, this record naming the plan SHA-256,
  a single apply, live verification, then the separately recorded SL-CORRECTION updates).

Statement: I have reviewed the saved plan (four in-place NSG-association updates only; no
creates, deletes, replacements, or ingress resources) and authorize this exact plan to be
applied once with remote locking. A failed apply stops without retry or rollback.
