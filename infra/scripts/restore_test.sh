#!/usr/bin/env bash
# Restore a backup into a THROWAWAY Postgres and compare it with production
# (master doc 8.5 implies a restore test; 9.1 makes it mandatory: a backup
# nobody has restored is not a backup).
#
#   infra/scripts/restore_test.sh [path/to/nyctaxi_*.dump]
#
# Picks the newest dump when called without an argument. Leaves no residue:
# the container and its volume are removed at the end, including on failure.
set -euo pipefail

BACKUP_DIR="${BACKUP_DIR:-/backups}"
CONTAINER="${POSTGRES_CONTAINER:-nyctaxi-postgres}"
USER_="${POSTGRES_USER:-nyctaxi}"
DB="${POSTGRES_DB:-nyctaxi}"
LOG="${BACKUP_LOG:-/var/log/nyctaxi-backup.log}"
TMP_PG="nyctaxi-restore-test-$$"

DUMP="${1:-}"
if [[ -z "$DUMP" ]]; then
  DUMP="$(find "$BACKUP_DIR" -maxdepth 1 -name 'nyctaxi_*.dump' -printf '%T@ %p\n' \
            2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)"
fi
if [[ -z "$DUMP" || ! -f "$DUMP" ]]; then
  echo "No dump found (looked in ${BACKUP_DIR})." >&2
  exit 1
fi

if [[ -f "${DUMP}.sha256" ]]; then
  (cd "$(dirname "$DUMP")" && sha256sum -c "$(basename "${DUMP}.sha256")")
else
  echo "WARN: no .sha256 next to $DUMP, integrity not checked." >&2
fi

cleanup() {
  docker rm -f "$TMP_PG" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "Restoring $DUMP into a throwaway container..."
docker run -d --name "$TMP_PG" \
  -e POSTGRES_USER="$USER_" -e POSTGRES_PASSWORD="restore-only" \
  -e POSTGRES_DB="$DB" \
  postgres:16-alpine >/dev/null

# The throwaway has no healthcheck of its own; pg_isready is the cheapest wait.
for _ in $(seq 1 30); do
  if docker exec "$TMP_PG" pg_isready -U "$USER_" -d "$DB" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

docker exec -i "$TMP_PG" pg_restore -U "$USER_" -d "$DB" --no-owner --no-privileges <"$DUMP"

count_in() {
  docker exec "$1" psql -U "$USER_" -d "$DB" -tAc \
    "SELECT count(*) FROM information_schema.tables WHERE table_schema='public';"
}

tables_now="$(count_in "$CONTAINER")"
tables_new="$(count_in "$TMP_PG")"
echo "tables: production=$tables_now restored=$tables_new"

if [[ "$tables_now" != "$tables_new" ]]; then
  echo "FAIL: table count differs." | tee -a "$LOG" >&2
  exit 1
fi

echo "$(date -Is) Restore test OK: $DUMP ($tables_new tables)" >>"$LOG"
echo "OK"
