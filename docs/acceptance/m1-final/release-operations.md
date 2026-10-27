# M1 final — release operations readiness

Status: **PREPARED** (exit gate met) · Evidence commit: the changes merged as
`1d0c7e6` ([PR #13](https://github.com/eswrops/EventForge/pull/13)) · Dry-run suite:
`tests/release/test-install-release.sh` (12 scenarios, offline, CI-integrated) ·
Date: 2026-10-27

No application binary was built, no systemd service was started or changed on any VM, and
`/readyz` success was never required outside an install — per the mission constraints. The
deployment mechanism is proven by offline dry-runs with PATH-stubbed `curl`/`systemctl` and a
redirected release root; production defaults are unchanged.

## 1. Audit results

| Item | Result | Note |
| --- | --- | --- |
| API systemd template | OK | `Type=simple`, `Restart=on-failure`, `TimeoutStopSec=30`, `MemoryMax=256M`, `NoNewPrivileges`, `ProtectSystem=strict`, `PrivateTmp` |
| Worker systemd template | OK | Same posture; `TimeoutStopSec=60` for longer drain |
| Release fetcher | OK | GitHub release API by immutable tag; per-asset `jq -er` (missing asset fails) |
| Checksum verification | **fixed** | Was vacuous when `SHA256SUMS` lacked entries for the downloaded binaries (`--check --ignore-missing`); now requires exactly the two published entries + `--check --strict` |
| Versioned symlink switching | **fixed** | `ln -sfn` was unlink+recreate; switching is now rename(2) (`mv -Tf`; perl-rename fallback — BSD `mv -f` follows a symlink-to-directory destination, caught live by the harness) |
| Release rollback | **fixed** | Health-check exhaustion exited directly and never triggered the ERR trap; it now rolls back through it. ERR traps need `set -E` to fire inside functions — added |
| Health-check polling | OK | 18 × 5 s `/readyz` budget (test seams `EVENTFORGE_READYZ_POLLS`/`EVENTFORGE_POLL_INTERVAL`, defaults unchanged) |
| VM1-then-VM2 ordering | OPERATOR PROCEDURE | The installer is per-host by design: install on `rust-api-test` first, require a healthy `/readyz`, only then `rust-api-worker`. A failed VM1 run cannot touch VM2 (separate hosts, separate runs) |
| Download authentication | OK | `Authorization: Bearer $GITHUB_TOKEN` only when set (releases are public); dry-runs prove no header without a token and the token never appears in output |
| Secret-file permissions | OK (guidance added) | `/etc/eventforge/*.env` must be root:eventforge 0640; password files 0600 (installer now prints this) |
| Graceful shutdown | OK | systemd default `KillSignal=SIGTERM` with the stop windows above |
| Backup scheduling | OK | `eventforge-backup.timer` + script: 0600 temp defaults file with cleanup trap, gzip dump, instance-principal upload to `eventforge-backups` only, 14-day retention with fatal-on-failed-deletion |
| journald limits | ADDED | `SystemMaxUse=200M` drop-in (`ops/systemd/30-eventforge-journald.conf`) for the micro VMs' small boot volumes; rate limiting left at systemd defaults |

## 2. Dry-run verification matrix (12/12 PASS)

| Required behavior | Scenario |
| --- | --- |
| Bad checksum rejects release | tampered worker binary → reject, no switch, no service restart, partial dir cleaned |
| Missing artifact rejects release | release JSON without the worker asset → reject, cleaned |
| Invalid manifest rejects release | malformed manifest line → reject (entry-count contract) |
| Manifest coverage | sparse manifest (missing binary entry) → reject — regression test for the vacuous `--ignore-missing` pass |
| Symlink switching is atomic | rename(2) contract test + live harness proof on macOS (BSD mv follow bug caught and fixed) |
| Previous version is retained | second install keeps the full previous release dir |
| Failed health check initiates rollback | readyz exhaustion → previous release restored, both services restarted |
| Failed VM1 rollout never updates VM2 | structural (per-host runs); ordering documented as the operator procedure |
| Failed VM2 rollout leaves VM1 recoverable | VM1's `current` and release dir are untouched by a VM2 run |
| Secrets never appear in logs | GITHUB_TOKEN asserted absent from all installer output/service log; header present only when set |
| Duplicate immutable tag rejected | second install of the same tag → exit 1 |
| Success path | install → verify → atomic switch → api restart → readyz → worker restart |

CI run for the introducing PR: all four required contexts PASS (run
[40455716453](https://github.com/eswrops/EventForge/actions/runs/40455716453)).

## 3. Deliberately not done

No `eventforge-api`/`eventforge-worker` execution, no VM host changes, no `/readyz` deployment
requirement introduced, no backup execution against the production MySQL system (M2, separately
approved).
