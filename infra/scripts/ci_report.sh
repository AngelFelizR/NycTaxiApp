#!/usr/bin/env bash
# Turn a test run's log into GitHub error annotations.
#
# Workflow job logs need admin rights to read through the API, so a red run is
# otherwise undiagnosable from outside the repository. Annotations are public:
# they show up in the check run and can be fetched with
#   GET /repos/{owner}/{repo}/check-runs/{id}/annotations
# The tail of the log also goes into the step summary, which is readable on
# the run page.
#
# Usage: ci_report.sh <log-file> [job-title]
set -u

log=${1:-}
title=${2:-tests}
[ -n "$log" ] && [ -f "$log" ] || exit 0

emit() {
  # Workflow commands escape %, \r and \n (docs: workflow-commands).
  local esc=${1//%/%25}
  esc=${esc//$'\r'/%0D}
  printf '::error title=%s::%s\n' "$title" "$esc"
}

# DIAG lines are emitted by the tests themselves for exactly this purpose --
# the job log is not readable from outside the repository, so a test that can
# fail for several reasons prints what it saw. Always reported, first.
# Not anchored: testthat's progress reporter can paste the message onto the
# end of the spinner line, so only the marker itself can be trusted.
grep -hE 'DIAG ' "$log" 2>/dev/null | while IFS= read -r line; do
  emit "$line"
done

# 1. testthat's own reporting first: every Failure/Error block, with enough
#    following lines to see what it was. The `── ` prefix only appears when
#    the reporter has a TTY to draw it on, so in CI the line is bare
#    "Failure ('file:line'): ..." -- both spellings are matched.
blocks=$(grep -A6 -E '^(── )?(Failure|Error) \(' "$log" 2>/dev/null)
if [ -n "$blocks" ]; then
  while IFS= read -r line; do
    case $line in
      # strip testthat's box-drawing prefix so the annotation reads as text
      "  "*) line=${line#"  "} ;;
      "── "*) line=${line#── } ;;
    esac
    [ -n "$line" ] && emit "$line"
  done <<< "$blocks"
  # and the summary line, which carries the counts, plus the 40 lines before
  # it -- if the block form was not printed, that is where the detail went.
  grep -E '^\[ FAIL [1-9]' "$log" | tail -1 | while IFS= read -r line; do
    emit "$line"
  done
  grep -B40 -E '^\[ FAIL [1-9]' "$log" | tail -45 | while IFS= read -r line; do
    emit "$line"
  done
else
  # 2. Nothing that looks like a test failure: the shell or the build died.
  matches=$(grep -E \
    '^\[ FAIL [1-9]|^Error( in)?: |^ERROR|^Execution halted|command not found|^error: ' \
    "$log" | head -30)
  if [ -z "$matches" ]; then
    matches=$(tail -20 "$log")
  fi
  while IFS= read -r line; do
    [ -n "$line" ] && emit "$line"
  done <<< "$matches"
fi

# Step summaries are public on the run page; this is the fallback for anything
# the annotations above could not express.
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    printf '### %s — last 60 lines\n\n```\n' "$title"
    tail -60 "$log"
    printf '```\n'
  } >> "$GITHUB_STEP_SUMMARY"
fi

exit 0
