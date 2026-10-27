# Terraform upstream regression tests — state migration metadata reset

Offline regression tests for the Terraform 1.12.2 defect that reset state
`lineage`/`serial` during backend migration. They run against a Terraform
source tree only — never against production infrastructure — and are committed
here as acceptance evidence and as the upstreamable reproduction.

Everything in this directory is sanitized: synthetic lineage UUID, synthetic
bucket/namespace/region, no credentials, no OCI access (the backend tests run
against an in-process mock of the Object Storage REST API).

## Contents

| File | Destination in a Terraform source tree | Purpose |
| --- | --- | --- |
| `states-remote-migration_metadata_repro_test.go` | `internal/states/remote/` | Unit repro/regression: `remote.State.PersistState` discarding metadata staged by `WriteStateForMigration`; mid-flight destination appearance; Get/Put failure handling |
| `oci-backend_migration_metadata_test.go` | `internal/backend/remote-state/oci/` (together with the lifecycle file) | Backend-level repro through the real `oci.Backend.StateMgr`/`Workspaces` path against a mock Object Storage server |
| `oci-backend_lifecycle_offline_test.go` | `internal/backend/remote-state/oci/` | Offline analogues of the live disposable-key probes: lock contention, version recovery, authorization denial |
| `remote-state-serial-lineage-fix.patch` | applied at `internal/states/remote/state.go` | Candidate upstream fix: (hunk 1) preserve staged migration metadata across the internal refresh; (hunk 2) refuse to overwrite a destination snapshot that appeared mid-flight |

## Reproducing with a clean source checkout

1. Obtain the Terraform 1.12.2 source archive from the official release and
   extract it (any disposable location; nothing outside the tree is touched).
2. Copy the test files to the destinations above (rename them freely; names
   here carry path prefixes because they live in one flat directory).
3. Run the commands below. Go ≥ 1.24 (module requirement); module downloads
   come from the public proxy.

### Exact commands and expected results

Unpatched tree (the defect reproduces; the mid-flight guard is missing):

```bash
cd <tree> && go test ./internal/states/remote/ -run 'TestMigration|TestPersistState' -v
# EXIT 1:
#   FAIL TestMigrationToAbsentRemote_PreservesMetadata         (lineage lost, serial 1)
#   FAIL TestMigrationWithoutRefresh_PreservesMetadata         (lineage lost, serial 1)
#   FAIL TestMigrationDestinationAppearsBeforePersist_RefusesOverwrite (silent overwrite)
#   PASS TestMigrationDestinationPreInitialized_PreservesMetadata
#   PASS TestPersistStateGeneratesLineageForGenuinelyNewState
#   PASS TestPersistStatePropagatesGetFailure
```

Patched tree:

```bash
cd <tree> && go test ./internal/states/remote/ -v        # EXIT 0 (14 PASS)
cd <tree> && go test ./internal/states/remote/ -race     # EXIT 0
cd <tree> && go test ./internal/states/...               # EXIT 0
cd <tree>/internal/backend/remote-state/oci && \
  go test . -run 'TestDefaultWorkspaceStateMgr|TestMigration|TestOffline' -v   # EXIT 0 (6 PASS)
```

Recorded validation (2026-10-27, Go 1.27.1, darwin/arm64) lives in the session
evidence directory as `repro-clean/validation-20261027/` (logs + commands);
forensic snapshots are never committed to this repository.

Resource-equality requirement: every metadata assertion also asserts
`statefile.StatesMarshalEqual(persisted, source)`; in the unpatched failures
only lineage/serial diverge — "resource data changed" never fires.

## Patch review against the six review properties

| # | Property | Verdict | Evidence |
| --- | --- | --- | --- |
| 1 | Preserves lineage/serial migrating to a genuinely absent destination | Fixed | `TestMigrationToAbsentRemote_PreservesMetadata`, `TestMigrationWithoutRefresh_PreservesMetadata`, `TestMigrationToAbsentDefaultWorkspace_PreservesMetadata`: fail unpatched, pass patched |
| 2 | Does not accidentally overwrite an existing state | Preserved | The hunk only runs when `s.lineage == ""` after the internal refresh, i.e. the remote provably holds no snapshot; every existing-destination path is byte-identical to 1.12.2 (`TestMigrationDestinationPreInitialized_*`, full `internal/states/...` suites pass unchanged) |
| 3 | Destination appearing between existence check and persistence | Hardened (hunk 2) | Unpatched: staged resources silently overwrite the appeared snapshot under its own lineage/serial with no validity check (`TestMigrationDestinationAppearsBeforePersist_RefusesOverwrite` fails unpatched). Patched: `PersistState` returns a conflict error naming both lineages; the appeared snapshot is untouched |
| 4 | No silent bypass of lineage/serial protections when state exists | Preserved/strengthened | No `CheckValidImport` semantics changed; hunk 2 adds a protection that did not exist. `TestWriteStateForMigration*` import-guard cases pass unchanged |
| 5 | Failed Get/Put/Lock/Unlock handled correctly | Preserved, now pinned | Get failure aborts before any Put (`TestPersistStatePropagatesGetFailure`); Put failure returns the error, persists nothing, and allows a successful retry (`TestPutFailureAllowsRetry`; the failed attempt may consume a serial number, consistent with 1.12.2's existing failed-persist behavior); Lock/Unlock are not touched by the patch |
| 6 | Ordinary initialization and updates unchanged | Preserved | `TestPersistStateGeneratesLineageForGenuinelyNewState` (fresh lineage + serial 1 minting retained), `TestStatePersist`, `TestStateRace` (-race clean), full `internal/states/...` |

Known pre-existing behavior, deliberately not changed and out of the patch's
scope: `PersistState`'s plain-write race (no staged migration metadata, remote
appears unrefreshed) still writes at the appeared snapshot's serial; all core
flows hold backend locks or refresh first (`state push` always refreshes;
`init -migrate-state` refreshes twice), so that window is only reachable by
unrefreshed custom callers.

## Offline lifecycle coverage

`oci-backend_lifecycle_offline_test.go` adds production-safe analogues of the
live disposable-key probes: lock acquisition, contender rejection surfacing the
holder's lock info, unlock + re-lock, version listing and recovery by copying a
prior version onto the live key (never `state push -force`), and a distinct 403
authorization-denial path. These prove the backend logic offline; they are not
evidence about the production OCI bucket.
