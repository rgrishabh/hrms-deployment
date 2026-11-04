#!/usr/bin/env bash
# Behaviour test for backup-loop.sh, using stub pg_dump, pg_restore, tar and sleep on PATH.
# Runs without Docker or Postgres. The script's fixed container paths are rewritten into a temp dir.
#   dev/tests/backup-loop.test.sh [path/to/backup-loop.sh ...]
# With no arguments it tests both copies: dev/bin and environments/dev/bin.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
[ "$#" -gt 0 ] || set -- "$ROOT/dev/bin/backup-loop.sh" "$ROOT/environments/dev/bin/backup-loop.sh"
REAL_TAR=$(command -v tar)
pass=0; failed=0
ok()  { echo "  ok    $1"; pass=$((pass+1)); }
bad() { echo "  FAIL  $1"; failed=$((failed+1)); }
expect() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

# setup <script>: creates a sandbox with one expired set, one recent set and a stale temp dir.
setup() {
  T=$(mktemp -d)
  mkdir -p "$T/backups/hrms-old" "$T/backups/hrms-recent" "$T/backups/.hrms-stale" "$T/storage" "$T/stubs"
  echo doc > "$T/storage/doc.txt"
  touch -t 202001010000 "$T/backups/hrms-old" "$T/backups/.hrms-stale"
  sed -e "s#/backups#$T/backups#g" -e "s#/storage#$T/storage#g" -e "s#/minio#$T/minio#g" "$1" > "$T/script.sh"
  stub pg_dump    'f=""; for a in "$@"; do case "$a" in --file=*) f=${a#--file=} ;; esac; done; echo PGDMP > "$f"'
  stub pg_restore 'exit 0'
  stub tar        "exec $REAL_TAR \"\$@\""
  stub sleep      'kill "$PPID"; exit 0'
}
stub() { printf '#!/bin/sh\n%s\n' "$2" > "$T/stubs/$1"; chmod +x "$T/stubs/$1"; }
run()  { PATH="$T/stubs:$PATH" BACKUP_KEEP_DAYS=7 /bin/sh "$T/script.sh" "$@" > "$T/out" 2> "$T/err"; echo $? > "$T/rc"; }
rc()   { cat "$T/rc"; }
sets() { find "$T/backups" -maxdepth 1 -type d -name 'hrms-*' ! -name 'hrms-old' ! -name 'hrms-recent' | wc -l | tr -d ' '; }

# failure_case <label>: the assertions every failed backup must satisfy.
failure_case() {
  run --now
  expect "$1: exits non-zero"                 '[ "$(rc)" != 0 ]'
  expect "$1: does not print backup ok"       '! grep -q "backup ok" "$T/out" "$T/err"'
  expect "$1: reports FAILED on stderr"       'grep -q "FAILED" "$T/err"'
  expect "$1: publishes no new set"           '[ "$(sets)" = 0 ]'
  expect "$1: does not prune the expired set" '[ -d "$T/backups/hrms-old" ]'
  expect "$1: health check reports failure"   '! PATH="$T/stubs:$PATH" /bin/sh "$T/script.sh" --check >/dev/null 2>&1'
}

for script in "$@"; do
  echo "== $script"

  setup "$script"; stub pg_dump 'echo "pg_dump: connection refused" >&2; exit 1'
  failure_case "pg_dump fails"; rm -rf "$T"

  setup "$script"; stub pg_dump 'for a in "$@"; do case "$a" in --file=*) : > "${a#--file=}" ;; esac; done'
  failure_case "pg_dump writes an empty file"; rm -rf "$T"

  setup "$script"; stub pg_restore 'echo "pg_restore: not a valid archive" >&2; exit 1'
  failure_case "dump fails pg_restore --list"; rm -rf "$T"

  setup "$script"; stub tar 'exit 2'
  failure_case "documents tar fails"; rm -rf "$T"

  # The confirmed bug: in the scheduler path, `backup_now || echo` disables set -e inside backup_now.
  setup "$script"; stub pg_dump 'exit 1'
  PATH="$T/stubs:$PATH" BACKUP_KEEP_DAYS=7 BACKUP_AT="$(date +%H:%M)" /bin/sh "$T/script.sh" > "$T/out" 2> "$T/err"
  expect "scheduler: no backup ok after failed pg_dump" '! grep -q "backup ok" "$T/out" "$T/err"'
  expect "scheduler: logs FAILED"                       'grep -q "FAILED" "$T/err"'
  expect "scheduler: expired set is kept"               '[ -d "$T/backups/hrms-old" ]'
  expect "scheduler: no set without a dump"             '[ "$(sets)" = 0 ]'
  rm -rf "$T"

  setup "$script"; run --now
  set_dir=$(find "$T/backups" -maxdepth 1 -type d -name 'hrms-2*' | head -1)
  expect "success: exits zero"                  '[ "$(rc)" = 0 ]'
  expect "success: prints backup ok"            'grep -q "backup ok" "$T/out"'
  expect "success: set has db.dump"             '[ -s "$set_dir/db.dump" ]'
  expect "success: set has documents.tar.gz"    '[ -s "$set_dir/documents.tar.gz" ]'
  expect "success: checksums verify"            '(cd "$set_dir" && sha256sum -c SHA256SUMS >/dev/null 2>&1)'
  expect "success: prunes the expired set"      '[ ! -d "$T/backups/hrms-old" ]'
  expect "success: keeps the recent set"        '[ -d "$T/backups/hrms-recent" ]'
  expect "success: removes stale temp dirs"     '[ ! -d "$T/backups/.hrms-stale" ]'
  expect "success: health check passes"         'PATH="$T/stubs:$PATH" /bin/sh "$T/script.sh" --check >/dev/null 2>&1'

  # A later success clears an earlier failure.
  stub pg_dump 'exit 1'; run --now
  stub pg_dump 'f=""; for a in "$@"; do case "$a" in --file=*) f=${a#--file=} ;; esac; done; echo PGDMP > "$f"'; run --now
  expect "recovery: health check passes again"  'PATH="$T/stubs:$PATH" /bin/sh "$T/script.sh" --check >/dev/null 2>&1'
  rm -rf "$T"
done

echo "passed: $pass  failed: $failed"
[ "$failed" -eq 0 ]
