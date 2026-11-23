#!/bin/sh
# Runs inside the "backup" service (postgres image). Once a day at BACKUP_AT (container TZ):
# custom-format pg_dump + documents tarball + SHA-256 files into /backups, then prunes old sets.
#   backup-loop.sh          scheduler
#   backup-loop.sh --now    one backup, exit status tells whether it worked
#   backup-loop.sh --check  health check: fails after a failed run or when the last success is too old
#
# Every step is checked explicitly. `set -e` cannot be relied on here: it is ignored inside a
# function called from `backup_now || ...`, which is how a failed pg_dump used to print "backup ok".
# A failed run keeps its .hrms-* temp dir for diagnosis, publishes nothing and prunes nothing.
set -eu
: "${BACKUP_AT:=02:30}" "${BACKUP_KEEP_DAYS:=7}" "${BACKUP_MAX_AGE_HOURS:=26}"
FAILURE_MARKER=/backups/.last-failure
SUCCESS_MARKER=/backups/.last-success

backup_failed() {
  echo "backup FAILED: $1" >&2
  date +%s > "$FAILURE_MARKER" 2>/dev/null || echo "backup FAILED: cannot write $FAILURE_MARKER" >&2
  return 1
}

backup_now() {
  ts=$(date +%Y%m%d-%H%M%S)
  tmp="/backups/.hrms-$ts"
  mkdir -p "$tmp" || { backup_failed "cannot create $tmp"; return 1; }

  pg_dump --format=custom --no-owner --file="$tmp/db.dump" || { backup_failed "pg_dump exited non-zero"; return 1; }
  [ -s "$tmp/db.dump" ] || { backup_failed "db.dump is empty"; return 1; }
  pg_restore --list "$tmp/db.dump" > /dev/null || { backup_failed "db.dump is not a readable archive"; return 1; }

  tar -C /storage -czf "$tmp/documents.tar.gz" . || { backup_failed "documents tar exited non-zero"; return 1; }
  files="db.dump documents.tar.gz"
  # Object data when the MinIO profile is in use; the mount is empty otherwise.
  if [ -d /minio ] && [ -n "$(ls -A /minio 2>/dev/null)" ]; then
    tar -C /minio -czf "$tmp/minio.tar.gz" . || { backup_failed "minio tar exited non-zero"; return 1; }
    files="$files minio.tar.gz"
  fi
  # shellcheck disable=SC2086 # $files is a fixed list of plain names, split on purpose
  (cd "$tmp" && sha256sum $files > SHA256SUMS) || { backup_failed "sha256sum exited non-zero"; return 1; }

  mv "$tmp" "/backups/hrms-$ts" || { backup_failed "cannot publish hrms-$ts"; return 1; }
  rm -f "$FAILURE_MARKER"
  date +%s > "$SUCCESS_MARKER" || { backup_failed "cannot write $SUCCESS_MARKER"; return 1; }
  echo "backup ok: hrms-$ts ($(du -sh "/backups/hrms-$ts" | cut -f1))"

  # Only after a verified, published set. Old failed temp dirs age out with the same retention.
  find /backups -maxdepth 1 -type d \( -name 'hrms-*' -o -name '.hrms-*' \) -mtime "+$BACKUP_KEEP_DAYS" -exec rm -rf {} + \
    || echo "warning: pruning old backups failed" >&2
}

check_health() {
  if [ -f "$FAILURE_MARKER" ]; then echo "last backup failed" >&2; return 1; fi
  [ -f "$SUCCESS_MARKER" ] || return 0
  age=$(( $(date +%s) - $(cat "$SUCCESS_MARKER") ))
  if [ "$age" -gt $(( BACKUP_MAX_AGE_HOURS * 3600 )) ]; then echo "last good backup is ${age}s old" >&2; return 1; fi
}

case "${1:-}" in
  --now)   backup_now; exit $? ;;
  --check) check_health; exit $? ;;
  "") ;;
  *) echo "usage: backup-loop.sh [--now|--check]" >&2; exit 2 ;;
esac

echo "backup scheduler: daily at $BACKUP_AT, keeping $BACKUP_KEEP_DAYS days"
last=""
while true; do
  today=$(date +%F)
  if [ "$(date +%H:%M)" = "$BACKUP_AT" ] && [ "$last" != "$today" ]; then
    backup_now || echo "backup FAILED: see the messages above; the next attempt is tomorrow at $BACKUP_AT, or run it now with bin/backup" >&2
    last=$today
  fi
  sleep 30
done
