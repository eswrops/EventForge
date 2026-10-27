# Phase 4 — OCI remote state: state-identity root-cause verification

Status: 2026-10-27, offline verification complete against the checksum-verified
Terraform 1.12.2 source archive. The approved bootstrap migration executed under
explicit STATE-MIGRATION approval (procedure:
[state-recovery.md §1–§2](../../m1b-bootstrap/state-recovery.md)). The resulting
remote snapshot preserved every resource and output but carried a **regenerated
lineage and serial 1** (source: lineage `edd2f249…`, serial `17`; remote: fresh
lineage `a79177dd…`, serial `1`). The already-made **ACCEPT_TRANSITION decision
stands**: the migrated state is live and accepted, production state is not
rewritten, and no further migration runs. This file records the offline
root-cause verification, the regression tests, and the approval boundaries that
remain.

## Acceptance status

| Area | Status |
| --- | --- |
| STATE-MIGRATION | **PASS** — accepted metadata-only lineage transition; resource data verified identical; offline root-cause verification complete (§2–§4) |
| STATE-LOCKING | **NOT_RUN** for live OCI verification (offline mock analogue only, §5) |
| STATE-CONTENTION | **NOT_RUN** for live OCI verification (offline mock analogue only, §5) |
| STATE-RECOVERY | **NOT_RUN** for live OCI verification (offline mock analogue only, §5) |
| IAM-DENIAL | **NOT_RUN** for live OCI verification (offline mock analogue only, §5) |

Mock-server results demonstrate backend logic only and are **not** proof of
production OCI behavior. Live verification requires the approval package in
[live-backend-validation-approval.md](live-backend-validation-approval.md) and
must not start until it is explicitly approved.

## 1. Production observation (read-only forensics)

Captured in the session evidence directory (never committed):

| Snapshot | Lineage | Serial | Resources | Outputs |
| --- | --- | --- | --- | --- |
| Pre-migration backup (`source-backup.tfstate`) | `edd2f249…` | 17 | 8 | 3 |
| Remote after migration (`remote-raw.tfstate`) | `a79177dd…` | 1 | 8 | 3 |

Top-level JSON diff keys: `check_results, lineage, serial` — resource and output
data are identical. `check_results` differs only in the order/content of `var`
check entries (a secondary serialization-order observation; no resource data
affected). The bucket's version list shows **exactly one** version of
`bootstrap/terraform.tfstate`, which proves the backend's absent-state
initialization branch never wrote an intermediate empty snapshot (see §3).

## 2. Reproduction (offline; no OCI access, no production state)

Two levels, both against the supplied unmodified Terraform 1.12.2 source
archive, with tests now committed under
[tests/terraform-upstream](../../../tests/terraform-upstream/README.md):

1. **Unit level** (`internal/states/remote`): isolated `remote.State` with an
   in-memory mock client whose store is empty. `RefreshState()` (destination
   absent) → `WriteStateForMigration(sourceLineage, serial 17, force=true)` →
   `PersistState(nil)` → persisted snapshot has a **fresh lineage and serial 1**
   with identical resource data — the exact production signature. The manager's
   own debug log shows the clobber in place:

   ```
   [DEBUG] states/remote: state read serial is: 0; serial is: 17
   [DEBUG] states/remote: state read lineage is: ; lineage is: edd2f249-…
   [DEBUG] states/remote: after refresh, state read serial is: 0; serial is: 0
   [DEBUG] states/remote: after refresh, state read lineage is: ; lineage is:
   ```

2. **Backend level** (`internal/backend/remote-state/oci`): the real
   `oci.Backend` driven against an in-process mock of the Object Storage REST
   API (`ListObjects`/`HeadObject`/`GetObject`/`PutObject`/`DeleteObject`/
   `objectversions`). `StateMgr("default")` → `statemgr.Migrate` →
   `PersistState(nil)` reproduces the same reset; the mock bucket also confirms
   the absent state object is never created during initialization (one version
   written in total, as in production).

## 3. Exact call chain (`terraform init -migrate-state`, local → oci, default workspace)

```
Meta.backendMigrateState                               internal/command/meta_backend.go:904
└─ backendMigrateState_s_s                             internal/command/meta_backend_migrate.go:260
   ├─ oci.Backend.StateMgr("default")                  internal/backend/remote-state/oci/backend_state.go:27
   │    Workspaces() seeds ["default"] unconditionally (backend_state.go:141)
   │    → exists=true → the absent-state create/refresh branch (:63–106) is skipped:
   │      no refresh, no empty-state initialization, object stays absent
   ├─ destinationState.RefreshState()                  meta_backend_migrate.go:316 (again :374)
   │    states/remote/state.go:137 refreshState():
   │      oci RemoteClient.Get() on 404 returns (nil, nil)   oci/client.go:37
   │      → payload==nil → s.readState=nil, s.lineage="", s.serial=0
   ├─ destination.Empty() → backendMigrateEmptyConfirm  meta_backend_migrate.go:397,462
   ├─ statemgr.Migrate(dst, src)                        meta_backend_migrate.go:445
   │    internal/states/statemgr/migrate.go:58 → dst.WriteStateForMigration(srcFile, true)
   │    → stages s.lineage="edd2f249…", s.serial=17, s.state=resources
   └─ destinationState.PersistState(nil)                meta_backend_migrate.go:453
        internal/states/remote/state.go:169 PersistState, readState==nil branch:
          refreshState() runs again → **resets staged s.lineage→"", s.serial→0**
          (state.go:146–148 run on a nil payload)
          → s.lineage=="" is misread as "no state snapshot present yet" (state.go:195)
          → uuid.GenerateUUID(); s.serial++ → 1
        → Client.Put({resources, fresh lineage, serial 1})
```

**Root cause (one site):** `remote.State.PersistState`'s no-remote-snapshot
branch calls `refreshState()`, which unconditionally resets the *current*
`lineage`/`serial` fields — the same fields `WriteStateForMigration` uses to
stage migration metadata — and the code then misinterprets the wiped lineage as
"brand new state". This violates `statemgr.Migrate`'s documented contract
("preserving snapshot metadata (serial and lineage) where possible",
`statemgr/migrate.go:42`). The same reset also affects `terraform state push`
to a key whose remote object does not exist yet
(`internal/command/state_push.go:131–147` uses `Import` + `PersistState`).
The contrast case proves the staging itself is sound: when the destination
object exists (any earlier initialization), the metadata is preserved and the
serial advances 17→18.

## 4. Root-cause verification (fix differential)

`tests/terraform-upstream/remote-state-serial-lineage-fix.patch` preserves the
staged lineage/serial across the internal refresh and restores them (serial+1)
when the remote is absent and a migration staged metadata. Results:

| Suite | Unpatched 1.12.2 | Patched |
| --- | --- | --- |
| Migration-to-absent-destination (unit ×2, backend ×1) | FAIL — fresh lineage, serial 1 | PASS |
| Migration-to-preinitialized-destination (unit, backend) | PASS | PASS |
| Genuinely-new-state lineage minting | PASS (behavior retained) | PASS |
| `./internal/states/...` full suites | — | PASS (no regressions) |

**Root-cause confidence: very high.** The single site is both necessary and
sufficient to produce the observed production behavior, verified by the fix
differential and a green full `internal/states` suite on the patched tree.

## 5. Offline lifecycle coverage (not live evidence)

`oci-backend_lifecycle_offline_test.go` adds production-safe analogues of the
live disposable-key probes (state-recovery.md §5, §7): lock acquisition,
contender rejection with the holder's lock info surfaced, unlock + re-lock,
version listing and recovery by copying a prior version onto the live key
(never `state push -force`), and a distinct 403 authorization-denial path.
All pass against the 1.12.2 tree. **These are logic checks against an
in-process mock server; they are not evidence about the production bucket and
do not substitute for the live runs in §7.**

## 6. Decision preserved — ACCEPT_TRANSITION

- The live `bootstrap/terraform.tfstate` (lineage `a79177dd…`, serial 1) is
  **accepted as-is**. No re-migration, no `state push`, no lock-object
  deletion, no resource imports beyond the separately approved plan.
- The pre-migration backup (lineage `edd2f249…`, serial 17) stays in the secure
  evidence store. It is an **unrelated lineage** to the live state: any future
  push of it requires force semantics and must never be attempted as a "restore".
- Consequence to record in runbooks: serial continuity now starts at 1 for the
  new lineage. Backup/audit tooling must key on lineage; comparisons against
  pre-migration serials are meaningless.
- The `check_results` ordering difference between the two snapshots was noted
  and accepted (no resource data affected).

## 7. Remaining approval boundaries (unchanged, still operator-gated)

1. Live `scripts/ci/verify-oci-backend.sh` (hardened: mandatory `RUN_ID`
   confinement, approved-coordinate fail-closed checks, Terraform 1.12.2 pin,
   EXIT/INT/TERM reaping and evidence preservation) under the
   [live-backend-validation-approval.md](live-backend-validation-approval.md)
   package, recording the real lock-object suffix for the federation policy
   (§5).
2. Live `scripts/ci/verify-oci-backend-denied.sh` with an explicitly
   underprivileged principal in the federation phase (redacted denial
   evidence); deferred — never run under the privileged operator profile, and
   no PASS claimed from administrator-profile or mock runs.
3. Encryption validation (§6: bucket/object KMS id + versioning = Enabled).
4. Version-recovery rehearsal on `validation/` keys per §7 via the committed
   `scripts/acceptance/oci-state-version-recovery.sh` (offline regression
   tests exist; live rehearsal still requires approval).
5. `platform/` and `frontend/` backend migrations: each requires its own
   STATE-MIGRATION approval; given this defect, each must take its §2 backup
   and record lineage/serial before and after. A patched Terraform (or an
   accepted serial/lineage reset) must be decided explicitly per root.
6. Production state writes of any kind remain prohibited without a fresh
   incident approval.

## 8. Upstream report

Sanitized draft: [terraform-upstream-issue.md](terraform-upstream-issue.md).
Reproduction requires only the Terraform source tree and Go — no cloud account,
no customer data.
