# 📝 PostgreSQL Redo Log 与 MySQL Undo Log 设计实现对比

> **文档类型**: 技术分享文档  
> **主题**: PostgreSQL 中 `redo log` 的设计实现，与 MySQL/InnoDB 中 `undo log` 的设计实现对比  
> **适用对象**: 数据库内核开发者、DBA、数据库原理学习者  
> **版本边界**: PostgreSQL 14.x / 当前 IvorySQL Pro 代码基线；MySQL 8.4 官方文档口径

## 💡 1. 文档目标

本文重点回答 4 个问题：

- **`redo log` 和 `undo log` 到底有什么区别**
- **PostgreSQL 的 redo log 为什么是 WAL**
- **MySQL/InnoDB 的 undo log 为什么是 MVCC 主路径的一部分**
- **为什么 PostgreSQL 没有 InnoDB 式独立 undo 子系统**

本文不是在做“术语翻译”，而是在做**实现机制对比**。  
如果对比维度选错，后面的结论几乎都会跟着错。

## 🔍 2. 先给结论：这两个东西不是同一层概念

最容易犯的错误，是把 PostgreSQL 的 `redo log` 和 MySQL/InnoDB 的 `undo log` 直接摆成一对。

更准确的说法是：

- **PostgreSQL 的 `WAL` 本质上就是 `redo log`**
- **MySQL/InnoDB 的 `undo log` 主要服务回滚和一致性读**
- **更对称的比较应该是 PostgreSQL WAL vs InnoDB redo log**

### 📊 2.1 一页结论表

| 维度 | PostgreSQL | MySQL/InnoDB |
|:---|:---|:---|
| `redo` 的定位 | `WAL` 本身就是 `redo log` | `redo log` 负责崩溃恢复与持久化 |
| `undo` 体系 | 没有 InnoDB 式独立 undo 子系统 | 有完整 `undo log` / rollback segment / undo tablespace |
| MVCC 主要依赖 | tuple version + `xmin/xmax` + snapshot + `pg_xact` | `DB_TRX_ID` + `DB_ROLL_PTR` + undo chain + read view |
| 崩溃恢复主路径 | checkpoint 之后向前 redo | redo log 重放 |
| 历史版本构造方式 | 直接读取旧 tuple version | 沿 undo 链回溯构造旧版本 |

### 🚀 2.2 一句话理解

可以把这两个日志理解成两个方向完全不同的系统：

- **redo log**: 记录“已经做过的修改，宕机后怎么再做一遍”
- **undo log**: 记录“已经做过的修改，如果要撤销，应该怎么退回去”

## ⚡ 3. redo log 和 undo log 的直接区别

### 📌 3.1 从职责看区别

| 维度 | redo log | undo log |
|:---|:---|:---|
| 解决的问题 | 宕机恢复、持久化保证 | 事务回滚、历史版本读取 |
| 时间方向 | 向前恢复 | 向后恢复 |
| 典型消费者 | crash recovery、replication | rollback、consistent read、purge |
| 关注粒度 | 页面修改、LSN、物理持久化 | 行版本、事务语义、MVCC |

**核心区别**在于：

- `redo` 关心的是“结果不能丢”
- `undo` 关心的是“错误修改能撤销”

### 🔧 3.2 从记录内容看区别

`redo log` 更像“施工记录”：

- 改了哪个页
- 写了哪些内容
- 如果机器宕机，如何把这个结果补回来

`undo log` 更像“撤销说明书”：

- 这次修改之前是什么值
- 如果事务失败，应该恢复成什么状态
- 如果旧快照要读，怎样拼出历史版本

### 💡 3.3 从数据库设计上看区别

如果数据库只有 `redo log`，会有两个问题：

- **能重做提交结果**
- **但不擅长撤销未提交逻辑修改**

如果数据库只有 `undo log`，也会有问题：

- **知道怎么回退**
- **但不能高效保证提交结果在宕机后一定恢复**

所以在 InnoDB 这样的体系里，`redo` 和 `undo` 通常同时存在。  
只是 PostgreSQL 采用了**不同的 MVCC 路线**，所以没有照搬 InnoDB 的 undo 设计。

## 📊 4. PostgreSQL 中 redo log 的设计实现

### 🔍 4.1 PostgreSQL 为什么需要 redo log

PostgreSQL 的核心问题是：

- 后端先在内存 buffer 中修改页面
- 数据页不会立刻落盘
- 如果这时宕机，磁盘页可能还是旧内容

所以系统必须有一种机制，保证：

- **提交已经发生**
- **即使页没刷盘，也能在重启后恢复出正确状态**

这就是 PostgreSQL `WAL` 的职责。  
它本质上就是 PostgreSQL 的 `redo log`。

### 🔧 4.2 WAL 的核心设计目标

- **先写日志，后写数据页**
- **通过 `LSN` 建立 WAL 与数据页之间的因果关系**
- **通过 checkpoint 缩短恢复起点**
- **通过 redo replay 在启动时补回尚未落盘的页修改**

### 📌 4.3 关键数据结构

#### 🔧 4.3.1 WAL record

PostgreSQL 的 WAL record 头部定义在  
[xlogrecord.h](/usr1/V9/ivorysql-pro/src/include/access/xlogrecord.h:1)。

核心字段包括：

- `xl_tot_len`
- `xl_xid`
- `xl_prev`
- `xl_info`
- `xl_rmid`
- `xl_crc`

这说明 PostgreSQL WAL 不是简单的“事务提交日志”。  
它是**面向资源管理器和页面恢复的日志记录格式**。

#### 🔍 4.3.2 Page LSN

在 [bufpage.h](/usr1/V9/ivorysql-pro/src/include/storage/bufpage.h:1) 中，  
每个 page header 都有 `pd_lsn`。

它表示：

- **该页最近一次修改对应的 WAL 位置**

这使得 buffer manager 可以执行最关键的规则：

- **页刷盘前，WAL 至少要先 flush 到该页的 LSN**

#### ⚡ 4.3.3 Checkpoint 与 RedoRecPtr

checkpoint 的作用不是“清空 WAL”，而是建立一个新的恢复起点。

在 [xlog.c](/usr1/V9/ivorysql-pro/src/backend/access/transam/xlog.c:1) 中：

- `RedoRecPtr` 表示 redo 起点边界
- `GetRedoRecPtr()` 提供当前 redo 指针
- `GetFullPageWriteInfo()` 参与 full-page image 判定

### 🚀 4.4 WAL 的写入路径

一次典型的 PostgreSQL 页面修改，大致会经历下面这条链路：

```text
heap/btree/gin 修改页面
-> MarkBufferDirty
-> XLogBeginInsert
-> XLogRegisterBuffer / XLogRegisterData
-> XLogInsert
-> PageSetLSN
-> 提交时 XLogFlush
```

在 [heapam.c](/usr1/V9/ivorysql-pro/src/backend/access/heap/heapam.c:2238) 中，  
可以看到典型的 heap insert 写 WAL 过程。

```c
/* [1] 开始构造 WAL record */
XLogBeginInsert();

/* [2] 注册 main data */
XLogRegisterData((char *) &xlrec, SizeOfHeapInsert);

/* [3] 注册被修改的 buffer */
XLogRegisterBuffer(0, buffer, REGBUF_STANDARD | bufflags);

/* [4] 注册 buffer 上的 payload */
XLogRegisterBufData(0, (char *) &xlhdr, SizeOfHeapHeader);

/* [5] 插入 WAL record */
recptr = XLogInsert(RM_HEAP_ID, info);

/* [6] 把页面 LSN 设置为这条 WAL record 的位置 */
PageSetLSN(page, recptr);
```

这个顺序背后隐含的约束非常重要：

- **先生成日志位置**
- **再把页标记成受这条日志保护**

### 🔧 4.5 WAL record 是怎样组装的

WAL 构造主逻辑在  
[xloginsert.c](/usr1/V9/ivorysql-pro/src/backend/access/transam/xloginsert.c:1)。

核心入口包括：

1. `XLogBeginInsert()`
2. `XLogRegisterBuffer()`
3. `XLogRegisterData()`
4. `XLogInsert()`
5. `XLogInsertRecord()`

它做的事情包括：

- 收集 block reference
- 判断是否需要 full-page image
- 计算 CRC
- 把 record 复制到 WAL buffer

### ⚡ 4.6 full-page writes 为什么重要

PostgreSQL 并不是每次修改都把整页写入 WAL。  
但在某些场景下，系统会把完整页镜像写进去。

这样做的目的不是“浪费空间”，而是为了避免 torn page 风险：

- 页面可能只写了一半就宕机
- 磁盘页会处于中间态
- recovery 时先用 full-page image 恢复到一致页，再继续 redo

### 📊 4.7 提交路径为什么还要写 WAL

提交并不等于“数据页已经落盘”。  
提交真正 durable 的依据，是**提交相关 WAL 已经满足持久化要求**。

在 [xact.c](/usr1/V9/ivorysql-pro/src/backend/access/transam/xact.c:1256) 中，  
`RecordTransactionCommit()` 会：

- 写 commit record
- 视情况调用 `XLogFlush(XactLastRecEnd)`
- 之后再更新事务提交状态

这保证了：

- **先有 durable 的提交事实**
- **再有 committed 状态**

### 🔍 4.8 启动恢复时 redo 是怎么做的

PostgreSQL 启动恢复入口是  
[StartupXLOG()](/usr1/V9/ivorysql-pro/src/backend/access/transam/xlog.c:6903)。

整体流程可以概括为：

1. 读取 `pg_control` 和 checkpoint 信息
2. 找到 `checkpoint.redo`
3. 从 redo 起点向前扫描 WAL
4. 根据 `rmgr` 分发给对应 redo handler
5. 逐步把数据页恢复到一致状态

### 💡 4.9 PostgreSQL 为什么不需要 InnoDB 式 undo log

因为 PostgreSQL 的 MVCC 路线不是“当前行 + undo 链回溯旧版本”，  
而是“**旧版本本身就作为 tuple version 留在 heap 中**”。

PostgreSQL 的可见性判断依赖：

- `xmin`
- `xmax`
- snapshot
- `pg_xact`
- hint bits

回滚时不需要沿 undo 链把每个值逆操作回去。  
它更多是通过**事务状态不可见**来让这些版本失效，后续再由 `VACUUM` 回收。

## 🔧 5. MySQL/InnoDB 中 undo log 的设计实现

### 🔍 5.1 InnoDB 为什么需要 undo log

InnoDB 的核心问题与 PostgreSQL 不同。  
它不仅要解决提交后的持久化问题，还要解决：

- **事务失败后怎么回滚**
- **快照读如何看到旧版本**

这正是 undo log 的职责边界。

### 📊 5.2 undo log 的核心目标

- **支持 rollback**
- **支持 consistent read**
- **支持提交后旧版本延迟清理**

换句话说，undo log 不是一个附属机制。  
在 InnoDB 里，它是 **MVCC 主路径的一部分**。

### 🔧 5.3 InnoDB undo 的逻辑层次

可以把 InnoDB undo 体系理解为下面这层结构：

```text
undo tablespace
-> rollback segment
-> undo log segment
-> undo log record
```

这个结构说明：

- undo 不是一条简单字符串
- 它是一个完整的持久化版本管理体系

### 🔍 5.4 行记录为什么能找到旧版本

InnoDB 聚簇记录里会保存隐藏列：

- `DB_TRX_ID`
- `DB_ROLL_PTR`
- `DB_ROW_ID`

其中最关键的是：

- **`DB_TRX_ID` 表示最后修改该行的事务**
- **`DB_ROLL_PTR` 指向对应 undo record**

这意味着当前记录并不直接保存所有历史版本。  
历史版本需要沿 `DB_ROLL_PTR` 去 undo 链中追溯。

### 🚀 5.5 undo 的写入路径

一条 `UPDATE` 在 InnoDB 中，从概念上通常会做三件事：

1. 生成 undo record
2. 更新当前行上的 `DB_TRX_ID` / `DB_ROLL_PTR`
3. 再通过 redo 保护这些页面修改

所以在 InnoDB 里：

- `undo` 负责逻辑可回退性
- `redo` 负责持久化与崩溃恢复

### ⚡ 5.6 undo 为什么是 consistent read 的核心

假设某行当前值已经被新事务改成新版本。  
如果老快照读还需要旧版本，InnoDB 不能直接返回当前值。

它要做的是：

1. 检查当前行的 `DB_TRX_ID`
2. 判断该事务对当前 read view 是否可见
3. 如果不可见，就沿 `DB_ROLL_PTR` 找 undo record
4. 构造出旧版本再返回

这说明在 InnoDB 中：

- **undo 不只是回滚工具**
- **它还是历史版本读取工具**

### 📊 5.7 insert undo 和 update undo 的区别

| 类型 | 主要用途 | 提交后是否还可能保留 |
|:---|:---|:---|
| `insert undo` | 回滚插入 | 通常可尽快清理 |
| `update undo` | 回滚更新 + 构造历史版本 | 可能保留到没有快照需要它为止 |

这也是为什么长事务会拖慢 purge。  
因为旧快照存在时，某些 update undo 还不能删。

### 🔍 5.8 purge 是干什么的

在 InnoDB 中，很多旧版本不会在提交瞬间物理删除。  
它们通常会经历这样的生命周期：

1. 生成 undo
2. 提交后进入 history list
3. 旧快照可能继续读取这些历史版本
4. purge 确认无人需要后再回收

所以 purge 不是回滚。  
它是 **历史版本的延迟清理机制**。

### 💡 5.9 crash recovery 里 undo 的边界

这是最容易讲错的点之一。

正确表述应该是：

- **InnoDB crash recovery 的主轴仍然是 redo**
- **undo 的主职责是回滚和历史版本构造**
- **普通 undo 页面本身也可能受 redo 保护**

所以不能说：

- “InnoDB 靠 undo 做崩溃恢复”

更准确的说法是：

- **InnoDB 用 redo 恢复页状态**
- **再用 undo 处理事务回滚和版本语义**

## 📊 6. 三个例子讲清 redo 和 undo

### 💡 6.1 例子一：事务已提交，但页还没落盘就宕机

假设转账事务如下：

```sql
-- [1] 开启事务
BEGIN;

-- [2] A 扣 100
UPDATE account SET balance = balance - 100 WHERE id = 'A';

-- [3] B 加 100
UPDATE account SET balance = balance + 100 WHERE id = 'B';

-- [4] 提交事务
COMMIT;
```

如果 `COMMIT` 已经完成，但数据页还没完全落盘就宕机，  
数据库启动后必须把“已提交的结果”恢复出来。

这个场景里主角是：

- **redo log**

因为系统要解决的问题是：

- **提交结果不能丢**

### 🔧 6.2 例子二：事务执行到一半失败，必须回滚

假设事务执行过程如下：

```sql
-- [1] 开启事务
BEGIN;

-- [2] A 扣 100
UPDATE account SET balance = balance - 100 WHERE id = 'A';

-- [3] 发生错误
ROLLBACK;
```

这时业务要求是：

- A 的余额恢复成原来的值

这个场景里主角是：

- **undo log**

因为系统要解决的问题是：

- **已经做过的修改必须撤销**

### 🔍 6.3 例子三：一致性读为什么依赖 undo

假设原始数据为：

```text
id=1, price=100
```

事务 T1 执行：

```sql
-- [1] 开启事务
BEGIN;

-- [2] 把价格从 100 改到 120
UPDATE product SET price = 120 WHERE id = 1;
```

事务 T2 在旧快照中查询：

```sql
-- [1] 旧快照读
SELECT price FROM product WHERE id = 1;
```

如果采用 InnoDB 的 undo 链机制，那么：

- 当前记录上也许已经是 `120`
- 但 T2 不能看到这个版本
- 系统必须沿 `DB_ROLL_PTR` 找旧 undo record
- 最终构造出 `100` 返回给 T2

这个例子说明：

- **undo 不只是给 rollback 用**
- **undo 还是 MVCC 读路径的一部分**

而 PostgreSQL 在同样场景下的做法不同：

- 新旧版本作为不同 tuple 共存
- 查询通过 snapshot 判断哪个版本可见
- 不需要沿独立 undo 链重建旧值

## 📊 7. PostgreSQL redo 与 InnoDB undo 的正面对比

### 🔧 7.1 目标对比

| 维度 | PostgreSQL WAL/redo | InnoDB undo |
|:---|:---|:---|
| 首要目标 | 崩溃恢复、持久化、复制 | 回滚、历史版本构造 |
| 核心对象 | 页面修改、WAL record、LSN | 行版本、undo record、rollback segment |
| 时间方向 | 向前恢复 | 向后恢复 |
| 与 MVCC 的关系 | 间接支撑 | 主路径组成部分 |

### 🔍 7.2 版本管理对比

| 维度 | PostgreSQL | InnoDB |
|:---|:---|:---|
| 当前版本 | heap tuple | clustered record |
| 历史版本 | 旧 tuple 仍在 heap 中 | undo 链中保存旧版本信息 |
| 可见性判断 | `xmin/xmax + snapshot + pg_xact` | `DB_TRX_ID + read view + undo chain` |
| 清理机制 | `VACUUM` / prune | purge |

### ⚡ 7.3 crash recovery 对比

| 维度 | PostgreSQL | InnoDB |
|:---|:---|:---|
| 恢复主日志 | WAL/redo | redo log |
| undo 的地位 | 无 InnoDB 式独立 undo 子系统 | 回滚与旧版本读取核心结构 |
| 页面一致性 | full-page writes + page LSN | redo + flush 协调 |

## 🚀 8. 最容易讲错的 6 个点

### 🔍 8.1 误区一：PostgreSQL 也有和 InnoDB 一样的 undo log

这是**错误的**。  
PostgreSQL 没有 InnoDB 那种 rollback segment + undo chain 体系。

### 🔧 8.2 误区二：redo 和 undo 是完全对称的一对

这也是**错误的**。  
在 InnoDB 中它们是一组互补机制，但 PostgreSQL 采用了不同的 MVCC 路线。

### ⚡ 8.3 误区三：PostgreSQL 回滚靠 WAL 反向回放

这不准确。  
PostgreSQL 没有独立的 InnoDB 式 undo 链回滚体系。

### 📊 8.4 误区四：InnoDB undo 只在 rollback 时才用

这是**错误的**。  
consistent read 读取历史版本时，同样依赖 undo。

### 💡 8.5 误区五：InnoDB crash recovery 主要靠 undo

这是**错误的**。  
crash recovery 主轴仍然是 redo。

### 📝 8.6 误区六：PostgreSQL WAL 只是提交日志

这也是**错误的**。  
WAL 包含大量页面级、rmgr 级、full-page image 级别的信息。

## 📝 9. 技术分享时建议怎么讲

### 💡 9.1 推荐讲解顺序

1. 先讲 `redo` 和 `undo` 的职责差异
2. 再讲 PostgreSQL 的 WAL 为什么就是 redo
3. 再讲 InnoDB 的 undo 为什么是 MVCC 主路径
4. 最后讲 PostgreSQL 为什么不需要这种 undo 体系

### 📊 9.2 推荐做成的三张核心图

- **图 1**: PostgreSQL `修改页 -> 写 WAL -> flush -> 宕机后 redo`
- **图 2**: InnoDB `当前记录 -> DB_ROLL_PTR -> undo chain -> 旧版本`
- **图 3**: `PostgreSQL tuple version` vs `InnoDB undo chain` 总对比

### 🚀 9.3 最适合收尾的一句话

> **redo log 保障提交结果不能丢，undo log 保障错误修改可以撤销、旧版本可以读取。**

## 🔍 10. 源码阅读路径

### 🔧 10.1 PostgreSQL 侧

- [WAL record 格式定义](/usr1/V9/ivorysql-pro/src/include/access/xlogrecord.h:1)
- [页面头与 `pd_lsn`](/usr1/V9/ivorysql-pro/src/include/storage/bufpage.h:1)
- [WAL 组装与插入](/usr1/V9/ivorysql-pro/src/backend/access/transam/xloginsert.c:1)
- [WAL flush、checkpoint、recovery](/usr1/V9/ivorysql-pro/src/backend/access/transam/xlog.c:1)
- [事务提交 WAL 路径](/usr1/V9/ivorysql-pro/src/backend/access/transam/xact.c:1256)
- [heap 修改写 WAL 的典型入口](/usr1/V9/ivorysql-pro/src/backend/access/heap/heapam.c:2238)

### 📊 10.2 MySQL / InnoDB 侧

- [MySQL 8.4: InnoDB Multi-Versioning](https://dev.mysql.com/doc/refman/8.4/en/innodb-multi-versioning.html)
- [MySQL 8.4: Undo Logs](https://dev.mysql.com/doc/refman/8.4/en/innodb-undo-logs.html)
- [MySQL 8.4: InnoDB Recovery](https://dev.mysql.com/doc/refman/en/innodb-recovery.html)
- [MySQL 源码文档: trx0undo.cc](https://dev.mysql.com/doc/dev/mysql-server/latest/trx0undo_8cc.html)
- [MySQL 源码文档: row_vers_build_for_consistent_read](https://dev.mysql.com/doc/dev/mysql-server/8.4.7/row0vers_8h.html)

## 💡 11. 最终总结

如果只记住一句话，那么应该记住这句：

> **PostgreSQL 用 WAL/redo 解决“提交结果如何在宕机后恢复”，InnoDB 用 undo 解决“修改如何回滚、旧版本如何读取”；它们不是同一层抽象，不应直接当成对称概念比较。**
