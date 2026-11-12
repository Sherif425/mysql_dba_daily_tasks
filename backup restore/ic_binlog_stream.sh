#!/usr/bin/env bash
# ic_binlog_stream.sh - continuously copy binary logs from one cluster member,
# for point-in-time recovery. Run one instance per cluster, under systemd.
#
# Usage:   ./ic_binlog_stream.sh <login-path> <dest_dir>
#   login-path  created with:  mysql_config_editor set --login-path=billing \
#                                --host=billing-db2 --port=3306 --user=backup --password
#   dest_dir    for example /backup/binlog/billing
#
# On restart it resumes from the newest file already in dest_dir (that file is
# downloaded again, which is safe). If the source member is replaced, start a
# NEW dest_dir: binary log file names differ between members.

set -eu

LP="${1:?login-path required}"
DEST="${2:?destination directory required}"
mkdir -p "$DEST"

last="$(find "$DEST" -maxdepth 1 -type f -regex '.*\.[0-9][0-9][0-9][0-9][0-9][0-9]$' \
          -printf '%f\n' | sort | tail -n 1)"

if [[ -z "$last" ]]; then
  # First run: start from the oldest binary log still on the server.
  last="$(mysql --login-path="$LP" -N -e 'SHOW BINARY LOGS' | head -n 1 | cut -f 1)"
fi
[[ -n "$last" ]] || { echo "Could not determine a starting binary log" >&2; exit 1; }

echo "Streaming binary logs from login-path '$LP' starting at $last into $DEST"
exec mysqlbinlog --login-path="$LP" --read-from-remote-server --raw --stop-never \
     --result-file="$DEST/" "$last"
