#!/usr/bin/env bash
# Disk and backup guard (master doc 8.1 and 8.5): hourly cron, logs the
# usage, and mails an alert through SMTP when something needs a human.
#
#   0 * * * * /srv/nyctaxi/nyctaxi/infra/scripts/disk_check.sh
#
# Two checks, one mail, one cooldown:
#   - disk usage >= DISK_THRESHOLD (8.1);
#   - no fresh dump. Nothing else notices when cron stops running: a missing
#     backup is invisible until someone needs one, which is the worst possible
#     moment to find out (8.5).
#
# No Prometheus/Grafana (ADR-013): this and health_check.sh and the external
# uptime monitor are the whole alerting surface. Cleaning up after a full disk
# is a runbook procedure (8.8), not something this script guesses at.
set -euo pipefail

THRESHOLD="${DISK_THRESHOLD:-80}"
MOUNT="${DISK_MOUNT:-/}"
BACKUP_DIR="${BACKUP_DIR:-/backups}"
# A daily job that did not run is caught on the second day.
BACKUP_MAX_AGE_H="${BACKUP_MAX_AGE_H:-25}"
LOG="${DISK_LOG:-/var/log/nyctaxi-disk.log}"
COOLDOWN_S="${DISK_ALERT_COOLDOWN:-21600}"   # 6 h
STAMP="${XDG_STATE_HOME:-/var/tmp}/nyctaxi-disk-alert"

# The default lives under /var/log because cron on the VM runs as root; on a
# workstation it is not writable. Failures must still reach stderr rather than
# kill the script under `set -e`.
logit() {
  { echo "$1" >>"$LOG"; } 2>/dev/null || echo "$1" >&2
}

problems=()
note_problem() { problems+=("$1"); }
# One line per problem reads better than space-joined prose.
SUMMARY() {
  local out="" p
  for p in "${problems[@]}"; do out+="${out:+; }${p}"; done
  echo "$out"
}

# ---------------------------------------------------------------- disk ----
USE="$(df -P "$MOUNT" | awk 'NR==2 {gsub("%","",$5); print $5}')"
AVAIL="$(df -P "$MOUNT" | awk 'NR==2 {print $4}')"
logit "$(date -Is) ${MOUNT} ${USE}% used, ${AVAIL}K available"

if (( USE >= THRESHOLD )); then
  note_problem "${MOUNT} is ${USE}% used (limit ${THRESHOLD}%), ${AVAIL}K free"
fi

# ------------------------------------------------------------- backups ----
if [[ -d "$BACKUP_DIR" ]]; then
  newest="$(find "$BACKUP_DIR" -name 'nyctaxi_*.dump' -printf '%T@\n' 2>/dev/null \
            | sort -rn | head -1 || true)"
  if [[ -z "$newest" ]]; then
    note_problem "no dump at all in $BACKUP_DIR"
  else
    age=$(( $(date +%s) - ${newest%.*} ))
    if (( age > BACKUP_MAX_AGE_H * 3600 )); then
      note_problem "newest dump is $(( age / 3600 ))h old (limit ${BACKUP_MAX_AGE_H}h) -- is cron running?"
    fi
  fi
fi

# -------------------------------------------------------------- outcome ----
LINE="$(date -Is)"
if (( ${#problems[@]} == 0 )); then
  logit "$LINE ok"
  # A green run clears the cooldown so the next incident alerts immediately.
  rm -f "$STAMP"
  exit 0
fi

logit "$LINE FAIL: $(SUMMARY)"

if [[ -f "$STAMP" ]] && (( $(date +%s) - $(stat -c %Y "$STAMP") < COOLDOWN_S )); then
  logit "$LINE (alert suppressed, inside cooldown)"
  exit 1
fi

: "${SMTP_URL:?Set SMTP_URL to alert on a full disk or a stale backup}"
: "${DISK_ALERT_TO:?Set DISK_ALERT_TO (recipient address)}"
MAIL_FROM="${DISK_ALERT_FROM:-alerts@nyctaxiapp.angelfeliz.com}"

# curl prepends -H headers to the upload WITHOUT a blank line, so the body
# looks like a continuation of the Subject header and the server answers
# "malformed header line" (451). The whole RFC822 message -- headers, empty
# line, body -- goes in the upload instead.
BODY="$(cat <<EOF
${LINE}

$(SUMMARY)

Runbook: docs/operations/runbook.md -> "Incident: disk full".
EOF
)"
MSG="$(printf 'From: %s\nTo: %s\nSubject: [nyctaxi] alert: %s\nContent-Type: text/plain; charset=utf-8\n\n%s' \
       "$MAIL_FROM" "$DISK_ALERT_TO" "$(SUMMARY)" "$BODY")"

if curl --silent --show-error --fail --max-time 30 \
      --url "$SMTP_URL" \
      --mail-from "$MAIL_FROM" \
      --mail-rcpt "$DISK_ALERT_TO" \
      --upload-file - <<<"$MSG"; then
  touch "$STAMP"
  logit "$LINE (alert sent)"
else
  logit "$LINE (mail FAILED)"
fi

exit 1
