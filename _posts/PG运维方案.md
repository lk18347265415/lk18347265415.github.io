# PG运维方案
## 制定运维整体方案
制定完善运维整体方案，包括运维环境监控、日常数据库管理、数据库备份与恢复、性能监控、性能调优。

1、**运维环境监控**：包括CPU是否过高、IO是否过忙、网络监控（网络流量是否过大）、磁盘空间监控、数据库年龄监控（如果数据年龄超了，数据库会停止工作）、表和物化视图上索引的数量、数据库级的统计信息。

2、**日常数据库管理**：包括实例状态检查、PG监听是否正常、WAL日志检查（是否出现爆增还爆减）、表空间检查、日志检查（是否报错）、备份有效性检查的方法。

3、**数据库备份与恢复**：包括备份策略设定、物理备份、逻辑备份（库表小做逻辑备份）、备份脚本、恢复脚本或恢复操作过程、如何防止误删除（是否架建延持备库）。

4、**性能监控**：包括检查等待事件、磁盘IO监控、TOP 10 SQL、数据库的每秒查询的行、插入的行、删除的行、更新的行。

5、**性能调优**：包括OS层面优化、PG参数优化、SQL优化、IO优化、架构优化：如读写分离、分库分表。

## 运维工作

- 表、索引、物化视图、数据库、表空间的大小，表空间剩余可用空间；
- 数据库年龄、表的年龄；
- 表，物化视图的索引数量；
- 索引扫描次数；
- 表、物化视图、索引膨胀字节数，膨胀比例；
- Deadtuple；
- 序列剩余次数；
- HA，备份，归档，备库延迟状态；
- 错误日志统计；
- 事件触发器、触发器的情况；
- Unlogged table的情况，如果是9.X版本之前，了解Hash Index情况；
- 锁等待；
- 活跃度，Active, Idle, Idle in transaction状态会话数，剩余可用连接数；
- 带事务号的长事务，2PC事务；
- 网卡利用率，CPU利用率，IO利用率，内存利用率；
- 慢SQL及当时的Analyze执行计划；
- TOP SQL；
- 数据库级别统计信息：回滚数，提交数，命中率，死锁次数，IO TIME，Tuple DML次数。

1、 表、索引、物化视图、数据库、表空间的大小，表空间剩余可用空间；

	表、索引大小
	select schemaname, tablename, 
	pg_size_pretty(pg_table_size(schemaname||'.'||tablename)) as table_size, 
	pg_size_pretty(pg_indexes_size(schemaname||'.'||tablename)) as index_size, 
	pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) as total_size
	from pg_tables 
	order by pg_total_relation_size(schemaname||'.'||tablename) desc;	
	
	SELECT schemaname||'.'||relname as '表名', n_dead_tup as '死元组数', n_live_tup as '',        pg_size_pretty(pg_relation_size(schemaname||'.'||relname)) as table_size, round(n_dead_tup * 100 / (n_live_tup + n_dead_tup),2) AS dead_tup_ratio FROM pg_stat_all_tables WHERE n_dead_tup >= 1000 ORDER BY dead_tup_ratio DESC limit 10;


​	
	视图大小
	select schemaname, viewname, 
	pg_size_pretty(pg_total_relation_size(schemaname||'.'||viewname)) as view_size 
	from pg_views 
	order by pg_total_relation_size(schemaname||'.'||viewname) desc;
	
	数据库大小
	select datname,
	pg_size_pretty(pg_database_size(datname)) as db_size
	from pg_database
	order by pg_database_size(datname) desc;
	
	表空间的大小
	select spcname, pg_size_pretty(pg_tablespace_size(spcname)) as tablespace_size
	from pg_tablespace
	order by pg_tablespace_size(spcname) desc;


2、 数据库年龄、表的年龄；

	查询库xid
	SELECT datname, age(datfrozenxid) FROM pg_database;
	
	查询每个表的xid使用程度
	select oid::regclass as table_name, age(relfrozenxid) as age, relkind 
	from pg_class 
	where relkind IN ('r', 'm') 
	order by age desc;

3、 表，物化视图的索引数量；

	select * from pg_indexes;

4、 索引扫描次数；

	select relname, indexrelname, idx_scan, idx_tup_read, idx_tup_fetch from pg_stat_user_indexes order by idx_scan asc, idx_tup_read asc, idx_tup_fetch asc;

5、冗余索引

```
with index_data as (
  select
    *,
    indkey::text as columns,
    array_to_string(indclass, ', ') as opclasses
  from pg_index
), redundant as (
  select
    tnsp.nspname AS schema_name,
    trel.relname AS table_name,
    irel.relname AS index_name,
    am1.amname as access_method,
    format('redundant to index: %I', i1.indexrelid::regclass)::text as reason,
    pg_get_indexdef(i1.indexrelid) main_index_def,
    pg_size_pretty(pg_relation_size(i1.indexrelid)) main_index_size,
    pg_get_indexdef(i2.indexrelid) index_def,
    pg_size_pretty(pg_relation_size(i2.indexrelid)) index_size,
    s.idx_scan as index_usage
  from
    index_data as i1
    join index_data as i2 on (
        i1.indrelid = i2.indrelid /* same table */
        and i1.indexrelid <> i2.indexrelid /* NOT same index */
    )
    inner join pg_opclass op1 on i1.indclass[0] = op1.oid
    inner join pg_opclass op2 on i2.indclass[0] = op2.oid
    inner join pg_am am1 on op1.opcmethod = am1.oid
    inner join pg_am am2 on op2.opcmethod = am2.oid
    join pg_stat_user_indexes as s on s.indexrelid = i2.indexrelid
    join pg_class as trel on trel.oid = i2.indrelid
    join pg_namespace as tnsp on trel.relnamespace = tnsp.oid
    join pg_class as irel on irel.oid = i2.indexrelid
  where
    not i1.indisprimary -- index 1 is not primary
    and not ( -- skip if index1 is (primary or uniq) and is NOT (primary and uniq)
        (i1.indisprimary or i1.indisunique)
        and (not i2.indisprimary or not i2.indisunique)
    )
    and  am1.amname = am2.amname -- same access type
    and (
      i2.columns like (i1.columns || '%') -- index 2 includes all columns from index 1
      or i1.columns = i2.columns -- index1 and index 2 includes same columns
    )
    and (
      i2.opclasses like (i1.opclasses || '%')
      or i1.opclasses = i2.opclasses
    )
    -- index expressions is same
    and pg_get_expr(i1.indexprs, i1.indrelid) is not distinct from pg_get_expr(i2.indexprs, i2.indrelid)
    -- index predicates is same
    and pg_get_expr(i1.indpred, i1.indrelid) is not distinct from pg_get_expr(i2.indpred, i2.indrelid)
)
select * from redundant;
```

6、 表、物化视图、索引膨胀字节数，膨胀比例；

	SELECT schemaname||'.'||relname as table_name,
	pg_size_pretty(pg_relation_size(schemaname||'.'||relname)) as table_size,
	n_dead_tup, n_live_tup, round(n_dead_tup * 100 / (n_live_tup + n_dead_tup),2) AS dead_tup_ratio
	FROM pg_stat_all_tables
	WHERE n_dead_tup >= 1000
	ORDER BY dead_tup_ratio DESC
	LIMIT 10;

7、 序列剩余次数；

	select seqrelid::regclass as seq_name, currval(seqrelid::regclass) as seq_cur, seqmax as seq_max, (seqmax - currval(seqrelid::regclass)) as seq_left from pg_sequence order by seq_left;

8、 复制状态检查；

	主备角色检查
	select pg_is_in_recovery();    --f:主库  t:从库
	
	主库wal buffer的插入位置 和 wal文件的写入位置(主库上执行)
	select pg_current_wal_insert_lsn(),pg_current_wal_lsn();
	
	从库的receive和replay位置(从库上执行)
	select pg_last_wal_replay_lsn(),pg_last_wal_receive_lsn();
	
	主从延迟
	pg_wal_lsn_diff(pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn())

9、 活跃度，Active, Idle, Idle in transaction状态会话数，剩余可用连接数；

	show max_connections;
	
	select count(pid) as total_connections, 
	count(case when state = 'active' then pid else null end) active_connections,
	count(case when state = 'idle' then pid else null end) idle_connections,
	count(case when state = 'idle in transaction' then pid else null end) idleintrx_connections
	from pg_stat_activity;

10、带事务号的长事务，2PC事务；

	长事务
	select datname,usename,query,xact_start,now()-xact_start xact_duration,query_start,now()-query_start query_duration,state 
	from pg_stat_activity 
	where state <> 'idle' 
	and (backend_xid is not null or backend_xmin is not null) and now()-xact_start > 	interval'30 min'
	order by xact_start;
	
	2PC事务
	select name,statement,prepare_time,now()-prepare_time,parameter_types,from_sql 
	from pg_prepared_statements where now()-prepare_time > interval '30 min'
	order by prepare_time;