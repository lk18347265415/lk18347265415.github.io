---
layout:	post
title:	"MVCC in Postgres"
date:	2021-08-30 15:58:00 +0800
categories:	[postgres]
---

> **MVCC介绍**

Postgres提供了一组丰富的工具来管理对数据的**并发**访问。在内部，数据一致性通过使用一种多版本模型（Multiversion Concurrency Control，MVCC）来维护。这意味着当检索数据时，每个事务看到的只是一段时间之前的数据快照（一个数据库版本），而不是底层数据的当前状态。这样可以保护语句不会看到可能由其它在相同数据行上执行更新的并发事务造成不一致数据，为每个数据库会话体统事务隔离。MVCC避免了使用锁的方法，MVCC对查询数据的锁请求与写数据的锁请求不冲突，所以**读不会阻塞写，且写也不阻塞读**。极大的提高了并发处理能力。

> **MVCC的通用实现**

常见的两种实现方法：

1）更新数据时，把旧数据移到一个单独的地方(如回滚段中--undo log)，其它事务读取数据时，从单独存放的地方把旧数据读出来。

2） 更新数据时，旧数据不删除，只对旧数据做标记处理，新数据插入新的数据行中（tuple中）。

Postgres使用的是第二种方案，oralce和mysql（innodb）使用的第一种实现方案。

方案2的优势在于：

- 事务回滚可以立即完成，无论事务进行了多少操作（mysql大事务回滚慢）。

  注意！：为什么说事务回滚很快？这要涉及到PG的clog日志对可见性设置的问题，后面会专门出章节介绍PG的clog原理

- 数据可以进行很多更新，不必像Oracle和innodb那样需要经常保证回滚段不会被用完。

方案2的劣势在于：

- 旧版本数据会占据磁盘空间，降低了查询性能，旧版本数据需要清理。postgres清理旧版本的进程为**vacuum**。

- 事务ID由32位数保存，用完会导致wraparound问题 

  

> **Postgres中MVCC的实现原理**

Postgres中表都有以下几个关键字段：

**txid:**事务ID,每当事务开始时，事务管理器就会为其分配一个唯一的标识符

**xmin（TransactionId）**: 插入改行版本的事务ID

**xmax（TransactionId）**: 删除改行版本的事务ID，第一次插入时为0，如果该字段不为0，表示这行事务还没有提交或者删除次行的事务回滚了。

cmin（CommandId）: 事务内部插入类操作的命令ID，从0开始。

cmax（CommandId）: 事务内部删除类操作的命令ID,如果不是删除命令，此字段为0。

ctid（ItemPointerData）: 一个行版本在它所处的表内的物理位置，指向最新版本位置。如（0,1）指向自己。

前面所说的postgres是通过把旧数据留在数据文件中，其中实现原理就是以上的xmin、xmax、cmin和cmax来记录并判断行版本信息。然后删除数据时，需记住记录并没有从数据块中删除，空间也没有释放。一个新元祖被保存在磁盘的时候，其ctid就被初始化为它自己的实际存储位置，如果该元祖被更新了，该元组的ctid字段就指向更新后的元祖，如果要找到某个版本的最新元祖，需要遍历ctid构成的链表。在HeapTupleHeaderData中，还有个重要的字段（t_infomask）用来表示当前元祖的事务信息，如下所示：

```c
/*
 * information stored in t_infomask:
 */
#define HEAP_HASNULL			0x0001	/* has null attribute(s) */
#define HEAP_HASVARWIDTH		0x0002	/* has variable-width attribute(s) */
#define HEAP_HASEXTERNAL		0x0004	/* has external stored attribute(s) */
#define HEAP_HASOID_OLD			0x0008	/* has an object-id field */
#define HEAP_XMAX_KEYSHR_LOCK	0x0010	/* xmax is a key-shared locker */
#define HEAP_COMBOCID			0x0020	/* t_cid is a combo cid */
#define HEAP_XMAX_EXCL_LOCK		0x0040	/* xmax is exclusive locker */
#define HEAP_XMAX_LOCK_ONLY		0x0080	/* xmax, if valid, is only a locker */

 /* xmax is a shared locker */
#define HEAP_XMAX_SHR_LOCK	(HEAP_XMAX_EXCL_LOCK | HEAP_XMAX_KEYSHR_LOCK)

#define HEAP_LOCK_MASK	(HEAP_XMAX_SHR_LOCK | HEAP_XMAX_EXCL_LOCK | \
						 HEAP_XMAX_KEYSHR_LOCK)
#define HEAP_XMIN_COMMITTED		0x0100	/* t_xmin 已提交 */
#define HEAP_XMIN_INVALID		0x0200	/* t_xmin 无效/中断 */
#define HEAP_XMIN_FROZEN		(HEAP_XMIN_COMMITTED|HEAP_XMIN_INVALID)
#define HEAP_XMAX_COMMITTED		0x0400	/* t_xmax 已提交 */
#define HEAP_XMAX_INVALID		0x0800	/* t_xmax 无效/中断 */
#define HEAP_XMAX_IS_MULTI		0x1000	/* t_xmax 是组合事务 */
#define HEAP_UPDATED			0x2000	/* 这是更新 */
#define HEAP_MOVED_OFF			0x4000	/* moved to another place by pre-9.0
										 * VACUUM FULL; kept for binary
										 * upgrade support */
#define HEAP_MOVED_IN			0x8000	/* moved from another place by pre-9.0
										 * VACUUM FULL; kept for binary
										 * upgrade support */
#define HEAP_MOVED (HEAP_MOVED_OFF | HEAP_MOVED_IN)
#define HEAP_XACT_MASK			0xFFF0	/* visibility-related bits */
```



Postgres把事务状态记录在commit log中（PG有两个二进制日志文件一个是xlog，一个是clog），简称为clog（功能同undo），后面因为很多人删除*log的原因，将clog改为xact日志。如下：

```c
[root@mypg01 data]# ls -l pg_xact
total 8
-rw------- 1 postgres postgres 8192 Aug 30 17:32 0000
```

事务的状态有一下四种：

```c
#define TRANSACTION_STATUS_IN_PROGRESS		0x00//事务正在进行中
#define TRANSACTION_STATUS_COMMITTED		0x01//事务已经提交
#define TRANSACTION_STATUS_ABORTED			0x02//事务已回滚
#define TRANSACTION_STATUS_SUB_COMMITTED	0x03//子事务已提交
```

clog中记录了每个事务相关的xid以及xid对应的事务提交状态（如上），所以查询数据时，得到tuple的xid时，如果要确定它的可见性，就需要查询clog日志做判断。

