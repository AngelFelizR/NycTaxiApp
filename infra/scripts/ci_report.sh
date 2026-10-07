#!/usr/bin/env bash
# Turn a test run's log into GitHub error annotations.
#
# Workflow job logs need admin rights to read through the API, so a red run is
# otherwise undiagnosable from outside the repository. Annotations are public:
# they show up in the check run and can be fetched with
#   GET /repos/{owner}/{repo}/check-runs/{id}/annotations
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

# testthat's own vocabulary first; then anything that looks like a crash.
matches=$(grep -E \
  '^\[ FAIL [1-9]|^── (Failure|Error)|^Error( in)?: |^ERROR|^Execution halted|command not found|error: ' \
  "$log" | head -40)

if [ -z "$matches" ]; then
  # No test output to point at -- the shell or the build itself failed.
  matches=$(tail -20 "$log")
fi

while IFS= read -r line; do
  [ -n "$line" ] && emit "$line"
done <<< "$matches"

exit 0
