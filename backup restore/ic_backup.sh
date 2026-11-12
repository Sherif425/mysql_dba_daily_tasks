#!/usr/bin/env bash
# ic_backup.sh - nightly full backup of every InnoDB Cluster in the inventory.
#
# Usage:   ./ic_backup.sh [backup_targets.txt]
# Env:     BACKUP_ROOT      where backups are written      (default: /backup/full)
#          RETENTION_DAYS   delete backups older than this (default: 7)
#          THREADS          dump threads per cluster       (default: 4)
#          IC_ALLOW_PRIMARY set to 1 to allow backing up from a primary
#          MAIL_TO          address to mail the summary to (optional)
# Exit:    0 = every backup succeeded, 2 = at least one failed
#
# backup_targets.txt, one cluster per line, pointing at a SECONDARY:
#   project_name   backup@secondary-host:3306
# Passwords come from the MySQL Shell credential store.

set -u -o pipefail

INVENTORY="${1:-backup_targets.txt}"
DIR="$(cd "$(dirname "$0")" && pwd)"
BACKUP_ROOT="${BACKUP_ROOT:-/backup/full}"
RETENTION_DAYS="${RETENTION_DAYS:-7}"
THREADS="${THREADS:-4}"
MAIL_TO="${MAIL_TO:-}"
STAMP="$(date +%F_%H%M)"
LOG="$BACKUP_ROOT/ic_backup_$STAMP.log"

[[ -r "$INVENTORY" ]] || { echo "Inventory file not found: $INVENTORY" >&2; exit 2; }
mkdir -p "$BACKUP_ROOT"
failed=0

log() { echo "$(date '+%F %T') $*" | tee -a "$LOG"; }

while read -r name uri _; do
  [[ -z "$name" || "$name" == \#* ]] && continue
  dest="$BACKUP_ROOT/$name/$STAMP"
  mkdir -p "$BACKUP_ROOT/$name"
  log "[INFO] $name: starting backup from $uri"
  start=$(date +%s)

  IC_BACKUP_DEST="$dest" IC_BACKUP_THREADS="$THREADS" \
    mysqlsh --uri "$uri" --js --quiet-start=2 -f "$DIR/ic_backup.js" \
    < /dev/null >> "$LOG" 2>&1
  rc=$?

  # MySQL Shell writes @.done.json only when the dump completed.
  if [[ $rc -eq 0 && -f "$dest/@.done.json" ]]; then
    size=$(du -sh "$dest" | cut -f1)
    log "[OK] $name: backup complete, $size in $(( $(date +%s) - start ))s -> $dest"
    # Prune old backups only after a good one exists.
    find "$BACKUP_ROOT/$name" -mindepth 1 -maxdepth 1 -type d \
         -mtime +"$RETENTION_DAYS" ! -name '*.failed' -print -exec rm -rf {} + >> "$LOG" 2>&1
    # Offsite copy goes here, for example:
    #   rclone sync "$dest" "remote:mysql-backups/$name/$STAMP"
  else
    failed=$((failed + 1))
    [[ -d "$dest" ]] && mv "$dest" "$dest.failed"
    log "[CRIT] $name: backup FAILED (mysqlsh exit $rc), see $LOG"
  fi
done < "$INVENTORY"

log "[INFO] finished: $failed failed"

if [[ -n "$MAIL_TO" ]]; then
  grep -E '\[(OK|CRIT)\]' "$LOG" | mail -s "InnoDB Cluster backups: $failed failed" "$MAIL_TO"
fi

(( failed > 0 )) && exit 2
exit 0
