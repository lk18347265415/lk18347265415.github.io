---
layout: post
title:  "pg_control文件解析"
date:   2021-09-16 11:06:00 +0700
categories: [postgres]
---

> pg_control文件

pg_control文件是*PGDATA/global*下一个8k大小的二进制文件，该文件记录了postgres的内部信息，比如：版本号、数据库集簇状态、最新检查点（checkpoint）、最新检查点时间、时间线和系统标识符等信息。该文件除了验证PG各种初始化信息外（信心与系统不符会报错误），最重要的是协助完成PITR功能（保存了检查点）。

> pg_control文件的生成

pg_control在initdb时（--boot模式下）生成：

```c
//创建pg_control，并写入信息
#define PG_CONTROL_FILE_SIZE		8192//pg_control文件的大小

InitControlFile(sysidentifier);
ControlFile->time = checkPoint.time;
ControlFile->checkPoint = checkPoint.redo;
ControlFile->checkPointCopy = checkPoint;
WriteControlFile();//将ControlFile信息写入pg_control文件

static void InitControlFile(uint64 sysidentifier)//sysidentifier为一个系统生成的标识符
{
    memset(ControlFile, 0, sizeof(ControlFileData));
	/* Initialize pg_control status fields */
	ControlFile->system_identifier = sysidentifier;
	memcpy(ControlFile->mock_authentication_nonce, mock_auth_nonce, MOCK_AUTH_NONCE_LEN);
	ControlFile->state = DB_SHUTDOWNED;
	ControlFile->unloggedLSN = FirstNormalUnloggedLSN;

	/* Set important parameter values for use when replaying WAL */
	ControlFile->MaxConnections = MaxConnections;
	ControlFile->max_worker_processes = max_worker_processes;
	ControlFile->max_wal_senders = max_wal_senders;
	ControlFile->max_prepared_xacts = max_prepared_xacts;
	ControlFile->max_prepared_foreign_xacts = max_prepared_foreign_xacts;
	ControlFile->max_locks_per_xact = max_locks_per_xact;
	ControlFile->wal_level = wal_level;
	ControlFile->wal_log_hints = wal_log_hints;
	ControlFile->track_commit_timestamp = track_commit_timestamp;
	ControlFile->enable_csn_snapshot = enable_csn_snapshot;
	ControlFile->data_checksum_version = bootstrap_data_checksum_version;
	ControlFile->xmin_for_csn = InvalidTransactionId;
}

static void WriteControlFile(void)
{
    //为了保持原子写和稳定性，确保ControlFileData的结构体不能大于512和8192
    StaticAssertStmt(sizeof(ControlFileData) <= PG_CONTROL_MAX_SAFE_SIZE,
					 "pg_control is too large for atomic disk writes");
	StaticAssertStmt(sizeof(ControlFileData) <= PG_CONTROL_FILE_SIZE,
					 "sizeof(ControlFileData) exceeds PG_CONTROL_FILE_SIZE");
    
	ControlFile->pg_control_version = PG_CONTROL_VERSION;
	ControlFile->catalog_version_no = CATALOG_VERSION_NO;

	ControlFile->maxAlign = MAXIMUM_ALIGNOF;
	ControlFile->floatFormat = FLOATFORMAT_VALUE;

	ControlFile->blcksz = BLCKSZ;
	ControlFile->relseg_size = RELSEG_SIZE;
	ControlFile->xlog_blcksz = XLOG_BLCKSZ;
	ControlFile->xlog_seg_size = wal_segment_size;

	ControlFile->nameDataLen = NAMEDATALEN;
	ControlFile->indexMaxKeys = INDEX_MAX_KEYS;

	ControlFile->toast_max_chunk_size = TOAST_MAX_CHUNK_SIZE;
	ControlFile->loblksize = LOBLKSIZE;

	ControlFile->float8ByVal = FLOAT8PASSBYVAL;

	/* Contents are protected with a CRC */
	INIT_CRC32C(ControlFile->crc);
	COMP_CRC32C(ControlFile->crc,
				(char *) ControlFile,
				offsetof(ControlFileData, crc));
	FIN_CRC32C(ControlFile->crc);
    
    //信息写入pg_control中
    memset(buffer, 0, PG_CONTROL_FILE_SIZE);
	memcpy(buffer, ControlFile, sizeof(ControlFileData));
    fd = BasicOpenFile(XLOG_CONTROL_FILE,O_RDWR | O_CREAT | O_EXCL | PG_BINARY);//二进制写
    if (fd < 0)
        ereport(PANIC,(errcode_for_file_access(),
                       errmsg("could not create file \"%s\": %m",XLOG_CONTROL_FILE)));
    errno = 0;
	pgstat_report_wait_start(WAIT_EVENT_CONTROL_FILE_WRITE);//保证原子写入
	if (write(fd, buffer, PG_CONTROL_FILE_SIZE) != PG_CONTROL_FILE_SIZE)
	{
		/* if write didn't set errno, assume problem is no disk space */
		if (errno == 0)
			errno = ENOSPC;
		ereport(PANIC,
				(errcode_for_file_access(),
				 errmsg("could not write to file \"%s\": %m",
						XLOG_CONTROL_FILE)));
	}
    pgstat_report_wait_end();
	pgstat_report_wait_start(WAIT_EVENT_CONTROL_FILE_SYNC);
    if (pg_fsync(fd) != 0)//将信息刷盘
        ereport(PANIC,(errcode_for_file_access(),
                  errmsg("could not fsync file \"%s\": %m",XLOG_CONTROL_FILE)));
    pgstat_report_wait_end();
    close(fd);
}

//pg_control结构体
typedef struct ControlFileData
{
	uint64		system_identifier;//系统生成唯一标识符，保证匹配xlog文件
    
	uint32		pg_control_version; //PG_CONTROL_VERSION
	uint32		catalog_version_no; //系统目录版本号

	DBState		state;			//System status data
	pg_time_t	time;			// 最后一次pg_control更新时间
	XLogRecPtr	checkPoint;		//最后一次checkpoint记录指针

	CheckPoint	checkPointCopy; //拷贝最后一次checkpoint记录

	XLogRecPtr	unloggedLSN;	/* current fake LSN value, for unlogged rels */

	/*
	 * 这两个值决定了我们在启动前必须恢复到的最低点：
	 *
	 * 每当我们在存档恢复期间刷新数据更改时，minRecoveryPoint 都会更新为最新重放的 LSN。
	 * 这可以防止启动存档恢复、中止并从较早的停止位置重新启动。 如果我们已经将 WAL记录 X 
	 * 中的数据更改刷新到磁盘，则在再次到达 X 之前不能启动。 不进行存档恢复时为零。
	 *
	 * backupStartPoint是备份开始检查点的重做指针, 如果我们正在从在线备份中恢复并且还
	 * 没有到达备份结束。 当到达备份结束时它被重置为零，并且在此之前我们不能启动。 否则，
	 * 布尔值就足够了，但是当我们看到备份结束记录时，我们使用重做指针作为交叉检查，以确保
     * 备份结束记录对应于我们正在从中恢复的基本备份.
	 *
	 * backupEndPoint是备份结束位置, 如果我们正在从备用的在线备份中恢复并且尚未到达备份
	 * 结束。 它被初始化为最后备份的 pg_control 中的最小恢复点。 当到达备份结束时它被重置
	 * 为零，并且在此之前我们不能启动。.
	 *
	 * 如果backupEndRequired为true,我们肯定知道我们正在从备份中恢复，并且在我们可以安全启
	 * 动之前必须看到备份结束记录.  如果它是false，但是设置了backupStartPoint，则在启动
	 * 时找到了一个 backup_label 文件，但它可能是一个从 pg_start_backup() 调用中遗留
	 * 下来的，没有伴随 pg_stop_backup()。 .
	 */
	XLogRecPtr	minRecoveryPoint;
	TimeLineID	minRecoveryPointTLI;
	XLogRecPtr	backupStartPoint;
	XLogRecPtr	backupEndPoint;
	bool		backupEndRequired;

	/*
	 * 决定 WAL 是否可用于归档或热备用的参数设置 
	 */
	int			wal_level;
	bool		wal_log_hints;
	int			MaxConnections;
	int			max_worker_processes;
	int			max_wal_senders;
	int			max_prepared_xacts;
	int			max_prepared_foreign_xacts;
	int			max_locks_per_xact;
	bool		track_commit_timestamp;
	bool		enable_csn_snapshot;

	/*
	 * 用于在数据库启动时记录一个 xmin 并带有一个snapshot-switch到 csn 快照，并保持该值直到它切换到 xid 快照.
	 */
	TransactionId xmin_for_csn;

	/*
	 * 此数据用于检查数据库和后端可执行文件的硬件架构兼容性。 我们不需要明确检查字节序，
	 * 因为 pg_control 版本对于不同字节序的机器肯定会出错，但我们确实需要担心 MAXALIGN 
	 * 和浮点格式。 （注意：存储布局名义上也取决于 SHORTALIGN 和 INTALIGN，但实际上这
	 * 些在所有感兴趣的架构上都是相同的。
	 *
	 * 仅测试一个 double 值对于浮点兼容性来说并不是非常可靠的测试，但它会捕获大多数情况。 
	 */
	uint32		maxAlign;		/* alignment requirement for tuples */
	double		floatFormat;	/* constant 1234567.0 */
#define FLOATFORMAT_VALUE	1234567.0

	/*
	 * 此数据用于确保此数据库的配置与后端可执行文件兼容.
	 */
	uint32		blcksz;			//数据库数据块大小
	uint32		relseg_size;	//每段大关系块数

	uint32		xlog_blcksz;	//WAL 文件中的块大小
	uint32		xlog_seg_size;	//每个 WAL 段的大小 

	uint32		nameDataLen;	//catalog名称字段宽度
	uint32		indexMaxKeys;	//索引中的最大列数 

	uint32		toast_max_chunk_size;	//TOAST 表中的块大小 
	uint32		loblksize;		//pg_largeobject 中的块大小 

	bool		float8ByVal;	// float8、int8 等按值传递？ 

	// 数据页是否受校验和保护？ 如果没有校验和版本则为零
	uint32		data_checksum_version;

	/*
	 * 随机随机数，用于需要基于集群唯一值进行的身份验证请求，例如在早期失败的 SASL 交换.
	 */
	char		mock_authentication_nonce[MOCK_AUTH_NONCE_LEN];

	//以上所有的CRC......必须是最后一个！
	pg_crc32c	crc;
} ControlFileData;
```

> 查看pg_control内容

```tex
[postgres@mypg01 bin]$ /opt/HGES1/bin/pg_controldata -D /opt/HGES1/data
pg_control version number:            1300
Catalog version number:               202006301
Database system identifier:           7000180976673032605
Database cluster state:               in production
pg_control last modified:             Thu 16 Sep 2021 01:55:55 PM CST
Latest checkpoint location:           0/29FF378
Latest checkpoint's REDO location:    0/29FF340
Latest checkpoint's REDO WAL file:    000000010000000000000002
Latest checkpoint's TimeLineID:       1
Latest checkpoint's PrevTimeLineID:   1
Latest checkpoint's full_page_writes: on
Latest checkpoint's NextXID:          0:1548
Latest checkpoint's NextOID:          18363
Latest checkpoint's NextMultiXactId:  1
Latest checkpoint's NextMultiOffset:  0
Latest checkpoint's oldestXID:        499
Latest checkpoint's oldestXID's DB:   1
Latest checkpoint's oldestActiveXID:  1548
Latest checkpoint's oldestMultiXid:   1
Latest checkpoint's oldestMulti's DB: 1
Latest checkpoint's oldestCommitTsXid:0
Latest checkpoint's newestCommitTsXid:0
Time of latest checkpoint:            Thu 16 Sep 2021 01:55:55 PM CST
Fake LSN counter for unlogged rels:   0/3E8
Minimum recovery ending location:     0/0
Min recovery ending loc's timeline:   0
Backup start location:                0/0
Backup end location:                  0/0
End-of-backup record required:        no
wal_level setting:                    replica
wal_log_hints setting:                off
max_connections setting:              100
max_worker_processes setting:         8
max_wal_senders setting:              10
max_prepared_xacts setting:           0
max_prepared_foreign_transactions setting:   0
max_locks_per_xact setting:           64
track_commit_timestamp setting:       off
enable_csn_snapshot setting:                off
Maximum data alignment:               8
Database block size:                  8192
Blocks per segment of large relation: 131072
WAL block size:                       8192
Bytes per WAL segment:                16777216
Maximum length of identifiers:        64
Maximum columns in an index:          32
Maximum size of a TOAST chunk:        1996
Size of a large-object chunk:         2048
Date/time type storage:               64-bit integers
Float8 argument passing:              by value
Data page checksum version:           0
Mock authentication nonce:            392d896baab8cff478aab2be71ffca319703e0745ae1948436f920db65ba8930
```

> 总结

pg_control文件初始完之后并不是不变的，而是经常更新，比如在恢复备份时，经常会使用并更新检查点和更新时间等信息，这一点会在日志重放时介绍。
