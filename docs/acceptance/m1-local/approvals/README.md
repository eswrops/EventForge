# M1-LOCAL approval records

Production mutations are authorized by **written records in this directory plus the
operator's matching environment attestation** — never by an environment variable alone,
never by a passed technical policy check alone. Each record is committed (part of the
acceptance history) and is verified by the executing script before anything runs.

## Contract

A record must contain, in plain text:

- `GATE: <gate marker>` — exactly one of `OCI-IMPORT`, `PLATFORM-APPLY`,
  `PLATFORM-INIT-EXISTING-STATE`, `SL-CORRECTION`;
- `APPROVER: <name>` — the operator's name as it will appear in the env attestation
  (`M1_IMPORT_APPROVED_BY` / `M1_APPLY_APPROVED_BY` / `M1_SCOPE_A_APPROVED_BY`);
- the gate-specific bindings the script verifies:
  - **OCI-IMPORT**: the current commit SHA and all eight resource addresses;
  - **PLATFORM-APPLY**: the saved plan's SHA-256 and the source commit SHA;
  - **PLATFORM-INIT-EXISTING-STATE**: the live state lineage being acknowledged;
  - **SL-CORRECTION**: all three scope-A security-list manifests' recorded rule-array
    hashes (verified by `scripts/ops/eventforge-sl-update` before any write).
- a dated statement that the operator reviewed the referenced artifacts.

A record without the exact bindings fails closed; a mismatching `M1_*_APPROVED_BY`
attestation fails closed. Templates: [oci-import-approval.template](oci-import-approval.template),
[platform-apply-approval.template](platform-apply-approval.template),
[scope-a-sl-correction.template](scope-a-sl-correction.template).

## Status

Executed under written records: OCI-IMPORT (2026-10-27, [oci-import-approval.md](oci-import-approval.md)),
PLATFORM-APPLY (2026-10-27, [platform-apply-approval.md](platform-apply-approval.md) +
[platform-apply-approval-2-budget-fix.md](platform-apply-approval-2-budget-fix.md)),
**Scope-A PLATFORM-APPLY (2026-10-28, [scope-a-apply-approval.md](scope-a-apply-approval.md),
plan SHA `8cce2da3…`) and SL-CORRECTION (2026-10-28, [scope-a-sl-correction.md](scope-a-sl-correction.md))**
— see the execution record in
[../scope-a-network-execution-approval.md](../scope-a-network-execution-approval.md) §14.
Pending: none (the MySQL DB-NSG attachment is service-blocked — B5 — and is not approvable
until the platform supports it).
