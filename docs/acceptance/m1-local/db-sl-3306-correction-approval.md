# DB-SL-3306-CORRECTION — prepared, NOT executed (Phase 9 package)

GATE: SL-CORRECTION
APPROVER: <operator name>

> Prepared 2026-10-28 after the MYSQL-NSG-IAM execution as the Phase 9
> handoff. This record authorizes ONE guarded security-list correction —
> removing the transitional application-subnet-wide TCP 3306 ingress rule —
> executed only via `scripts/ops/eventforge-sl-update` (which re-verifies
> every recorded hash against the live object before any write and refuses
> any concurrent change). It is deliberately NOT authorized by
> MYSQL-NSG-IAM or MYSQL-NSG-RETEST, and MUST NOT be executed until all of
> the execution preconditions below are real.

## What is authorized

- Security list: `rust-api-database-private`
  (`ocid1.securitylist.oc1.ap-hyderabad-1.aaaaaaaarwcfapns7orc6hvovfrt2md3xhko443sp5vz324b5c7pwiu7apoa`,
  db subnet, tenancy-root compartment).
- Change: **remove the ingress rule** `TCP 3306 from 10.0.2.0/24`
  (the application-subnet-wide transitional permission).
- Everything else on the list stays: the existing egress rule is untouched;
  no other security list, NSG, or route construct is modified; no ingress is
  added anywhere.
- After this correction the ONLY path to MySQL 3306 is the reviewed
  app-NSG ↔ db-NSG pairing (TCP 3306 restricted to the app NSG source),
  which must be live-verified immediately before and after the correction.

## Execution preconditions (all mandatory at execution time)

1. MYSQL-NSG-RETEST **SUCCEEDED**: the UPDATE_DBSYSTEM work request reached
   SUCCEEDED, live MySQL `nsg_ids` contains `eventforge-db-nsg`
   (`ocid1.networksecuritygroup.oc1.ap-hyderabad-1.aaaaaaaay3iipwy7weycrbdb7slmiu44mmhvnxsrizrrs2w7dpag5wur6hga`),
   MySQL ACTIVE, Terraform state consistent with live.
2. **Observation window elapsed** since the retest (the approved retest
   procedure's app→MySQL 3306 path verified repeatedly through the NSG
   pairing — the operator sets the window when signing).
3. Fresh evidence that the app-NSG→db-NSG path carries the 3306 traffic
   (in-VM protocol-level greeting from BOTH VMs after the NSG attachment,
   via the approved SSH source).
4. Fresh manifests + ETags + hashes captured at execution time (the
   baseline below predates the retest and MUST be re-read; the guarded
   script refuses stale hashes).

## Baseline captured 2026-10-28T20:5xZ (post-IAM-apply, pre-retest)

- Ingress: exactly 1 rule — `TCP 3306, source 10.0.2.0/24, protocol 6`
  (the transitional rule this package removes).
- Egress: 1 rule (unchanged by this package).
- Live object snapshot hash (with ingress+egress arrays):
  `5b8878b15c70206a63ef47eb4f7ebb7f37ab79545e7205f33e9111ebb1fb1277`
  — reference only; regenerate before execution.

## Recovery

The list's prior state is this baseline plus the recorded pre-change ETag;
`eventforge-sl-update` re-applies the retained-rule manifest if a rollback is
ever approved. The bucket/state are unaffected (security lists are not in the
Terraform state — the platform root imports no SL).

## Explicitly out of scope

No SSH-source change (the rotated workstation IP
`49.207.216.108` vs the approved `49.207.214.221/32` is a separate decision),
no LB/app SL change, no NSG rule change, no MySQL change, no ingress
enablement, no public exposure of any kind.

Dated statement: I reviewed the captured baseline, the preconditions, and the
stop conditions, and I authorize exactly this one rule removal — no other
security list, no other rule, no ingress enablement.
Date: <YYYY-MM-DD>
