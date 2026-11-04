# QA report

| ID | Module | Severity | Steps | Root cause | Fix | Test |
|---|---|---|---|---|---|---|
| DEP-001 | dev backup | High | Make `pg_dump` fail while the scheduler runs. Reproduced: `dev/tests/backup-loop.test.sh environments/dev/bin/backup-loop.sh` failed 19 of 38 assertions before the fix | The scheduler called `backup_now \|\| echo`, and POSIX `sh` ignores `set -e` inside a function called from `\|\|`. Every later step ran, printing `backup ok`, publishing a set without a dump and pruning good sets. Empty and unreadable dumps were never detected, and failed runs left `.hrms-*` dirs behind | Each step is checked explicitly. The dump must be non-empty and pass `pg_restore --list`. A failed run publishes nothing and prunes nothing. It writes `.last-failure`, which `--check` turns into an unhealthy container. Temp dirs age out after a success. Same script in both stacks | `dev/tests/backup-loop.test.sh` (76 assertions over both copies) |
