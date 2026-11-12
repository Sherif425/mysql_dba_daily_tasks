#!/usr/bin/env bash
# ic_restore.sh - restore a full backup into an EMPTY standalone MySQL instance
# (a scratch server for restore tests and point-in-time recovery, or the first
# node of a cluster being rebuilt).
#
# Usage:   ./ic_restore.sh <backup_dir> <target_uri>
#   e.g.   ./ic_restore.sh /backup/full/billing/2026-11-12_0100 root@scratch-db:3306
# Env:     THREADS   load threads (default: 4)
#
# The restore refuses to run if the target is an ONLINE cluster member or
# already contains user schemas.

set -u -o pipefail

SRC="${1:?backup directory required}"
TARGET="${2:?target URI required}"
DIR="$(cd "$(dirname "$0")" && pwd)"
THREADS="${THREADS:-4}"

[[ -f "$SRC/@.done.json" ]] || { echo "[CRIT] $SRC is not a completed MySQL Shell dump" >&2; exit 2; }

echo "About to restore:"
echo "  backup : $SRC"
echo "  target : $TARGET"
read -r -p "Type the target host name to confirm: " answer
host="${TARGET#*@}"; host="${host%%:*}"
[[ "$answer" == "$host" ]] || { echo "Confirmation did not match, nothing done."; exit 1; }

start=$(date +%s)
if IC_RESTORE_SRC="$SRC" IC_RESTORE_THREADS="$THREADS" \
     mysqlsh --uri "$TARGET" --js --quiet-start=2 -f "$DIR/ic_restore.js"; then
  echo "[OK] restore finished in $(( $(date +%s) - start ))s"
else
  echo "[CRIT] restore failed" >&2
  exit 2
fi
