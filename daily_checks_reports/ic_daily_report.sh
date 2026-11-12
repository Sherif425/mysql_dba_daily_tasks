#!/usr/bin/env bash
# ic_daily_report.sh - daily health report across all MySQL InnoDB Clusters.
#
# Usage:   ./ic_daily_report.sh [clusters.txt]
# Env:     REPORT_DIR  where reports are kept   (default: ./reports)
#          MAIL_TO     address to mail the report to (optional, needs `mail`)
# Exit:    0 = all OK, 1 = warnings, 2 = critical findings
#
# clusters.txt format, one cluster per line:
#   project_name   user@host:3306
# Passwords come from the MySQL Shell credential store, so nothing is stored here.

set -u -o pipefail

INVENTORY="${1:-clusters.txt}"
DIR="$(cd "$(dirname "$0")" && pwd)"
REPORT_DIR="${REPORT_DIR:-$DIR/reports}"
MAIL_TO="${MAIL_TO:-}"
TIMEOUT_SECS=120

[[ -r "$INVENTORY" ]] || { echo "Inventory file not found: $INVENTORY" >&2; exit 2; }
mkdir -p "$REPORT_DIR"
REPORT="$REPORT_DIR/ic_report_$(date +%F).txt"
BODY="$(mktemp)"
trap 'rm -f "$BODY"' EXIT

while read -r name uri _; do
  [[ -z "$name" || "$name" == \#* ]] && continue
  {
    echo "===== $name ($uri) ====="
    # Prefix every result line with the project name so the summary is readable.
    if ! timeout "$TIMEOUT_SECS" mysqlsh --uri "$uri" --js --quiet-start=2 \
           -f "$DIR/ic_checks.js" < /dev/null 2>&1 |
         awk -v n="$name" '/^\[(OK|INFO|WARN|CRIT)\]/ { sub(/\]/, "] " n ":") } { print }'
    then
      echo "[CRIT] $name: could not connect or the checks did not finish"
    fi
    echo
  } >> "$BODY"
done < "$INVENTORY"

crit=$(grep -c '^\[CRIT\]' "$BODY" || true)
warn=$(grep -c '^\[WARN\]' "$BODY" || true)

{
  echo "InnoDB Cluster daily report - $(date '+%F %H:%M %Z')"
  echo "Critical: $crit   Warnings: $warn"
  echo
  if (( crit + warn > 0 )); then
    echo "----- Needs attention -----"
    grep -E '^\[(CRIT|WARN)\]' "$BODY"
    echo
  fi
  echo "----- Full detail -----"
  cat "$BODY"
} > "$REPORT"

cat "$REPORT"

if [[ -n "$MAIL_TO" ]]; then
  mail -s "InnoDB Cluster report: $crit critical, $warn warnings" "$MAIL_TO" < "$REPORT"
fi

(( crit > 0 )) && exit 2
(( warn > 0 )) && exit 1
exit 0
