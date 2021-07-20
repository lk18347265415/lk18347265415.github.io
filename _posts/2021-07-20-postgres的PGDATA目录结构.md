---
layout:	post
title:	"postgres的PGDATA目录结构"
date:	2021-07-20 15:58:00 +0800
categories:	[postgres]
---

> postgres文件布局

在传统上，数据库集簇锁使用的配置文件和数据文件都被一起存储在集簇的数据目录里，通常用PGDATA来引用，不同数据库实例所管理的多个集簇可以在同一台机器上共享。集簇里的每个数据库，在PGDATA/base里都有一个子目录对应，子目录的名字为该数据库在pg_database里的OID。除了如下必要的目录和文件外，集簇的配置文件postgresql.conf、pg_hba.conf和pg_ident.conf通常都存储在PGDATA中，不过也可以放在别的地方。

<table border='1'>
<tr>
    <td>项</td>
    <td>描述</td>
</tr>
<tr>
    <td>PG_VERSION</td>
    <td>一个包含PostgreSQL主版本号的文件</td>
</tr>
<tr>
    <td>base</td>
    <td>包含每一个数据库对应的子目录的子目录</td>
</tr>
<tr>
    <td>global</td>
    <td>包含集簇范围表的子目录，比如pg_database</td>
</tr>
<tr>
    <td>pg_commit_ts</td>
    <td>包含事务提交时间戳数据的子目录</td>
</tr>
<tr>
    <td>pg_dynshmem</td>
    <td>包含被动态共享内存子系统所使用的文件的子目录</td>
</tr>
<tr>
    <td>pg_logical</td>
    <td>包含用于逻辑复制的状态数据的子目录</td>
</tr>
<tr>
    <td>pg_multixact</td>
    <td>包含多事务状态数据的子目录（用于共享的行锁）</td>
</tr>
<tr>
    <td>pg_notify</td>
    <td>包含LISTEN/NOTIFY状态数据的子目录</td>
</tr>
<tr>
    <td>pg_replslot</td>
    <td>包含复制槽数据的子目录</td>
</tr>
<tr>
    <td>pg_serial</td>
    <td>包含已提交的可序列化事务信息的子目录</td>
</tr>
<tr>
    <td>pg_snapshots</td>
    <td>包含导出的快照的子目录</td>
</tr>
<tr>
    <td>pg_stat</td>
    <td>包含用于统计子系统的永久文件的子目录</td>
</tr>
<tr>
    <td>pg_stat_tmp</td>
    <td>包含用于统计信息子系统的临时文件的子目录</td>
</tr>
<tr>
    <td>pg_subtrans</td>
    <td>包含子事务状态数据的子目录</td>
</tr>
<tr>
    <td>pg_tblspc</td>
    <td>包含指向表空间的符号链接的子目录</td>
</tr>
<tr>
    <td>pg_twophase</td>
    <td>包含用于预备事务状态文件的子目录</td>
</tr>
<tr>
    <td>pg_wal</td>
    <td>包含WAL(预写日志)文件的子目录</td>
</tr>
<tr>
    <td>pg_xact</td>
    <td>包含事务提交状态数据的子目录</td>
</tr>
<tr>
    <td>postgresql.auto.conf</td>
    <td>用于存储由ALTER SYSTEM设置的配置参数的文件</td>
</tr>
<tr>
    <td>postmaster.opts</td>
    <td>一个记录服务器最后一次启动使用的命令行参数的文件</td>
</tr>
<tr>
    <td>postmaster.pid</td>
    <td>一个锁文件，记录着当前postmaster进程ID，集簇数据目录路径、psotmaster启动时间戳、端口号、Unix域套接字目录路径第一个可用的listen_address以及共享内存段ID</td>
</tr>
<table>

> 总结

每个表和索引都存储在独立的文件里，对于普通的关系，这些文件以表或索引的filenode号（可在pg_class.relfilenode中找到  ）命名。对于临时关系，文件名的形式为tBBB_FFF,其中BBB是创建改文件的后台ID，FFF是文件节点号。空闲空间映射存储在一个文件中，该文件以节点号加上后缀 _fsm 命名。可见性映射关系存储在一个 后缀为_vm的文件中。