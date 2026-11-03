#!/bin/sh
# Runs inside the "backup" service (postgres image). Once a day at BACKUP_AT (container TZ):
# custom-format pg_dump + documents tarball + SHA-256 files into /backups, then prunes old sets.
set -eu
: "${BACKUP_AT:=02:30}" "${BACKUP_KEEP_DAYS:=7}"

backup_now() {
  ts=$(date +%Y%m%d-%H%M%S)
  tmp="/backups/.hrms-$ts"
  mkdir -p "$tmp"
  pg_dump --format=custom --no-owner --file="$tmp/db.dump"
  tar -C /storage -czf "$tmp/documents.tar.gz" .
  (cd "$tmp" && sha256sum db.dump documents.tar.gz > SHA256SUMS)
  mv "$tmp" "/backups/hrms-$ts"
  echo "backup ok: hrms-$ts ($(du -sh "/backups/hrms-$ts" | cut -f1))"
  find /backups -maxdepth 1 -type d -name 'hrms-*' -mtime "+$BACKUP_KEEP_DAYS" -exec rm -rf {} +
}

[ "${1:-}" = "--now" ] && { backup_now; exit 0; }
echo "backup scheduler: daily at $BACKUP_AT, keeping $BACKUP_KEEP_DAYS days"
last=""
while true; do
  today=$(date +%F)
  if [ "$(date +%H:%M)" = "$BACKUP_AT" ] && [ "$last" != "$today" ]; then
    backup_now || echo "backup FAILED" >&2
    last=$today
  fi
  sleep 30
done
