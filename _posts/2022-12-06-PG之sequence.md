---
layout: post
title:  "PG之sequence"
date:   2022-12-06 11:06:00 +0700
categories: [postgres]
---

[TOC]

## 序列的创建

### 序列创建过程

CREATE SEQUENCE会创建一个和序列名同名的表，用于记录序列的实时信息，并插入一行序列初始信息。同时会将序列的基本信息，如（序列对象oid、最大最小值、起始值、增长间隙、cache值等）存入pg_sequence系统表中。

```text
序列表字段信息:
	last_value    |   log_cnt   |   is_called
其中：
	last_value:保存序列的当前值，初始值为seqstart
	log_cnt:#define SEQ_LOG_VALS  32,序列状态的改变需要记录在wal日志中，这可能导致性能受损，32个序列值可能在崩溃期间丢失（恢复将序列设置为记录位置），log_cnt显示在写入新WAL记录之前还有多少次回迁，在检查点后第一次调用nextval后，log_cnt将为32.每次调用nextval时，log_cnt将减小，一旦达到0，log_cnt将再次设置为32，并写入WAL记录
	is_called:布尔值，false直接返回last_value，true推进序列返回，初始值为false


序列基础信息：pg_sequence
	seqrelid  |  seqtypeid  | seqstart  |  seqincrement  |  seqmax  | seqmin  |  seqcache  |  seqcycle
其中：
	seqrelid:序列表对象oid
	seqtypeid:序列类型
	
```

### 创建序列代码实现

```c
ObjectAddress
DefineSequence(ParseState *pstate, CreateSeqStmt *seq)
{
    //从seq->option中获取序列基础信息
    init_params(pstate, seq->options, seq->for_identity, true, seq->seq_type,
				&seqform, &seqdataform,
				&need_seq_rewrite, &owned_by);
    //创建序列，并填充初始值
    for (i = SEQ_COL_FIRSTCOL; i <= SEQ_COL_LASTCOL; i++)
	{//组装序列的列信息
        ColumnDef  *coldef = makeNode(ColumnDef);
        null[i - 1] = false;
        switch (i)
		{
			case SEQ_COL_LASTVAL:
				coldef->typeName = makeTypeNameFromOid(INT8OID, -1);
				coldef->colname = "last_value";
				value[i - 1] = Int64GetDatumFast(seqdataform.last_value);
				break;
			case SEQ_COL_LOG:
				coldef->typeName = makeTypeNameFromOid(INT8OID, -1);
				coldef->colname = "log_cnt";
				value[i - 1] = Int64GetDatum((int64) 0);
				break;
			case SEQ_COL_CALLED:
				coldef->typeName = makeTypeNameFromOid(BOOLOID, -1);
				coldef->colname = "is_called";
				value[i - 1] = BoolGetDatum(false);
				break;
		}
		stmt->tableElts = lappend(stmt->tableElts, coldef);
    }
    //创建具体序列，并生成存储文件
    address = DefineRelation(stmt, RELKIND_SEQUENCE, seq->ownerId, NULL, NULL);
    //向序列表中填入初始值
    tuple = heap_form_tuple(tupDesc, value, null);
	fill_seq_with_data(rel, tuple);
    
    //向pg_sequence中插入基础信息
    rel = table_open(SequenceRelationId, RowExclusiveLock);
	tupDesc = RelationGetDescr(rel);

	memset(pgs_nulls, 0, sizeof(pgs_nulls));

	pgs_values[Anum_pg_sequence_seqrelid - 1] = ObjectIdGetDatum(seqoid);
	pgs_values[Anum_pg_sequence_seqtypid - 1] = ObjectIdGetDatum(seqform.seqtypid);
	pgs_values[Anum_pg_sequence_seqstart - 1] = Int64GetDatumFast(seqform.seqstart);
	pgs_values[Anum_pg_sequence_seqincrement - 1] = Int64GetDatumFast(seqform.seqincrement);
	pgs_values[Anum_pg_sequence_seqmax - 1] = Int64GetDatumFast(seqform.seqmax);
	pgs_values[Anum_pg_sequence_seqmin - 1] = Int64GetDatumFast(seqform.seqmin);
	pgs_values[Anum_pg_sequence_seqcache - 1] = Int64GetDatumFast(seqform.seqcache);
	pgs_values[Anum_pg_sequence_seqcycle - 1] = BoolGetDatum(seqform.seqcycle);

	tuple = heap_form_tuple(tupDesc, pgs_values, pgs_nulls);
	CatalogTupleInsert(rel, tuple);
    return address;
}
```



## 序列引用

### 引用方法

PG中使用nextval函数推进序列到下一个值并返回该值。使用currval函数或者当前序列最近获取的值（如果在这个会话中没有调用过nextval函数，则调用currval会报告错误）

```sql
CREATE SEQUENCE seq;
select nextval('seq');//获取seq序列的下一个值
select currval('seq');//或者seq序列的当前值
```

### nextval代码实现

```c
int64
nextval_internal(Oid relid, bool check_permissions)
{
    int64	rescnt = 0;//获取了几次值
    int64	last;//用于记录缓存后的最大值
    int64	next;//用于记录在wal中的序列值
    bool	logit = false;
    //获取或初始化序列hash表数据
    init_sequence(relid, &elm, &seqrel);
    PreventCommandIfParallelMode("nextval()");	//禁止在并行状态使用nextval
    if (elm->last != elm->cached)	//表示是否有些数值被cache了，last是cache序列后的最大值
    {//返回cache的值
        elm->last += elm->increment;
		relation_close(seqrel, NoLock);
		last_used_seq = elm;
		return elm->last;
    }
    //从pg_sequence中获取序列基础信息
    pgstuple = SearchSysCache1(SEQRELID, ObjectIdGetDatum(relid));
    pgsform = (Form_pg_sequence) GETSTRUCT(pgstuple);
	incby = pgsform->seqincrement;
	maxv = pgsform->seqmax;
	minv = pgsform->seqmin;
	cache = pgsform->seqcache;
	cycle = pgsform->seqcycle;

    //读取序列表中数据信息
    seq = read_seq_tuple(seqrel, &buf, &seqdatatuple);
	page = BufferGetPage(buf);
    elm->increment = incby;
	last = next = result = seq->last_value;
	fetch = cache;
	log = seq->log_cnt;

    if (!seq->is_called)
	{//如果is_called为false，那么last_value不能直接使用
		rescnt++;
		fetch--;
	}

    /*决定是否需要将序列计入wal日志，如果需要，则我们要+SEQ_LOG_VALS更多缓存值。如果是checkpoint后
     *第一次执行nextval，我们也要记录wal日志，否则从检查点开始的重放将无法使序列前进超过记录的值。在这种
     *情况下，我们不妨获取额外的值
     */
    if (log < fetch || !seq->is_called)
	{/* forced log to satisfy local demand for values */
		fetch = log = fetch + SEQ_LOG_VALS;
		logit = true;
	}
	else
	{
		XLogRecPtr	redoptr = GetRedoRecPtr();//获取当前共享内存Redo指针
		if (PageGetLSN(page) <= redoptr)
		{/* last update of seq was before checkpoint */
			fetch = log = fetch + SEQ_LOG_VALS;
			logit = true;
		}
	}

    /*
     * 循环获取next和last的值，next用于记录于wal中，last的值用于缓存到的值(last_value+cache*incby)
     */
    while (fetch)
    {
        if (incby > 0)
        {//升序
            if ((maxv >= 0 && next > maxv - incby) ||
				(maxv < 0 && next + incby > maxv))
			{//推进的序列值超过了序列最大值
				if (rescnt > 0)
					break;		/* stop fetching */
				if (!cycle)//达到最大值且序列不是循环的，则报错
					elog("nextval: reached maximum value of sequence");	
				next = minv;
            }else{
                next += incby;
            }
        }else{//降序
            if ((minv < 0 && next < minv - incby) ||
				(minv >= 0 && next + incby < minv))
            {//降序达到了最小值
                if (rescnt > 0)
					break;		/* stop fetching */
				if (!cycle)//达到序列最小值且不是循环的
					elog("nextval: reached minimum value of sequence");
				next = maxv;
            }else{
                next += incby;
            }
        }
        fetch--;
        if (rescnt < cache)
		{
			log--;
			rescnt++;
			last = next;
			if (rescnt == 1)	/* 如果这是第一个结果 */
				result = next;	/*要返回的最终值*/
		}
    }

    log -= fetch;//调整记录于序列表中的log数
    //保存本地cache的序列信息
    elm->last = result;
    elm->cached = last;
    elm->last_valid = true;
	last_used_seq = elm;

    if (logit && RelationNeedsWAL(seqrel))
		GetTopTransactionId();
    START_CRIT_SECTION();
    MarkBufferDirty(buf);//将序列缓冲区标记为脏
    if (logit && RelationNeedsWAL(seqrel))//是否达到记录日志标准
    {
        XLogBeginInsert();
        XLogRegisterBuffer(0, buf, REGBUF_WILL_INIT);
        seq->last_value = next;
        seq->is_called = true;
        seq->log_cnt = 0;
        xlrec.node = seqrel->rd_node;
        XLogRegisterData((char *) &xlrec, sizeof(xl_seq_rec));
        XLogRegisterData((char *) seqdatatuple.t_data, seqdatatuple.t_len);
        recptr = XLogInsert(RM_SEQ_ID, XLOG_SEQ_LOG);
        PageSetLSN(page, recptr);
    }
    seq->last_value = last;
    seq->is_called = true;
    seq->log_cnt = log;
    END_CRIT_SECTION();
    return result;
}
```

### nextval总结

```reStructuredText
1. 首先判断elm->last和elm->cached是否相等，如果不等，则表示序列还有缓存序列值，则直接从本地缓冲区获取下一个序列值（last是上次nextval返回的值，cached表示已经为nextval缓存的最后一个值），否则进入步骤2
2. 判断(是否是第一次调用nextval或者cache值大于1时)是否需要发出wal日志记录，如果需要记录日志，为了性能，我们记录序列的后cache值+32次增长数据在wal日志中，即如果cache值为5，递增数为1，则记录wal中的序列值为last_value+(5+32-1)*incby.然后在循环中或者last和next值，其中last用于cache到的最大序列值，next记录的是写入wal中的值。然后更新本地序列缓冲区信息，用于下次nextval引用直接返回缓存的序列值。
3. 如果需要记录日志，则将序列信息记录日志
4. 更新序列表的信息，序列表记录的last_value是last的值，即cache后的值
```

## 与序列相关对象

PG中的有**SERIAL**或**自增列**类型的表都依赖于序列对象，即创建带SERIAL或自增列的表时，都会隐式的创建一个依赖该表的序列对象(tablename_columnname_seq)。其中自增列的运用范围更加广泛，因为在创建时可以指定序列的基础信息，即起始值，递增间隙值等等。

### SERIAL和自增列代码

```c
//ProcessUtilitySlow-》transformCreateStmt-》transformColumnDefinition-》generateSerialExtraStmts
static void
generateSerialExtraStmts(CreateStmtContext *cxt, ColumnDef *column,
						 Oid seqtypid, List *seqoptions,
						 bool for_identity, bool col_exists,
						 char **snamespace_p, char **sname_p)
{
    //创建序列
    seqstmt = makeNode(CreateSeqStmt);
	seqstmt->for_identity = for_identity;
	seqstmt->sequence = makeRangeVar(snamespace, sname, -1);
	seqstmt->sequence->relpersistence = cxt->relation->relpersistence;
	seqstmt->options = seqoptions;
	//设置序列owner
    if (cxt->rel)
		seqstmt->ownerId = cxt->rel->rd_rel->relowner;
	else
		seqstmt->ownerId = InvalidOid;

	cxt->blist = lappend(cxt->blist, seqstmt);
    column->identitySequence = seqstmt->sequence;
    //新增Alter节点更改序列的owner
    altseqstmt = makeNode(AlterSeqStmt);
	altseqstmt->sequence = makeRangeVar(snamespace, sname, -1);
	attnamelist = list_make3(makeString(snamespace),
							 makeString(cxt->relation->relname),
							 makeString(column->colname));
	altseqstmt->options = list_make1(makeDefElem("owned_by",
												 (Node *) attnamelist, -1));
	altseqstmt->for_identity = for_identity;

	if (col_exists)
		cxt->blist = lappend(cxt->blist, altseqstmt);
	else
		cxt->alist = lappend(cxt->alist, altseqstmt);
}
//向带有SERIAL或自增列的表中插入数据时ExecEvalNextValueExpr -》nextval_internal
```

## unlogged序列

unlogged序列是为了配合unlogged表包含自增列或SERIAL列类型支持的一个特征，即与表一样，当表对象是unlogged时，数据库崩溃或者不干净关闭时，表中的数据会被清空。而对于序列，unlogged序列表中的数据会恢复到定义序列时的初始值。

### UNLOGGED原理

创建UNLOGGED对象PG首先会创建main分支，然后创建一个init分支，对应的物理存储就main分支对应oid文件，init分支对应oid_init文件。当数据库崩掉或者非正常关闭重启后，会将所有main分支的删除，然后将init文件的初始化内容拷贝至main分支。从而实现了崩溃后对象恢复到初始化状态的功能。

```c
//unlogged表的创建
static void
heapam_relation_set_new_filenode(Relation rel,...)
{
    srel = RelationCreateStorage(*newrnode, persistence);//创建主分支文件
    if (persistence == RELPERSISTENCE_UNLOGGED)
	{//创建init分支
		Assert(rel->rd_rel->relkind == RELKIND_RELATION ||
			   rel->rd_rel->relkind == RELKIND_MATVIEW ||
			   rel->rd_rel->relkind == RELKIND_TOASTVALUE);
		smgrcreate(srel, INIT_FORKNUM, false);//创建init文件
		log_smgrcreate(newrnode, INIT_FORKNUM);//记录smgr日志
		smgrimmedsync(srel, INIT_FORKNUM);//强制init数据落盘
	}
}

//unlogged序列，向main和init分支写入必要数据
static void
fill_seq_with_data(Relation rel, HeapTuple tuple)
{
	fill_seq_fork_with_data(rel, tuple, MAIN_FORKNUM);

	if (rel->rd_rel->relpersistence == RELPERSISTENCE_UNLOGGED)
	{
		SMgrRelation srel;

		srel = smgropen(rel->rd_node, InvalidBackendId);
		smgrcreate(srel, INIT_FORKNUM, false);
		log_smgrcreate(&rel->rd_node, INIT_FORKNUM);
		fill_seq_fork_with_data(rel, tuple, INIT_FORKNUM);
		FlushRelationBuffers(rel);
		smgrclose(srel);
	}
}

//unlogged数据清理，启动阶段xlog.c
StartupXLOG(void)
{
    ...
    //删除除了init文件的所有文件
	ResetUnloggedRelations(UNLOGGED_RELATION_CLEANUP);
    if (InRecovery)
        ResetUnloggedRelations(UNLOGGED_RELATION_INIT);//拷贝init文件的内容到main分支
}
```

### pg中unlogged表的缺点及解决方案

当我们Alter修改unlogged表为logged表时，流程是新创建一个数据表文件，然后将原表的数据拷贝至新表中，且没拷贝一条数据都会记录wal日志中，这导致alter unlogged表为logged表时性能差。为了快速的将unlogged表修改为logged表，我们可以不新创建表文件，也不拷贝数据，只是把原表的基础信息修改为logged表即可。这样就大大增加了将unlogged表修改为logged表的性能

## PG中序列的缺点

>1. 由于会话建独立共享hash表中的序列值，当cache值大于1时，多个会话之间会存在cache值大的间隙，即多个会话使用同一个序列值时，不同会话之间会存在间隙值
>2. 由于为了性能，每取32个序列值后才记录一次wal日志，导致序列值是不安全的，且流复制时，序列的值会有32个间隙值产生
>
>