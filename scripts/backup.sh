#!/usr/bin/env bash
# Logical backup of an HRMS database: custom-format pg_dump + SHA-256 checksum.
# Usage: scripts/backup.sh <database_url> <output_dir>
set -euo pipefail
URL=${1:?database url required}; OUT=${2:?output directory required}
mkdir -p "$OUT"
DB=$(python3 -c "import sys,urllib.parse as u;print(u.urlparse(sys.argv[1]).path.lstrip('/'))" "$URL")
FILE="$OUT/${DB}-$(date -u +%Y%m%dT%H%M%SZ).dump"
pg_dump --format=custom --no-owner --file="$FILE" "$URL"
shasum -a 256 "$FILE" > "$FILE.sha256"
echo "backup written: $FILE"
