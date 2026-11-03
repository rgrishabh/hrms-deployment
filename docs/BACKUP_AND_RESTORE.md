# Backup and restore

> **Status:** a **local** backup → restore drill was performed on 2026-11-03 with `scripts/backup.sh` / `scripts/restore.sh` (PostgreSQL 17, synthetic seed data). Results: checksum verified; row counts identical for tenants, employees, attendance events/daily, audit logs and migrations; restore into a non-empty target refused; `migrate` was a no-op on the restored copy; RLS still enforced for `hrms_app`. The drill found and fixed a real defect: `FORCE ROW LEVEL SECURITY` made `pg_dump` fail as the owner (migration 004, DECISIONS D15). **No AWS/RDS restore has been rehearsed, and no RPO/RTO has been approved.** Both are required before go-live.

## Proposed objectives (to be approved by the business)

| | Proposal |
|---|---|
| RPO | ≤ 5 minutes (RDS point-in-time recovery) |
| RTO | ≤ 2 hours for full-region-AZ failure (Multi-AZ failover is automatic, minutes); ≤ 4 hours for logical-corruption restore |

## Production (AWS RDS) — target

- Automated backups with PITR (retention 14–35 days), encrypted with KMS.
- Manual snapshot before every migration run (DEPLOYMENT.md).
- Weekly snapshot copy to a second region (or AWS Backup vault with vault lock) for ransomware/account-compromise protection.
- S3 (when documents ship): versioning + Object Lock (governance) + lifecycle rules.

### Restore drill (perform quarterly; record results in OPERATIONS_RUNBOOK.md)
1. Restore the PITR target to a **new** instance (never overwrite production).
2. Run `npm run migrate` against it (should be a no-op). Start an API task pointed at it.
3. Verify: row counts per table vs the source at the restore time, `audit_logs` max id, a sample tenant login, `scripts/smoke.sh` against a staging host.
4. Record the elapsed time (actual RTO) and data gap (actual RPO).

## Self-managed / local

```bash
scripts/backup.sh  postgres://hrms_owner:…@host:5432/hrms_dev  ./backups
scripts/restore.sh ./backups/hrms_dev-<timestamp>.dump postgres://hrms_owner:…@host:5432/hrms_restore_target
```

`backup.sh` uses `pg_dump -Fc` (custom format, compressed) and writes a SHA-256 checksum. `restore.sh` verifies the checksum, refuses to restore into a database that already has tables, and restores with `--no-owner`. Re-run migration 003's grant section afterwards if roles differ. Backups contain personal data: store them encrypted with restricted access, and never copy production backups to test environments.
