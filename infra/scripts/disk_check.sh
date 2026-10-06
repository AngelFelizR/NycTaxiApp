#!/usr/bin/env bash
# Disk usage guard (master doc 8.1): hourly cron, logs the usage, and mails
# an alert through SMTP once the disk crosses the threshold.
#
#   0 * * * * /srv/nyctaxi/nyctaxi/infra/scripts/disk_check.sh
#
# No Prometheus/Grafana (ADR-013): this and the external uptime monitor are
# the whole alerting surface. Cleaning up is a runbook procedure (8.8), not
# something this script guesses at.
set -euo pipefail

THRESHOLD="${DISK_THRESHOLD:-80}"
MOUNT="${DISK_MOUNT:-/}"
LOG="${DISK_LOG:-/var/log/nyctaxi-disk.log}"
# Re-alert at most this often, so an hour-long incident does not produce 24
# identical mails.
COOLDOWN_S="${DISK_ALERT_COOLDOWN:-21600}"   # 6 h
STAMP="${XDG_STATE_HOME:-/var/tmp}/nyctaxi-disk-alert"

USE="$(df -P "$MOUNT" | awk 'NR==2 {gsub("%","",$5); print $5}')"
AVAIL="$(df -P "$MOUNT" | awk 'NR==2 {print $4}')"
LINE="$(date -Is) ${MOUNT} ${USE}% used, ${AVAIL}K available"
echo "$LINE" >>"$LOG"

if (( USE < THRESHOLD )); then
  # A green run clears the cooldown so the next incident alerts immediately.
  rm -f "$STAMP"
  exit 0
fi

if [[ -f "$STAMP" ]] && (( $(date +%s) - $(stat -c %Y "$STAMP") < COOLDOWN_S )); then
  echo "$LINE (alert suppressed, inside cooldown)" >>"$LOG"
  exit 0
fi

: "${SMTP_URL:?Set SMTP_URL to alert on a full disk}"
: "${DISK_ALERT_TO:?Set DISK_ALERT_TO (recipient address)}"
MAIL_FROM="${DISK_ALERT_FROM:-alerts@nyctaxiapp.angelfeliz.com}"

BODY="$(cat <<EOF
Disk alert on nyctaxiapp.angelfeliz.com

${LINE}
Threshold: ${THRESHOLD}%

Runbook: docs/operations/runbook.md -> "Incident: disk full".
EOF
)"

# curl speaks SMTP directly: MAIL FROM/RCPT TO come from the flags and stdin
# is the RFC822 message. No local MTA to install or keep alive.
if curl --silent --show-error --fail --max-time 30 \
      --url "$SMTP_URL" \
      --mail-from "$MAIL_FROM" \
      --mail-rcpt "$DISK_ALERT_TO" \
      --header "From: $MAIL_FROM" \
      --header "To: $DISK_ALERT_TO" \
      --header "Subject: [nyctaxi] disk ${USE}% on ${MOUNT}" \
      --header "Content-Type: text/plain; charset=utf-8" \
      --upload-file - <<<"$BODY"; then
  touch "$STAMP"
  echo "$LINE (alert sent)" >>"$LOG"
else
  echo "$LINE (mail FAILED)" >>"$LOG"
  exit 1
fi
