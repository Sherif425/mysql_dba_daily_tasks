Here is a daily routine that works across many InnoDB Clusters, ordered by priority. The commands assume MySQL 8.0.22+ / 8.4 with MySQL Shell, and I haven't run them against your environments, so test them on a non-production cluster first.

## 0. One-time setup: an inventory and a loop

Keep one file listing every cluster, and store passwords in the MySQL Shell credential store (`shell.options.setPersist("credentialStore.savePasswords", "always")`) so scripts run without prompts.

```bash
# clusters.txt  ->  project_name   user@host:3306
#!/usr/bin/env bash
while read -r name uri; do
  [[ -z "$name" || "$name" == \#* ]] && continue
  echo "=== $name ==="
  mysqlsh --uri "$uri" --js --quiet-start=2 -e '
    var d = dba.getCluster().status().defaultReplicaSet;
    print(d.status + " | " + d.statusText + "\n");
    for (var m in d.topology) {
      var t = d.topology[m];
      print("  " + m + "  " + t.memberRole + "  " + t.status +
            "  lag=" + t.replicationLag + "\n");
    }' < /dev/null || echo "!! $name UNREACHABLE"
done < clusters.txt
```

Run this first every morning. Anything other than `OK` (for example `OK_NO_TOLERANCE` or `NO_QUORUM`) gets attention before the rest of the checklist.

## 1. Cluster and member health

```js
// mysqlsh, per cluster
var c = dba.getCluster();
c.status({extended: 1});      // members, roles, lag, instance errors
c.listRouters();              // routers registered and their last check-in
dba.getClusterSet().status({extended: 1});   // only if you use ClusterSet
```

```sql
SELECT MEMBER_HOST, MEMBER_PORT, MEMBER_STATE, MEMBER_ROLE, MEMBER_VERSION
FROM performance_schema.replication_group_members;
```

Every member should be `ONLINE`, with exactly one `PRIMARY` in single-primary mode.

## 2. Replication lag and applier errors

```sql
-- Queues building up = lag or flow control kicking in
SELECT m.MEMBER_HOST, m.MEMBER_ROLE, m.MEMBER_STATE,
       s.COUNT_TRANSACTIONS_IN_QUEUE                 AS cert_queue,
       s.COUNT_TRANSACTIONS_REMOTE_IN_APPLIER_QUEUE  AS applier_queue,
       s.COUNT_CONFLICTS_DETECTED                    AS conflicts
FROM performance_schema.replication_group_members m
JOIN performance_schema.replication_group_member_stats s USING (MEMBER_ID);

-- Applier errors
SELECT CHANNEL_NAME, WORKER_ID, LAST_ERROR_NUMBER, LAST_ERROR_MESSAGE, LAST_ERROR_TIMESTAMP
FROM performance_schema.replication_applier_status_by_worker
WHERE LAST_ERROR_NUMBER <> 0;
```

## 3. Error log review (last 24 hours)

```sql
SELECT LOGGED, PRIO, SUBSYSTEM, ERROR_CODE, LEFT(DATA, 200) AS msg
FROM performance_schema.error_log
WHERE LOGGED > NOW() - INTERVAL 1 DAY
  AND PRIO IN ('Error', 'Warning')
ORDER BY LOGGED DESC;
```

Look especially for members being expelled, view changes, and network timeouts between nodes.

## 4. Router check

```bash
# RW port should land on the primary, RO port on a secondary
mysql -h router-host -P 6446 -e "SELECT @@hostname, @@super_read_only;"
mysql -h router-host -P 6447 -e "SELECT @@hostname, @@super_read_only;"
systemctl is-active mysqlrouter
```

## 5. Long transactions and blocking

Large or long transactions are the most common cause of Group Replication trouble.

```sql
SELECT trx_mysql_thread_id, trx_started,
       TIMESTAMPDIFF(SECOND, trx_started, NOW()) AS secs,
       trx_rows_modified, LEFT(trx_query, 100) AS query
FROM information_schema.innodb_trx
WHERE trx_started < NOW() - INTERVAL 60 SECOND
ORDER BY trx_started;

SELECT * FROM sys.innodb_lock_waits\G
```

## 6. Backups

- Confirm last night's backup finished and has a sensible size.
- Take backups from a secondary, for example:

```bash
mysqlsh backup@secondary:3306 -- util dump-instance /backup/$(date +%F) --threads=8
```

- Do a test restore weekly, because a backup that has never been restored is unproven.

## 7. Disk and binary logs

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

## 8. Top queries

```sql
SELECT schema_name, LEFT(digest_text, 80) AS query, count_star,
       ROUND(sum_timer_wait/1e12, 1) AS total_s,
       ROUND(avg_timer_wait/1e9, 1)  AS avg_ms,
       sum_rows_examined
FROM performance_schema.events_statements_summary_by_digest
ORDER BY sum_timer_wait DESC LIMIT 10;
```

## 9. Group Replication compliance (daily or weekly)

```sql
-- Tables without a primary key break GR requirements
SELECT t.table_schema, t.table_name, t.engine
FROM information_schema.tables t
LEFT JOIN information_schema.table_constraints c
  ON c.table_schema = t.table_schema AND c.table_name = t.table_name
 AND c.constraint_type = 'PRIMARY KEY'
WHERE t.table_type = 'BASE TABLE'
  AND (c.constraint_name IS NULL OR t.engine <> 'InnoDB')
  AND t.table_schema NOT IN ('mysql','sys','performance_schema','information_schema');

-- Errant transactions: run on a secondary, paste the primary's gtid_executed
SELECT GTID_SUBTRACT(@@global.gtid_executed, '<primary_gtid_executed>');  -- should be empty
```

Setting `sql_require_primary_key = ON` prevents the first problem from recurring.

## Common fixes

| Situation | Command (mysqlsh) |
|---|---|
| Member shows `(MISSING)` | `c.rejoinInstance('user@host:3306')` |
| Member too far behind or corrupt | `c.removeInstance(...)`, then `c.addInstance(..., {recoveryMethod: 'clone'})` |
| Metadata out of sync with the group | `c.rescan()` |
| Planned primary switch (patching) | `c.setPrimaryInstance('host:3306')` |
| Lost quorum, some members alive | `c.forceQuorumUsingPartitionOf('host:3306')` |
| All members were down | `dba.rebootClusterFromCompleteOutage()` |

Would you like me to turn this into a runbook document, or expand the loop script into a full daily health report that emails or logs the results for all projects?