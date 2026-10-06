#!/usr/bin/env bash
# Daily Postgres backup (master doc 8.5). Cron at 03:00, four weeks of
# retention, no object storage.
#
#   0 3 * * * /srv/nyctaxi/nyctaxi/infra/scripts/backup.sh
#
# The dumps contain PII (waitlist emails, 9.1): /backups is mode 700 and a
# manual PII-erasure request has to remember that older copies expire after
# 28 days.
set -euo pipefail

BACKUP_DIR="${BACKUP_DIR:-/backups}"
CONTAINER="${POSTGRES_CONTAINER:-nyctaxi-postgres}"
USER_="${POSTGRES_USER:-nyctaxi}"
DB="${POSTGRES_DB:-nyctaxi}"
LOG="${BACKUP_LOG:-/var/log/nyctaxi-backup.log}"
KEEP_DAYS="${BACKUP_KEEP_DAYS:-28}"

FECHA="$(date +%Y%m%d_%H%M%S)"
ARCHIVO="${BACKUP_DIR}/nyctaxi_${FECHA}.dump"

umask 077
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  echo "$(date -Is) Backup FAILED: container $CONTAINER is not running" >>"$LOG"
  exit 1
fi

# -Fc gives a compressed custom format, which restore_test.sh can restore into
# a throwaway container without unpacking the whole dump first.
docker exec -i "$CONTAINER" pg_dump -Fc -U "$USER_" "$DB" >"$ARCHIVO"

if [[ ! -s "$ARCHIVO" ]]; then
  echo "$(date -Is) Backup FAILED: $ARCHIVO is empty" >>"$LOG"
  rm -f "$ARCHIVO"
  exit 1
fi

sha256sum "$ARCHIVO" >"${ARCHIVO}.sha256"

# Retention: the .dump and its .sha256 share the mtime, so one -mtime handles
# both. Anything under two weeks old is never touched.
find "$BACKUP_DIR" -name 'nyctaxi_*.dump*' -mtime "+${KEEP_DAYS}" -delete

echo "$(date -Is) Backup OK: $ARCHIVO ($(du -h "$ARCHIVO" | cut -f1))" >>"$LOG"
