# M1-LOCAL cost and quota findings (2026-10-27)

## Current estate (live, read-only verification)

| Resource | Usage | Always Free eligibility |
| --- | --- | --- |
| 2× compute `VM.Standard.E2.1.Micro` | RUNNING, 1 OCPU / 1 GB each, AD-1 | Eligible (2 AMD micro VMs) |
| MySQL `MySQL.Free` | ACTIVE, 10.0.3.18:3306, 1-day backups | Eligible (MySQL.HeatWave.Free) |
| Flexible LB 10–10 Mbps | 1 public IP 129.159.239.48, no listeners | Eligible (10 Mbps flexible LB) |
| Object Storage | state bucket ~16 KB + retained validation keys; backups bucket empty | Eligible (20 GB object storage; states and backups are tiny) |
| ONS | 1 topic, 1 email subscription | Free tier |
| Vault / CMK | 1 software-protected key, 1 vault | Virtual vault + 20 key versions free; SOFTWARE protection (not HSM) |

**Projected monthly OCI charge: $0** for the accepted baseline and for the entire planned
additive platform plan — NSGs, NSG rules, alarms (well inside the free allocation of the first
10 alarms), and budgets are free-tier services.

## Planned additive resources — no cost change

3 NSGs, 19 NSG rules, 2 alarms, 1 budget + 3 alert rules, 1 `terraform_data` marker: all free.
`enable_api_ingress=false` keeps out the resources that could add cost or Origin CA consumption.

## Billable exposure to watch (Phase 6 monitoring)

- Flexible LB bandwidth **above** the 10 Mbps minimum becomes billable; the imported resource
  pins 10–10 and `prevent_destroy`; any reshape is a reviewed existing-resource update.
- Outbound data transfer beyond the monthly Always Free egress allowance (10 TB) — not
  approached by current state/validation traffic.
- Object Storage beyond 20 GB or retention of large validation artifacts — states are KB-scale.
- Alarm count above the free allocation or alarm-status API calls — negligible at 2 alarms.
- MySQL upgrade off `MySQL.Free`, or compute shape change — each is a ForceNew replacement,
  blocked by `prevent_destroy` and the safe-plan policy.
- The monthly budget (`eventforge-monthly`, amount 5) with 75/100/forecast alerts is the
  runtime tripwire; note its email alerts depend on the ONS-adjacent email confirmation
  status in [blockers.md](blockers.md) (budget alert recipients receive mail directly; the
  ONS subscription covers alarms).

## Quota findings (live limits API, 2026-10-27 post-apply)

- **Compute free-tier quota is fully consumed**: `standard-e2-micro-core-count` in AD-1 shows
  `available=0, used=2`. No additional free micro VM can be created in this region/AD — any
  M2 compute provisioning needs a different shape (billable) or a quota change. The two
  running API hosts occupy the entire free allocation.
- MySQL free-tier and LB limits were not precisely queryable with the available read-only
  limit names (`mysql-2-count` reports available=0/used=0 while the ACTIVE `MySQL.Free`
  system exists; `lb-10mbps-micro-count` rejected by the API) — recorded as unverified; the
  running estate demonstrates the quota is sufficient for one LB + one MySQL system.
- NSG/rule/alarm/budget counts are far below service limits; no limit increase is needed.

## Verification boundaries (what was and was not proven)

Verified read-only 2026-10-27: 2 alarms enabled with valid metric namespaces
(`oci_computeagent` CPU query, `oci_lbaas` unhealthy-backend query) → topic
`eventforge-operations` **ACTIVE**; ONS email subscription `eswr.ops@gmail.com` still
**PENDING** confirmation (alarm delivery must not be marked PASS); budget `eventforge-monthly`
at tenancy root targeting the Test compartment, amount 5, three alert rules
(75/100 actual, 100 forecast) to `eswr.ops@gmail.com`; state-bucket lifecycle 30-day
noncurrent-version DELETE; state CMK **ENABLED**.

Not verifiable read-only with this CLI setup: **actual billed cost** — the usage/cost
summaries require creating a saved query (a tenancy write, not authorized by this mission)
and the tenancy cost-report bucket is not accessible via object storage. The Always-Free
eligibility table above is an assessment from resource counts and must not be read as a
billing guarantee; the $5 monthly budget with its three alert rules is the runtime tripwire
(email delivery for budget alerts is separate from the ONS alarm subscription and likewise
requires a real alert to prove).
