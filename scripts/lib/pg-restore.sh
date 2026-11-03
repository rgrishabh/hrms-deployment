#!/usr/bin/env bash
# Restore a backup into an EMPTY target database (never overwrites a populated one).
# Usage: scripts/restore.sh <dump_file> <target_database_url>
set -euo pipefail
FILE=${1:?dump file required}; URL=${2:?target database url required}
shasum -a 256 -c "$FILE.sha256"
TABLES=$(psql "$URL" -Atc "SELECT count(*) FROM information_schema.tables WHERE table_schema='public'")
if [ "$TABLES" != "0" ]; then echo "refusing: target database already has $TABLES tables" >&2; exit 1; fi
pg_restore --no-owner --exit-on-error --dbname="$URL" "$FILE"
echo "restore complete. Verify row counts and run migrations (should be a no-op)."
