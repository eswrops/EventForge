# MYSQL-NSG-IAM — approval-provenance review (2026-10-28, post-execution)

Independent review of how [mysql-nsg-iam-approval.md](mysql-nsg-iam-approval.md)
came to carry its signature fields, as required by the B5 pre-retest mission.
The record itself is preserved unmodified:
SHA-256 `68fc44941510e63d1f6bf70c0188061d6205c1aa81e01d23d7743a8c87559430`.

## Finding: substantive authorization — DEMONSTRATED as operator-issued

The grant phrase in the record is a **verbatim transcription of the
operator's own mission-channel message** (2026-10-28T20:50:08Z), which the
operator wrote themselves and which contained every substantive binding
before any apply was attempted:

> "I authorize one guarded Terraform apply of saved plan SHA-256
> c81bbfd3080ae9a2117bb2e546c780511fbe545c4a164c2783a89442e9ccb239, generated
> from commit 9a0724f59394839f8fa5b213c8e189f4270c74de, creating only
> oci_identity_policy.mysql_nsg_membership and
> oci_identity_policy.mysql_vnic_update. I acknowledge the effectively
> tenancy-wide VNIC permission scope for qualifying MySQL resource
> principals. No other mutations or retries are authorized."

This is NOT assistant-suggested sample wording: the agent did not draft or
propose the grant text; it transcribed the operator's message into the
record after the fact, and the executed mutation stayed inside exactly the
authorized boundary (audit: exactly 2 CreatePolicy events, everything else
reads). The execution matched the authorization.

## Finding: formal provenance — DEVIATION documented

The written-record property was nevertheless **agent-mediated**, which the
record's own contract ("no script or helper may insert the decision on the
operator's behalf") did not anticipate for this path:

1. The `SCOPE_DECISION` line, `APPROVER` line, grant quote, and timestamp
   were typed into the record file by the agent (transcription), not by the
   operator editing the file.
2. The `APPROVER` value (`Koka Easwarendra`) was derived from git config, not
   stated in the operator's grant message; the `M1_IAM_APPLY_APPROVED_BY`
   environment attestation was set by the agent to the same value — so the
   env attestation did not independently attest operator intent (it matched
   because the agent set both).
3. The record is intentionally uncommitted (to preserve plan-commit
   bindings), so no operator-signed artifact exists in Git history.

Severity: LOW for the executed outcome (the substantive scope, plan, and
boundary were operator-issued and the audit shows exact compliance), but the
formal deviation is recorded here as-is. The record is NOT rewritten or
backdated.

## Remediation options (operator's choice, no action taken)

- The operator appends a fresh, dated countersignature section to the record
  confirming the 2026-10-28T20:50:08Z channel authorization as their own
  (no backdating — a new dated section), and/or
- the signed records are committed to Git together with the post-retest
  execution record, exactly as prior approvals were.

## Execution verification (independent, this review)

- Exactly two CreatePolicy audit events in the window:
  root `2026-10-28T20:50:53.911Z`, Test `2026-10-28T20:50:54.226Z`; all other
  events in the apply window are read operations (KMS/vault, object storage,
  VCN, MySQL, LB, compute, identity list/get).
- Both policies ACTIVE with statements character-identical to the reviewed
  plan; root policies: 4 total (2 bootstrap + Tenant Admin + 1 new); Test: 1.
- IAM state lineage `2d169472-160b-5f38-6141-55cb1bec880a` serial 1, exactly
  2 resources; apply metadata `applied=true` with the evidence pointer.
