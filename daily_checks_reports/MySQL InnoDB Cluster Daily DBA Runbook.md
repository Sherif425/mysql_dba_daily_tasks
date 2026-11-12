# MySQL InnoDB Cluster Daily DBA Runbook

Nov 12, 2026 · @SHERIF MOHAMED

## Setup

Run the health report first each morning, then work through the checks below for any cluster it flags. Commands assume MySQL 8.0.22 or later (including 8.4) with MySQL Shell installed on the admin host.

Keep one inventory file listing every cluster, one line per project, pointing at any member:

```
# clusters.txt  ->  project_name   user@host:3306
billing     dba@billing-db1:3306
logistics   dba@logi-db1:3306
```

Store passwords in the MySQL Shell credential store so scripts run without prompts. Run this once in `mysqlsh`, then connect to each cluster once and accept the save:

```js
shell.options.setPersist("credentialStore.savePasswords", "always");
```

The scripts in this runbook have been syntax-checked but not run against a live cluster. Test them on a non-production cluster first.

## Daily health report script

One run checks every cluster in `clusters.txt` and writes a dated report with a "needs attention" summary at the top. It has two files, kept in the same directory: `ic_daily_report.sh` (the loop and report) and `ic_checks.js` (the checks, run inside MySQL Shell).

```bash
./ic_daily_report.sh /opt/dba/clusters.txt

# Mail it and keep reports elsewhere
MAIL_TO=dba-team@example.com REPORT_DIR=/var/log/ic_reports ./ic_daily_report.sh /opt/dba/clusters.txt

# cron: every day at 07:30
30 7 * * * /opt/dba/ic_daily_report.sh /opt/dba/clusters.txt >/dev/null 2>&1
```

The exit code is 0 when everything is healthy, 1 with warnings and 2 with critical findings, so a monitoring tool can alert on it.

| Check | Warning | Critical |
| --- | --- | --- |
| Cluster status | `OK_NO_TOLERANCE`, `OK_PARTIAL` | `NO_QUORUM`, `OFFLINE`, unreachable |
| Member status |  | Not `ONLINE`, or instance errors |
| Applier queue | More than 100 transactions |  |
| Applier errors |  | Any error |
| Error log, last 24 hours | Any `Error` entry |  |
| Open transactions | Older than 300 seconds |  |
| Connections | 80% of `max_connections` |  |
| Tables without a primary key or not InnoDB | Any |  |

Thresholds are variables at the top of `ic_checks.js`. The error log, applier error and binary log checks only cover the member named in `clusters.txt`, because those tables are local to each server.

Both files were sent in the chat alongside this runbook.

## Cluster and member health

Every member should be `ONLINE`, with exactly one `PRIMARY` in single-primary mode. Any cluster status other than `OK` gets attention before the rest of the checklist.

```js
// mysqlsh, connected to any member
var c = dba.getCluster();
c.status({extended: 1});      // members, roles, lag, instance errors
c.listRouters();              // registered routers and their last check-in
dba.getClusterSet().status({extended: 1});   // only if you use ClusterSet
```

```sql
SELECT MEMBER_HOST, MEMBER_PORT, MEMBER_STATE, MEMBER_ROLE, MEMBER_VERSION
FROM performance_schema.replication_group_members;
```

## Replication lag and applier errors

Growing queues mean a member is falling behind or flow control is throttling writes. Any applier error needs fixing the same day.

```sql
SELECT m.MEMBER_HOST, m.MEMBER_ROLE, m.MEMBER_STATE,
       s.COUNT_TRANSACTIONS_IN_QUEUE                 AS cert_queue,
       s.COUNT_TRANSACTIONS_REMOTE_IN_APPLIER_QUEUE  AS applier_queue,
       s.COUNT_CONFLICTS_DETECTED                    AS conflicts
FROM performance_schema.replication_group_members m
JOIN performance_schema.replication_group_member_stats s USING (MEMBER_ID);

SELECT CHANNEL_NAME, WORKER_ID, LAST_ERROR_NUMBER, LAST_ERROR_MESSAGE, LAST_ERROR_TIMESTAMP
FROM performance_schema.replication_applier_status_by_worker
WHERE LAST_ERROR_NUMBER <> 0;
```

## Error log review

Look for members being expelled, view changes and network timeouts between nodes. The table is local to each server, so run this on every member.

```sql
SELECT LOGGED, PRIO, SUBSYSTEM, ERROR_CODE, LEFT(DATA, 200) AS msg
FROM performance_schema.error_log
WHERE LOGGED > NOW() - INTERVAL 1 DAY
  AND PRIO IN ('Error', 'Warning')
ORDER BY LOGGED DESC;
```

## Router checks

The read-write port should land on the primary (`super_read_only = 0`) and the read-only port on a secondary (`super_read_only = 1`). Ports shown are the Router defaults.

```bash
mysql -h router-host -P 6446 -e "SELECT @@hostname, @@super_read_only;"
mysql -h router-host -P 6447 -e "SELECT @@hostname, @@super_read_only;"
systemctl is-active mysqlrouter
```

## Long transactions and blocking

Large or long-running transactions are the most common cause of Group Replication trouble. Chase the owner of anything open for more than a few minutes.

```sql
SELECT trx_mysql_thread_id, trx_started,
       TIMESTAMPDIFF(SECOND, trx_started, NOW()) AS secs,
       trx_rows_modified, LEFT(trx_query, 100) AS query
FROM information_schema.innodb_trx
WHERE trx_started < NOW() - INTERVAL 60 SECOND
ORDER BY trx_started;

SELECT * FROM sys.innodb_lock_waits\G
```

## Backups

Confirm every morning that last night's backup finished and its size is in line with previous days. Take backups from a secondary to keep load off the primary.

```bash
mysqlsh backup@secondary:3306 -- util dump-instance /backup/$(date +%F) --threads=8

# Quick check: yesterday's and today's backup sizes side by side
du -sh /backup/$(date -d yesterday +%F) /backup/$(date +%F)
```

- [ ] Backup completed for every cluster
- [ ] Size is consistent with the previous day
- [ ] Test restore done this week

A backup that has never been restored is unproven, so restore one cluster's backup to a scratch server each week.

## Disk and binary logs

A full data volume stops the member, so watch free space and how fast binary logs accumulate on every node.

```bash
df -h /var/lib/mysql
```

```sql
SHOW BINARY LOGS;
SELECT @@binlog_expire_logs_seconds;

SELECT table_schema,
       ROUND(SUM(data_length + index_length)/1024/1024/1024, 2) AS size_gb
FROM information_schema.tables
GROUP BY table_schema ORDER BY size_gb DESC;
```

## Top queries

The ten statements using the most total time since the last restart show where tuning pays off. A new entry near the top usually means a recent release or a missing index.

```sql
SELECT schema_name, LEFT(digest_text, 80) AS query, count_star,
       ROUND(sum_timer_wait/1e12, 1) AS total_s,
       ROUND(avg_timer_wait/1e9, 1)  AS avg_ms,
       sum_rows_examined
FROM performance_schema.events_statements_summary_by_digest
ORDER BY sum_timer_wait DESC LIMIT 10;
```

## Group Replication compliance

Every table needs a primary key and the InnoDB engine, and secondaries must hold no transactions the primary lacks. The health report checks the first daily; run the GTID comparison weekly.

```sql
-- Tables without a primary key or not InnoDB
SELECT t.table_schema, t.table_name, t.engine
FROM information_schema.tables t
LEFT JOIN information_schema.table_constraints c
  ON c.table_schema = t.table_schema AND c.table_name = t.table_name
 AND c.constraint_type = 'PRIMARY KEY'
WHERE t.table_type = 'BASE TABLE'
  AND (c.constraint_name IS NULL OR t.engine <> 'InnoDB')
  AND t.table_schema NOT IN ('mysql','sys','performance_schema','information_schema');

-- Errant transactions: run on a secondary, paste the primary's gtid_executed.
-- The result should be empty.
SELECT GTID_SUBTRACT(@@global.gtid_executed, '<primary_gtid_executed>');
```

Setting `sql_require_primary_key = ON` stops new tables without a primary key from being created.

## Common fixes

All commands run in `mysqlsh` after `var c = dba.getCluster();`. The last two are for outages only: confirm which members are really down before forcing quorum, because forcing it on the wrong partition can cause split-brain.

| Situation | Command |
| --- | --- |
| Member shows `(MISSING)` | `c.rejoinInstance('user@host:3306')` |
| Member too far behind or corrupt | `c.removeInstance('user@host:3306')`, then `c.addInstance('user@host:3306', {recoveryMethod: 'clone'})` |
| Metadata out of sync with the group | `c.rescan()` |
| Planned primary switch before patching | `c.setPrimaryInstance('host:3306')` |
| Lost quorum, some members still alive | `c.forceQuorumUsingPartitionOf('user@host:3306')` |
| All members were down | `dba.rebootClusterFromCompleteOutage()` |
