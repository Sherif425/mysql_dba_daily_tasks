# MySQL InnoDB Cluster Backup and Restore Runbook

Nov 12, 2026 · @SHERIF MOHAMED

## Backup plan

Each cluster gets a nightly full backup from a secondary plus continuous binary log copies, so any cluster can be restored to any second within the retention window. Group Replication protects against losing a server; only backups protect against a bad `DELETE`, a dropped table, or losing the whole site.

| Layer | Tool | Frequency | Retention | Protects against |
| --- | --- | --- | --- | --- |
| Full logical backup | MySQL Shell `util.dumpInstance()` | Nightly | 7 daily, 4 weekly | Data loss, corruption, human error |
| Binary logs | `mysqlbinlog --read-from-remote-server` | Continuous stream | Same as the oldest full backup | Loss of changes since the last full backup |
| Offsite copy | Object storage or a second site | After each nightly backup | 30 days | Loss of the backup server or the site |
| Restore test | `ic_restore.sh` on a scratch server | Weekly, one cluster in rotation | Keep the log | Backups that cannot be restored |
| Configuration | Copy of `my.cnf`, Router config, cluster topology | On change | Latest 5 | Slow rebuilds |

Retention figures are starting values. Two targets must be agreed per project before this plan is final:

- [ ] Recovery point objective: how much data loss is acceptable (with binary log streaming, normally seconds)
- [ ] Recovery time objective: how long a full restore may take (measure it in the weekly restore test)

## Prerequisites

Create one dedicated backup account per cluster, on the primary; it replicates to every member.

```sql
CREATE USER 'backup'@'10.0.0.%' IDENTIFIED BY '<strong password>';
GRANT SELECT, RELOAD, LOCK TABLES, PROCESS, EXECUTE, EVENT, TRIGGER, SHOW VIEW,
      REPLICATION CLIENT, REPLICATION SLAVE ON *.* TO 'backup'@'10.0.0.%';
GRANT BACKUP_ADMIN ON *.* TO 'backup'@'10.0.0.%';
```

`REPLICATION SLAVE` is only needed for binary log streaming. Replace `10.0.0.%` with the backup server's address.

On the backup server:

- MySQL Shell and the `mysql` client tools, at the same version as the clusters or newer
- Passwords saved in the MySQL Shell credential store (for the dump) and a login path per cluster (for binary log streaming)
- A separate volume for backups, sized for the retention window, with this layout:

```
/backup/full/<project>/<date_time>/     nightly full backups
/backup/binlog/<project>/               streamed binary logs
/opt/dba/                               scripts and inventory files
```

The inventory for backups names a secondary of each cluster:

```
# backup_targets.txt  ->  project_name   backup@secondary-host:3306
billing     backup@billing-db2:3306
logistics   backup@logi-db3:3306
```

## Daily full backup

`ic_backup.sh` takes a consistent, compressed full backup of every cluster in `backup_targets.txt`, then prunes backups older than the retention period. It refuses to back up from a primary or from a member that is not `ONLINE`.

```bash
./ic_backup.sh /opt/dba/backup_targets.txt

# Overrides
BACKUP_ROOT=/backup/full RETENTION_DAYS=7 THREADS=8 MAIL_TO=dba-team@example.com \
  ./ic_backup.sh /opt/dba/backup_targets.txt

# cron: every night at 01:00
0 1 * * * /opt/dba/ic_backup.sh /opt/dba/backup_targets.txt >/dev/null 2>&1
```

How it behaves:

- A backup counts as good only when MySQL Shell has written `@.done.json` in the backup directory.
- Old backups are deleted only after a good new one exists, so a run of failures never empties the backup volume.
- A failed backup directory is renamed with a `.failed` suffix and kept for diagnosis.
- The exit code is 0 when every backup succeeded and 2 when any failed.
- The cluster metadata schema is excluded, because `dba.createCluster()` recreates it on restore.

The script keeps daily backups only. For the weekly tier, copy each Sunday's backup to a separate directory or rely on the offsite copy's own retention; the offsite step is a commented line in the script to fill in with your storage tool.

## Continuous binary log backup

`ic_binlog_stream.sh` copies binary logs off one member as they are written, which is what makes recovery to a specific second possible. Run one instance per cluster as a systemd service so it restarts on its own.

Create a login path per cluster once, as the user the service runs as:

```bash
mysql_config_editor set --login-path=billing --host=billing-db2 --port=3306 --user=backup --password
```

```ini
# /etc/systemd/system/ic-binlog@.service
[Unit]
Description=Binary log streaming for InnoDB Cluster %i
After=network-online.target

[Service]
User=mysqlbackup
ExecStart=/opt/dba/ic_binlog_stream.sh %i /backup/binlog/%i
Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target
```

```bash
systemctl enable --now ic-binlog@billing
systemctl status ic-binlog@billing
```

Points to know:

- Binary log file names and positions differ between cluster members, while GTIDs are the same everywhere. Always recover by GTID or by time, never by file position.
- If the source member is replaced or rebuilt, point the login path at another member and stream into a new directory.
- Keep `binlog_expire_logs_seconds` on the servers at 3 days or more, so a streaming outage over a weekend loses nothing.
- Prune streamed files older than the oldest full backup you keep:

```bash
find /backup/binlog/billing -type f -mtime +8 -delete
```

## Large databases

Switch a cluster to physical backups when its logical restore no longer fits the recovery time objective; the weekly restore test tells you when. A physical backup copies the data files, so restore time is close to file-copy time instead of rebuilding every index.

| Tool | Licence | Notes |
| --- | --- | --- |
| MySQL Enterprise Backup (`mysqlbackup`) | MySQL Enterprise Edition | Supports incremental and compressed backups |
| Percona XtraBackup (`xtrabackup`) | Open source | Its version series must match the server (8.0 with 8.0, 8.4 with 8.4) |

XtraBackup outline, run on a secondary:

```bash
# Backup
xtrabackup --backup --user=backup --password='<password>' --target-dir=/backup/phys/billing/$(date +%F)

# Prepare (makes the files consistent; do it before storing or before restore)
xtrabackup --prepare --target-dir=/backup/phys/billing/2026-11-12

# Restore: MySQL stopped, data directory empty
xtrabackup --copy-back --target-dir=/backup/phys/billing/2026-11-12
chown -R mysql:mysql /var/lib/mysql
```

A physical backup includes the cluster metadata and Group Replication settings of the member it came from. Start the restored server with `group_replication_start_on_boot=OFF` so it does not try to rejoin a group on its own. Binary log streaming and the restore procedures below stay the same.

## Verification and restore tests

A backup is trusted only after it has been restored. Check the nightly run every morning and restore one cluster's backup to a scratch server every week, rotating through the projects.

Daily, a few minutes:

```bash
# Result of last night's run
grep -E '\[(OK|CRIT)\]' "$(ls -t /backup/full/ic_backup_*.log | head -n 1)"

# Size trend for one project: a sudden drop means missing data
du -sh /backup/full/billing/* | tail -n 5

# Binary log streaming is alive and current
systemctl is-active ic-binlog@billing
ls -lt /backup/binlog/billing | head -n 3
```

Weekly restore test:

1. Start an empty MySQL instance on the scratch server, same version as the cluster.
2. Restore the latest backup: `./ic_restore.sh /backup/full/billing/<date_time> root@scratch-db:3306`
3. Compare table counts and a few key row counts with production.
4. Replay an hour of binary logs using the command in Procedure B, to prove point-in-time recovery works.
5. Record the restore duration; it is the measured recovery time for that cluster.
6. Wipe the scratch instance.

- [ ] Nightly backup log reviewed
- [ ] Binary log streaming current for every cluster
- [ ] Offsite copy completed
- [ ] Weekly restore test done and duration recorded

## Which restore procedure to use

Most incidents do not need a backup at all: while one healthy member survives, rebuild the others from it. Use backups only when the data itself is wrong or every member is gone.

| Situation | Is the data on surviving members good? | Procedure |
| --- | --- | --- |
| One member crashed, is corrupt, or is too far behind | Yes | A: rebuild the member from the group |
| All members stopped (power loss, patching mistake) but their data is intact | Yes | `dba.rebootClusterFromCompleteOutage()`, no restore |
| Table dropped, bad `UPDATE` or `DELETE`, application bug damaged data | No, the mistake replicated everywhere | B: point-in-time recovery on a scratch server, then copy the data back |
| Every member lost or unrecoverable (site loss, storage failure, ransomware) | No | C: rebuild the cluster from backup |

Before any restore, write down the time the problem started and stop anything that could make it worse (application writes, scheduled jobs, backup pruning).

## Procedure A: rebuild one member

A failed member is rebuilt from the running group with the clone plugin, not from backup; clone copies a full snapshot from a healthy member and then catches up.

1. Confirm the cluster still has quorum and a primary: `dba.getCluster().status()`
2. Try the simple fix first, in case the member only dropped out:

   ```js
   var c = dba.getCluster();
   c.rejoinInstance('icadmin@db3:3306');
   ```
3. If it will not rejoin, or its data is damaged, remove it and add it back with clone:

   ```js
   c.removeInstance('icadmin@db3:3306', {force: true});
   c.addInstance('icadmin@db3:3306', {recoveryMethod: 'clone'});
   ```
4. If the server itself was replaced, install the same MySQL version and run `dba.configureInstance('root@db3:3306', {clusterAdmin: 'icadmin'})` before step 3.
5. Check that the member is `ONLINE` and its applier queue drains, using the daily health report.

Clone wipes the target member's data, so double-check the host name in `addInstance`. With only two members left the cluster has no fault tolerance; rebuild the third promptly.

## Procedure B: point-in-time recovery

Recover the data on a scratch server as it was just before the mistake, then copy only the affected tables back to the live cluster. The cluster stays online throughout and nothing is restored over production.

1. Find the exact moment. Search the streamed binary logs for the statement and note its time and the `GTID_NEXT` value just above it:

   ```bash
   mysqlbinlog --base64-output=decode-rows -vv /backup/binlog/billing/binlog.000412 \
     | grep -n -i -B 25 'DROP TABLE'
   ```

   A dropped table shows as the statement text; a bad `DELETE` shows as lines starting with `### DELETE FROM`.
2. Restore the last full backup taken before the mistake into an empty scratch instance:

   ```bash
   ./ic_restore.sh /backup/full/billing/2026-11-12_0100 root@scratch-db:3306
   ```
3. Replay binary logs up to just before the mistake. List every streamed file from the backup day onward; transactions already in the backup are skipped automatically by GTID.

   ```bash
   mysqlbinlog --stop-datetime="2026-11-12 14:29:00" \
     /backup/binlog/billing/binlog.000410 /backup/binlog/billing/binlog.000411 \
     /backup/binlog/billing/binlog.000412 \
     | mysql -h scratch-db -u root -p
   ```

   To keep everything except the one bad transaction, replace `--stop-datetime` with `--exclude-gtids='<group_uuid>:<number>'` using the GTID from step 1.
4. Check the recovered table on the scratch server (row counts, a few known records).
5. Export the affected tables from scratch and load them into a side schema on the primary:

   ```js
   // mysqlsh on scratch-db
   util.dumpTables('shop', ['orders'], '/tmp/orders_recovered');
   
   // mysqlsh on the cluster primary (needs local_infile = ON)
   util.loadDump('/tmp/orders_recovered', {schema: 'shop_recovered'});
   ```
6. Put the data back with the application owner, either by renaming the table into place or by inserting the missing rows:

   ```sql
   RENAME TABLE shop_recovered.orders TO shop.orders;          -- table was dropped
   INSERT INTO shop.orders SELECT * FROM shop_recovered.orders r
     WHERE NOT EXISTS (SELECT 1 FROM shop.orders o WHERE o.id = r.id);   -- rows were deleted
   ```
7. Take a fresh full backup and wipe the scratch instance.

`--stop-datetime` uses the time zone of the machine running `mysqlbinlog`; confirm it matches the time you noted.

## Procedure C: rebuild a whole cluster

Restore the backup into one fresh server, replay binary logs to the latest point, create a new cluster on it, then clone the other members from it. Use this only when no member has usable data; if any member's data survives, `dba.rebootClusterFromCompleteOutage()` is faster and loses nothing.

1. Keep applications off the database until step 8.
2. Install the same MySQL version on the first node and prepare it:

   ```js
   dba.configureInstance('root@db1:3306', {clusterAdmin: 'icadmin'});
   ```
3. Restore the latest full backup into it:

   ```bash
   ./ic_restore.sh /backup/full/billing/2026-11-12_0100 root@db1:3306
   ```
4. Replay all streamed binary logs from the backup day onward, to recover changes made after the backup:

   ```bash
   mysqlbinlog /backup/binlog/billing/binlog.0004* | mysql -h db1 -u root -p
   ```
5. If the restore brought the old cluster metadata with it (physical backups do), remove it, then create the new cluster:

   ```js
   dba.dropMetadataSchema({force: true});      // only if the old metadata exists
   var c = dba.createCluster('billing');
   ```
6. Add the other members; clone copies the data from the first node:

   ```js
   c.addInstance('icadmin@db2:3306', {recoveryMethod: 'clone'});
   c.addInstance('icadmin@db3:3306', {recoveryMethod: 'clone'});
   c.status();
   ```
7. Bootstrap each Router again, because the cluster metadata is new, then restart it:

   ```bash
   mysqlrouter --bootstrap icadmin@db1:3306 --user=mysqlrouter --force
   systemctl restart mysqlrouter
   ```
8. Validate with the application owner, then reopen access.
9. Take a full backup immediately and restart binary log streaming into a new directory, since the rebuilt servers start a new binary log sequence.

Rehearse this procedure once per project on test servers; the first run always surfaces missing accounts, firewall rules or configuration that a real outage is the wrong time to discover.

## Script reference

The five files were sent in the chat alongside this runbook. Keep them together in `/opt/dba/`; each `.sh` file calls the `.js` file of the same name. All have been syntax-checked but not run against a live cluster, so run each one on a test cluster before scheduling it.

| File | Purpose | Runs |
| --- | --- | --- |
| `ic_backup.sh` | Loops over `backup_targets.txt`, backs up each cluster, prunes old backups, reports failures | Nightly from cron |
| `ic_backup.js` | Checks the member is an `ONLINE` secondary, then runs `util.dumpInstance()` | Called by `ic_backup.sh` |
| `ic_binlog_stream.sh` | Streams binary logs from one member and resumes where it stopped | Continuously under systemd |
| `ic_restore.sh` | Asks for confirmation, then restores a backup into an empty instance | On demand and in the weekly test |
| `ic_restore.js` | Refuses live cluster members and non-empty targets, then runs `util.loadDump()` | Called by `ic_restore.sh` |
