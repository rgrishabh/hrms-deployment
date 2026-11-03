# Operations runbook

## Health

| Endpoint | Meaning | Use |
|---|---|---|
| `GET /health/live` | Process is up | ECS/ALB liveness |
| `GET /health/ready` | Database reachable, migrations current, installation bootstrapped | ALB target / Compose health; 503 otherwise |

Logs are JSON (pino) with a `reqId` per request. Error responses include `Reference: <reqId>` so a user's report can be matched to a log line. Cookie, authorization, CSRF and device-key headers are redacted.

## Common tasks

### Deploy a new customer
See DEPLOYMENT.md §1 (Docker Compose) or §2 (Terraform). There is no in-app provisioning.

### Users can't reach the site
1. `GET https://<host>/api/v1/public/config`. A 404 means the hostname isn't in `APP_URL`/`APP_EXTRA_DOMAINS`; fix the deployment config and restart.
2. A 503 on `/health/ready` means not bootstrapped, migrations pending, or the database is unreachable (`docker compose logs migrate app`).
3. Check DNS and the TLS certificate (Caddy logs / ACM).

### Administrator lost access
`docker compose --profile tools run --rm bootstrap --reset-admin --admin-email <email>` (or the AWS equivalent in DEPLOYMENT.md §5) prints a new one-time link and revokes the old password and sessions.

### User locked out
Settings center → Users → Manage → Unlock account (audited). The lockout lifts by itself after 15 minutes.

### Revoke access immediately
Disable the user (Settings → Users) or change their roles. Either revokes all their sessions. To stop a whole installation: `docker compose stop app` or scale the ECS service to 0.

### Biometric device not syncing
Attendance setup → Biometric devices: check last sync, clock drift warning, status. Common causes: device disabled, key rotated but not updated on the device or bridge, or `attendance.biometric` removed from `ENABLED_MODULES` (ingestion returns 403 `feature_unavailable`). Events from unknown enrolment IDs appear under **Unmapped device events**. Map them and they're processed automatically.

### Attendance shows "Not calculated"
The `attendance.close_day` job calculates yesterday at 01:30 (organization time). For today, or to redo a range: Team attendance → Recalculate this day, or `POST /api/v1/attendance/recalculate` (≤ 62 days). Locked days are skipped by design.

### Background jobs
Settings → Scheduled jobs shows each job's schedule, next run, last runs and errors, plus Run now (needs the job's permission; audited). Jobs: `attendance.close_day` (daily 01:30), `leave.accrual` (monthly, 1st 02:00), `sessions.cleanup` (daily 03:00). A failed run retries up to 3 times with 5-minute backoff steps. A run left `running` by a crashed process is failed and retried after 60 minutes. Every job is idempotent. With several instances, the database guarantees one run per period. Disable the scheduler on an instance with `JOBS_ENABLED=false`. CLI: `docker compose exec app node dist/src/core/jobs/cli.js run leave.accrual` (or `tick`).

### Correct attendance after a payroll lock
Locked periods cannot change. A post-lock correction requires the payroll adjustment workflow (not yet implemented). Until it exists, record the correction outside the system and flag it to payroll.

### Rotate the field-encryption key
**No tooling exists yet.** Do not change `DATA_ENCRYPTION_KEY`: existing bank account ciphertexts would become unreadable. The plan is versioned keys (`v2.` prefix) plus a re-encryption job.

## Incident response (summary)
1. Triage severity. A suspected data exposure or credential leak is always Sev-1.
2. Contain: stop the installation's app if needed, disable users, rotate device keys, revoke sessions (`UPDATE sessions SET revoked_at = now()`), rotate DB passwords (DEPLOYMENT.md §11).
3. Preserve evidence: audit logs are append-only, so export the relevant range.
4. Assess notification duties (DPDP Act, contracts) with legal.
5. Postmortem: blameless, with action items.

## Drill log

| Date | Drill | Environment | Result |
|---|---|---|---|
| 2026-11-03 | Backup → restore (pg_dump/pg_restore) | Local PostgreSQL 17 | Pass after fixing the FORCE RLS defect (migration 004). Row counts matched |
| 2026-11-03 | Compose sequence (provision → migrate → bootstrap → app → setup link → login) with Compose-resolved env | Throwaway local PostgreSQL 17 (no Docker engine) | Pass |
