# 🧩 PostgreSQL 扩展机制实现框架、源码原理与多线程失效分析

> 📌 文档类型：技术分享 / 机制分析
> 👥 适用对象：扩展开发者、数据库内核工程师、多线程改造评估者。
> 🧭 阅读方式：建议先理解扩展机制，再进入“为什么多线程会破坏这套契约”的分析。

## 🧭 快速导航

- 🎯 1. 目标与结论
- 🏗️ 2. 扩展机制的总体架构
- 📄 3. 扩展对象由哪些部分组成
- ⚙️ 4. CREATE EXTENSION 的内核执行流程
- 📄 4.1 入口：CreateExtension
- 📄 4.2 读取 control 文件
- 📄 4.3 版本与升级路径
- 📄 4.4 插入 pg_extension
- ⚙️ 4.5 执行扩展脚本
- ⚙️ 4.6 执行 SQL 字符串的方式
- 📄 5. 扩展对象是如何归属到某个 extension 的
- 📄 6. C 扩展函数是如何被调用的
- 📄 6.1 pg_proc 中存的是什么
- 📄 6.2 fmgr 的角色
- 📄 6.3 动态库加载：dfmgr
- 📄 6.4 为什么必须有 PG_MODULE_MAGIC
- 📄 6.5 为什么必须有 PG_FUNCTION_INFO_V1
- 📄 6.6 调用约定：FunctionCallInfo
- 📄 7. 两个典型扩展示例
- 📄 7.1 普通 C 函数扩展：test_bloomfilter
- 📄 7.2 hook 型扩展：auto_explain
- 📄 8. PostgreSQL 扩展机制为什么能工作
- 📄 9. 为什么改成多线程后，现有扩展机制会失效
- 📄 9.1 PostgreSQL 原生就是按多进程模型设计的
- 📄 9.2 扩展安装上下文依赖进程级全局变量
- 📄 9.3 动态库缓存是进程级静态变量，不是线程局部
- 📄 9.4 backend 全局运行时状态不是线程局部
- 📄 9.5 扩展普遍依赖“static 变量 == 会话私有”
- 📄 9.6 错误处理模型与栈模型并不是通用线程安全设计
- 📄 9.7 fork、信号、库初始化假设也会被破坏
- 📄 10. “失效”具体会表现成什么
- 📄 11. 如果一定要做多线程，需要改到什么程度
- ✅ 12. 技术分享时可直接使用的总结
- 📚 13. 参考源码
- 📄 14. 附：一个适合口头讲解的结束语

---

## 🎯 1. 目标与结论

这份文档面向技术分享，回答四个问题：

1. PostgreSQL 的扩展机制整体框架是什么。
2. 扩展是如何从控制文件、SQL 脚本走到 C 函数调用的。
3. 典型扩展代码应该怎么写，内核如何加载和执行它。
4. 为什么把 PostgreSQL 从多进程模型强行改成多线程模型后，现有扩展机制会大面积失效。

核心结论：

- PostgreSQL 的扩展机制本质上是 `SQL 安装脚本 + catalog 元数据 + 动态库加载 + fmgr 调用框架 + 依赖管理` 的组合。
- 它的实现建立在 PostgreSQL 传统的“每个会话一个 backend 进程”的假设上。
- 现有扩展 ABI 并不是围绕“同一进程内多个并发线程共享一套后端全局状态”设计的。
- 因此，一旦把 PostgreSQL 改为多线程，哪怕 core 代码勉强能跑，大量现有扩展也会因为全局变量、hook、内存上下文、错误栈、信号/中断、静态缓存、`fork` 假设而失效。

---

## 🏗️ 2. 扩展机制的总体架构

可以把 PostgreSQL 扩展拆成两层：

- 控制面：安装、升级、卸载、依赖归属。
- 执行面：把 SQL 对象映射到 C/PL 函数并执行。

整体链路如下：

![PostgreSQL 扩展机制整体链路](images/postgresql_extension_mechanism_flow.png)

对应源码主文件：

- 扩展安装与升级：`src/backend/commands/extension.c`
- 扩展成员依赖归属：`src/backend/catalog/pg_depend.c`
- 动态库加载：`src/backend/utils/fmgr/dfmgr.c`
- 函数管理器：`src/backend/utils/fmgr/fmgr.c`
- fmgr ABI 定义：`src/include/fmgr.h`

---

## 📄 3. 扩展对象由哪些部分组成

一个典型 C 扩展至少包含三类文件：

1. 控制文件：`xxx.control`
2. 安装/升级脚本：`xxx--1.0.sql`、`xxx--1.0--1.1.sql`
3. 共享库源码：`xxx.c`，编译后成为 `xxx.so`

最小例子可以直接看测试模块 `test_bloomfilter`：

- 控制文件：`src/test/modules/test_bloomfilter/test_bloomfilter.control`
- SQL 文件：`src/test/modules/test_bloomfilter/test_bloomfilter--1.0.sql`
- C 实现：`src/test/modules/test_bloomfilter/test_bloomfilter.c`

### 3.1 control 文件

`test_bloomfilter.control` 内容很小：

```conf
comment = 'Test code for Bloom filter library'
default_version = '1.0'
module_pathname = '$libdir/test_bloomfilter'
relocatable = true
```

其中关键字段：

- `default_version`：默认安装版本
- `module_pathname`：SQL 脚本中的 `MODULE_PATHNAME` 替换值
- `relocatable`：是否允许 `ALTER EXTENSION SET SCHEMA`
- `requires`：依赖哪些扩展
- `schema`：固定安装到哪个 schema
- `superuser` / `trusted`：权限策略

源码中，control 文件由 `parse_extension_control_file()` 解析，使用的其实就是 GUC 的配置文件解析器。见 `src/backend/commands/extension.c:478`。

### 3.2 SQL 安装脚本

`test_bloomfilter--1.0.sql` 的关键语句：

```sql
CREATE FUNCTION test_bloomfilter(...)
RETURNS pg_catalog.void STRICT
AS 'MODULE_PATHNAME' LANGUAGE C;
```

这里没有直接写 `.so` 路径，而是先写 `MODULE_PATHNAME`，在执行脚本前由内核替换成 control 文件里的 `$libdir/test_bloomfilter`。替换逻辑在 `execute_extension_script()` 中完成，见 `src/backend/commands/extension.c:1062`。

### 3.3 C 代码

`test_bloomfilter.c` 展示了两个最关键的宏：

```c
PG_MODULE_MAGIC;
PG_FUNCTION_INFO_V1(test_bloomfilter);
```

- `PG_MODULE_MAGIC`：告诉内核“这个模块是按当前 PostgreSQL ABI 编译的”
- `PG_FUNCTION_INFO_V1`：告诉 fmgr“这个函数按 V1 调用约定暴露”

对应定义在 `src/include/fmgr.h:427` 和后续 `PG_MODULE_MAGIC` 相关结构定义区域。

---

## ⚙️ 4. CREATE EXTENSION 的内核执行流程

## 📄 4.1 入口：CreateExtension

SQL `CREATE EXTENSION` 最终进入 `CreateExtension()`，见 `src/backend/commands/extension.c:1884`。

它主要做三件事：

1. 校验扩展名与是否已存在。
2. 解析 `SCHEMA`、`VERSION`、`CASCADE` 等选项。
3. 调 `CreateExtensionInternal()` 做真正工作。

特别要注意这里的一个实现假设：

```c
if (creating_extension)
    ereport(ERROR, ... "nested CREATE EXTENSION is not supported")
```

`creating_extension` 是进程级全局变量，定义在 `src/backend/commands/extension.c:74`。这已经说明扩展安装上下文默认假设“一个 backend 同时只会安装一个扩展”。

## 📄 4.2 读取 control 文件

控制文件路径生成逻辑：

- `get_extension_control_filename()`：拼出 `share/extension/xxx.control`
- `get_extension_script_filename()`：拼出 `xxx--1.0.sql` 或 `xxx--1.0--1.1.sql`

这部分在 `src/backend/commands/extension.c:390-465`。

`read_extension_control_file()` 会先给 `ExtensionControlFile` 填默认值，然后调用 `parse_extension_control_file()` 真正解析，见：

- `src/backend/commands/extension.c:638`
- `src/backend/commands/extension.c:478`

解析结果进入结构体：

```c
typedef struct ExtensionControlFile
{
    char *name;
    char *directory;
    char *default_version;
    char *module_pathname;
    char *comment;
    char *schema;
    bool relocatable;
    bool superuser;
    bool trusted;
    int  encoding;
    List *requires;
} ExtensionControlFile;
```

这个结构体就是扩展安装阶段的“配置描述对象”。

## 📄 4.3 版本与升级路径

如果指定版本没有直接安装脚本，PostgreSQL 会尝试找到升级路径。

涉及函数：

- `get_ext_ver_list()`
- `identify_update_path()`
- `ApplyExtensionUpdates()`

这些函数在 `extension.c` 中把版本看成图上的节点，把 `a--b.sql` 看成边，然后选择一条路径执行升级脚本。

这意味着 PostgreSQL 扩展升级不是“替换整个扩展”，而是“按版本迁移脚本逐步变更 catalog 和对象集”。

## 📄 4.4 插入 pg_extension

扩展本身首先是一个 catalog 对象。`InsertExtensionTuple()` 负责往 `pg_extension` 插一行，见 `src/backend/commands/extension.c:1991`。

它会记录：

- 扩展 OID
- 扩展名
- owner
- schema
- relocatable
- version
- extconfig / extcondition

并建立依赖：

- 对 owner 的依赖
- 对 schema 的依赖
- 对 prerequisite extension 的依赖

因此，“扩展”在 PostgreSQL 里不是纯文件概念，而是 catalog 中的一等对象。

## ⚙️ 4.5 执行扩展脚本

扩展脚本执行函数是 `execute_extension_script()`，见 `src/backend/commands/extension.c:861`。

这部分是扩展机制最关键的桥：

1. 切换权限或临时提升为 bootstrap superuser
2. 设置 GUC，如 `client_min_messages`、`check_function_bodies`
3. 重写 `search_path`
4. 设置扩展安装上下文：

```c
creating_extension = true;
CurrentExtensionObject = extensionOid;
```

5. 读取 SQL 文件
6. 替换 `@extowner@`、`@extschema@`、`MODULE_PATHNAME`
7. 执行 SQL 字符串

其中第 4 步非常关键。扩展安装不是靠“脚本外部”推断对象归属，而是靠安装时打开一个全局上下文，告诉后续 DDL：

- 当前正在创建扩展
- 当前扩展 OID 是谁

## ⚙️ 4.6 执行 SQL 字符串的方式

`execute_sql_string()` 不是简单调用 SPI，而是完整走一遍 SQL 管线，见 `src/backend/commands/extension.c:734`：

1. `pg_parse_query(sql)`
2. `pg_analyze_and_rewrite(...)`
3. `pg_plan_queries(...)`
4. 普通语句走 Executor
5. Utility 语句走 `ProcessUtility`

也就是说，扩展安装脚本执行的语义，和客户端发来的 SQL 基本一致，只是被包在一个受控上下文中。

---

## 📄 5. 扩展对象是如何归属到某个 extension 的

扩展脚本里会创建函数、类型、操作符、索引方法等对象。PostgreSQL 需要知道这些对象属于哪个扩展，以便：

- `DROP EXTENSION` 时级联删除
- `pg_dump` / `pg_upgrade` 正确处理
- 防止对象被错误替换或越权吸收

这个逻辑在 `recordDependencyOnCurrentExtension()`，见 `src/backend/catalog/pg_depend.c:188`。

核心逻辑：

```c
if (creating_extension)
{
    extension.objectId = CurrentExtensionObject;
    recordDependencyOn(object, &extension, DEPENDENCY_EXTENSION);
}
```

所以扩展成员资格不是放在对象本身上，而是写进 `pg_depend`：

- depender：新建对象
- referenced：当前扩展对象
- deptype：`DEPENDENCY_EXTENSION`

这也是 PostgreSQL 扩展机制的本质之一：

> 扩展不是一个“插件容器”，而是一组 catalog 对象通过依赖边绑定成的逻辑集合。

---

## 📄 6. C 扩展函数是如何被调用的

## 📄 6.1 pg_proc 中存的是什么

对 `LANGUAGE C` 函数，`pg_proc` 里至少有两列重要信息：

- `probin`：动态库路径，如 `$libdir/test_bloomfilter`
- `prosrc`：符号名，如 `test_bloomfilter`

扩展安装脚本执行 `CREATE FUNCTION ... AS 'MODULE_PATHNAME'` 时，最终就是把这两个信息写入 `pg_proc`。

## 📄 6.2 fmgr 的角色

PostgreSQL 并不直接通过函数名调用 C 符号，而是先经过 fmgr。

`fmgr_info()` / `fmgr_info_cxt_security()` 会根据函数 OID 查 `pg_proc`，再决定：

- 内建函数：直接取内核函数地址
- `LANGUAGE C`：走动态库加载
- `LANGUAGE SQL`：走 `fmgr_sql`
- 其他 PL：走对应语言 handler

入口逻辑见 `src/backend/utils/fmgr/fmgr.c:245` 之后，C 语言分支进入 `fmgr_info_C_lang()`，见 `src/backend/utils/fmgr/fmgr.c:452`。

## 📄 6.3 动态库加载：dfmgr

`fmgr_info_C_lang()` 做的事情很直白：

1. 从 `pg_proc` 取出 `probin` 和 `prosrc`
2. 调 `load_external_function(probin, prosrc, ...)`
3. 调 `fetch_finfo_record(...)`
4. 把函数地址缓存到 `CFuncHash`

代码见：

- `src/backend/utils/fmgr/fmgr.c:452`
- `src/backend/utils/fmgr/fmgr.c:494`
- `src/backend/utils/fmgr/fmgr.c:498`
- `src/backend/utils/fmgr/fmgr.c:500`

真正 `dlopen/dlsym` 的地方在 `dfmgr.c`：

- `load_external_function()`：`src/backend/utils/fmgr/dfmgr.c:106`
- `internal_load_library()`：`src/backend/utils/fmgr/dfmgr.c:183`

它会：

1. 展开动态库路径
2. 检查该库是否已经在当前 backend 内加载过
3. `dlopen(..., RTLD_NOW | RTLD_GLOBAL)`
4. 查找 `PG_MAGIC_FUNCTION_NAME_STRING`
5. 校验 `PG_MODULE_MAGIC`
6. 如果有 `_PG_init()`，调用 `_PG_init()`

这就是 PostgreSQL 扩展初始化回调的来源。

## 📄 6.4 为什么必须有 PG_MODULE_MAGIC

`dfmgr.c` 在加载共享库后会检查 magic block，见 `src/backend/utils/fmgr/dfmgr.c:251`。

校验内容包括：

- major version
- `FUNC_MAX_ARGS`
- `INDEX_MAX_KEYS`
- `NAMEDATALEN`
- `FLOAT8PASSBYVAL`

如果不匹配，直接报 `incompatible library`。

所以 `PG_MODULE_MAGIC` 的本质是：

> 扩展 ABI 兼容性自检机制。

## 📄 6.5 为什么必须有 PG_FUNCTION_INFO_V1

`fetch_finfo_record()` 会寻找 `pg_finfo_<funcname>`，见 `src/backend/utils/fmgr/fmgr.c:562`。

这个函数通常由 `PG_FUNCTION_INFO_V1(funcname)` 宏自动生成，定义见 `src/include/fmgr.h:427`。

这个宏返回：

```c
static const Pg_finfo_record my_finfo = { 1 };
```

也就是告诉 fmgr：这个函数遵守 V1 调用约定。

没有它，PostgreSQL 会报错：

```text
could not find function information for function "xxx"
SQL-callable functions need an accompanying PG_FUNCTION_INFO_V1(funcname).
```

## 📄 6.6 调用约定：FunctionCallInfo

fmgr 的真正 ABI 不是普通 C 参数列表，而是统一的：

```c
Datum func(PG_FUNCTION_ARGS)
```

其中 `PG_FUNCTION_ARGS` 展开为：

```c
FunctionCallInfo fcinfo
```

`FunctionCallInfo` 内含：

- `flinfo`：函数查找结果
- `context`：调用上下文
- `resultinfo`：返回附加信息
- `fncollation`
- `nargs`
- `args[]`
- `isnull`

设计说明见 `src/backend/utils/fmgr/README:10` 开始，结构体定义见 `src/include/fmgr.h`。

这套设计把“函数查找”和“函数执行”分离开来，便于缓存函数入口地址，也便于统一支持 SQL、C、PL handler。

---

## 📄 7. 两个典型扩展示例

## 📄 7.1 普通 C 函数扩展：test_bloomfilter

这是最标准的一类扩展。

### 写法

1. control 文件声明版本和库路径。
2. SQL 文件创建 `LANGUAGE C` 函数。
3. C 文件中：

```c
PG_MODULE_MAGIC;
PG_FUNCTION_INFO_V1(test_bloomfilter);

Datum
test_bloomfilter(PG_FUNCTION_ARGS)
{
    int power = PG_GETARG_INT32(0);
    ...
    PG_RETURN_VOID();
}
```

### 内核视角的调用链

```text
SELECT test_bloomfilter(...)
-> parser/analyzer/planner/executor
-> fmgr_info(functionOid)
-> fmgr_info_C_lang()
-> load_external_function()
-> dlopen + dlsym
-> fetch_finfo_record()
-> FunctionCallInvoke(fcinfo)
```

### 特点

- 不需要 hook
- 不需要 shared preload
- 第一次调用时装载共享库，后续走缓存

## 📄 7.2 hook 型扩展：auto_explain

`auto_explain` 代表另一大类扩展：不是靠显式 SQL 调用，而是通过 `_PG_init()` 改写全局 hook。

看 `contrib/auto_explain/auto_explain.c`：

- `PG_MODULE_MAGIC`：第 23 行
- `_PG_init()`：第 92 行开始
- 保存原 hook 并安装新 hook：第 235 行开始

它在 `_PG_init()` 中做两件事：

1. 注册自定义 GUC
2. 接管 `ExecutorStart_hook`、`ExecutorRun_hook` 等

这类扩展更能说明 PostgreSQL 扩展机制的真实边界：

> 扩展不仅是“外部函数”，还可以直接修改 backend 进程内部的全局行为。

---

## 📄 8. PostgreSQL 扩展机制为什么能工作

它能工作，不是因为插件系统“很通用”，而是因为 PostgreSQL 提供了几个非常强的运行时契约：

### 8.1 进程隔离契约

一个 client session 对应一个 backend 进程。该进程独占：

- `CurrentMemoryContext`
- `CurrentResourceOwner`
- `error_context_stack`
- `MyProc`
- `MyProcPort`
- `MyLatch`
- GUC 栈
- 中断标志
- hook 指针的运行时使用环境

所以扩展作者天然可以假设：

- backend 全局变量就是“本会话私有”
- `static` 缓存就是“本进程私有”
- 出问题最多杀死当前 backend，不会污染其他会话线程

### 8.2 统一 ABI 契约

所有 SQL 可调用函数统一通过 fmgr 调用，签名统一为：

```c
Datum func(FunctionCallInfo fcinfo)
```

这样内核就能在调用前后注入：

- null 语义
- collation
- 统计信息
- security definer
- hook
- set-returning protocol

### 8.3 catalog + dependency 契约

扩展中的对象不是散落在文件系统里，而是 catalog 中有据可查，并通过 `pg_depend` 与扩展绑定。

因此 PostgreSQL 可以支持：

- `DROP EXTENSION`
- `ALTER EXTENSION UPDATE`
- `ALTER EXTENSION ADD/DROP`
- `pg_dump` 识别扩展对象

---

## 📄 9. 为什么改成多线程后，现有扩展机制会失效

这一节是重点。

先说结论：

> 不是“动态库机制”本身失效，而是“现有扩展 ABI 所依赖的后端运行时假设”失效。

换句话说，`dlopen` 还能用，`dlsym` 也还能用，但扩展进入 backend 后看到的世界已经变了。

## 📄 9.1 PostgreSQL 原生就是按多进程模型设计的

`postmaster.c` 文件头已经写得很明确，见 `src/backend/postmaster/postmaster.c:25`：

- 收到连接后立刻 `fork()`
- child 做认证并成为 backend
- 这样认证代码可以保持简单的 single-threaded 风格
- 也避免非线程安全库把整个服务拖死

同时，源码还显式防御 postmaster 意外变成多线程。见 `src/backend/postmaster/postmaster.c:1638`：

- `fork()` without immediate `exec()` 在多线程程序里是未定义行为
- `sigprocmask()` 在多线程场景也会出问题

这说明 PostgreSQL 的顶层架构前提就是：

> postmaster 单线程，backend 多进程隔离。

## 📄 9.2 扩展安装上下文依赖进程级全局变量

扩展安装依赖两个全局变量：

- `creating_extension`
- `CurrentExtensionObject`

定义在 `src/backend/commands/extension.c:74-75`，使用在：

- `execute_extension_script()`：`src/backend/commands/extension.c:985`
- `recordDependencyOnCurrentExtension()`：`src/backend/catalog/pg_depend.c:194`

在多进程模型下，这没问题，因为每个 backend 只有一条执行主线。

但在多线程模型下，如果同一进程内两个线程同时：

- 一个在 `CREATE EXTENSION a`
- 一个在 `CREATE EXTENSION b`

那么这两个全局变量会互相覆盖，导致：

- 对象被错误挂到别的扩展上
- `nested CREATE EXTENSION` 误报
- `CurrentExtensionObject` 指向错对象

这是第一类失效：**全局安装上下文冲突**。

## 📄 9.3 动态库缓存是进程级静态变量，不是线程局部

`dfmgr.c` 里：

- `file_list`
- `file_tail`

定义在 `src/backend/utils/fmgr/dfmgr.c:67-68`

`fmgr.c` 里：

- `CFuncHash`
- `needs_fmgr_hook`
- `fmgr_hook`

定义在：

- `src/backend/utils/fmgr/fmgr.c:42-43`
- `src/backend/utils/fmgr/fmgr.c:58`

这些对象默认都是“backend 进程内唯一一份”。

在多进程模型下，这意味着：

- 每个 backend 自己维护一套已加载库列表
- 每个 backend 自己维护一套函数地址缓存

但在多线程模型下，这变成了：

- 所有线程共享一套动态库加载链表
- 所有线程共享一套 C 函数缓存哈希
- 所有线程共享 hook 指针

问题有两类：

1. 并发安全问题  
   这些结构本身没有锁，多个线程并发插入/查找会破坏链表和哈希表。

2. 语义安全问题  
   扩展作者原本以为“模块内 static 状态是本 backend 私有”，线程化后却变成“整个 server 进程内所有会话共享”。

这是第二类失效：**静态缓存与 hook 的共享化**。

## 📄 9.4 backend 全局运行时状态不是线程局部

PostgreSQL 大量关键状态都是普通全局变量：

- `CurrentMemoryContext`：`src/include/utils/palloc.h:59`
- `CurrentResourceOwner`：`src/include/utils/resowner.h:33`
- `MyProc`：`src/include/storage/proc.h:295`
- `MyProcPid` / `MyProcPort` / `MyLatch`：`src/include/miscadmin.h:180-184`
- `InterruptPending` / `InterruptHoldoffCount`：`src/include/miscadmin.h:90-104`

在当前模型里，这些变量的隐含语义是：

- “当前 backend 的状态”
- 不是“当前线程的状态”

扩展里大量 API 都默认读写这些变量。例如：

- `palloc()` 默认使用 `CurrentMemoryContext`
- `CHECK_FOR_INTERRUPTS()` 依赖 `InterruptPending`
- 等待/唤醒依赖 `MyLatch`
- 错误恢复依赖 error context / longjmp 栈

如果变成多线程，同一进程内两个线程会同时改这些变量：

- A 线程切换 `CurrentMemoryContext`
- B 线程正在 `palloc()`
- A 线程把 `CurrentResourceOwner` 改成事务 owner
- B 线程创建 DSM / buffer pin
- A 线程的 `MyLatch` 唤醒逻辑打到 B 线程

结果就是：

- 内存分配到错误上下文
- 资源记到账户错乱
- latch / signal / interrupt 投递到错误执行流
- 错误恢复跳栈跨线程失效

这是第三类失效：**backend 运行时上下文不是 TLS 化的**。

## 📄 9.5 扩展普遍依赖“static 变量 == 会话私有”

很多扩展会写这种代码：

```c
static HTAB *cache = NULL;
static int nesting_level = 0;
static ExecutorStart_hook_type prev_hook = NULL;
```

以 `auto_explain` 为例：

- `nesting_level`：`contrib/auto_explain/auto_explain.c:62`
- `current_query_sampled`：`contrib/auto_explain/auto_explain.c:65`
- `prev_ExecutorStart` 等 hook：`contrib/auto_explain/auto_explain.c:73-76`

在多进程模型中：

- 这些状态只属于当前 backend
- 用户 A 的查询不会影响用户 B

在多线程模型中：

- 同一进程内多个会话线程共享这些静态变量
- 一个线程的嵌套层数会污染另一个线程
- 一个线程采样状态会影响另一个线程
- hook 安装/卸载会产生竞态

这不是“个别扩展写得不好”，而是 PostgreSQL 扩展生态长期依赖的默认编程模型。

这是第四类失效：**扩展作者的私有状态假设被破坏**。

## 📄 9.6 错误处理模型与栈模型并不是通用线程安全设计

PostgreSQL 广泛使用 `PG_TRY/PG_CATCH`，底层依赖 `sigsetjmp/siglongjmp` 式错误恢复。

再看一个非常直接的证据：`postgres.c` 里 `restore_stack_base()` 的注释说明，PL/Java 从不同线程调用 backend 函数时，必须先修正 stack base，见 `src/backend/tcop/postgres.c:3815`。

这说明：

- 很多 backend 设施默认假设“当前执行栈就是 backend 主线程的栈”
- 线程切换后，连栈深检测都要额外修补

如果大量现有扩展在非原生线程中直接调用 backend API，就会遇到：

- stack depth 检测失真
- 错误跳转上下文不匹配
- 异常清理路径错线程

这是第五类失效：**错误处理和栈假设不是为任意线程设计的**。

## 📄 9.7 fork、信号、库初始化假设也会被破坏

PostgreSQL 很多扩展会在 `_PG_init()` 中：

- 注册 hook
- 定义 GUC
- 初始化本地缓存
- 依赖 postmaster/backend 的 fork 生命周期

但多线程化后会有新问题：

- 某些库初始化只允许进程单线程早期进行
- 某些扩展内部又依赖非线程安全第三方库
- postmaster 一旦多线程，再 `fork` 子进程会进入未定义行为区域

也就是说，扩展不仅依赖 PostgreSQL 自己的多进程模型，还常常隐式依赖“第三方库只在单线程 backend 中运行”。

这是第六类失效：**生命周期与第三方库线程安全前提被打破**。

---

## 📄 10. “失效”具体会表现成什么

把 PostgreSQL 改为多线程后，现有扩展常见故障包括：

- `CREATE EXTENSION` / `ALTER EXTENSION` 并发时对象归属错乱
- hook 类扩展互相覆盖状态
- `static` 缓存串会话
- `palloc` 到错误内存上下文，产生野指针或双重释放
- `ResourceOwner` 记账错线程，事务结束清理崩溃
- `CHECK_FOR_INTERRUPTS()` 响应到错误线程
- `MyLatch` / `MyProc` / `MyProcPort` 指向错误 backend
- `PG_TRY/PG_CATCH` 与错误栈跨线程不成立
- 使用外部非线程安全库的扩展随机崩溃
- 原本“backend 崩一个会话”的问题，变成“整个进程内多个会话一起崩”

---

## 📄 11. 如果一定要做多线程，需要改到什么程度

如果目标是真正支持“线程化 PostgreSQL + 兼容现有扩展”，那不是改 `postmaster` 一处，而是要重做运行时契约。

至少需要：

1. 把 backend 关键全局状态 TLS 化  
   如 `CurrentMemoryContext`、`CurrentResourceOwner`、`MyProc`、`MyLatch`、错误栈、中断标志。

2. 把扩展安装上下文线程化  
   `creating_extension`、`CurrentExtensionObject` 不能再是进程全局。

3. 给动态库管理和函数缓存加并发保护  
   `file_list`、`CFuncHash`、hook 链接都需要锁或 RCU 风格方案。

4. 重新定义 extension ABI  
   明确哪些 backend API 只能在“当前线程已绑定 backend context”后调用。

5. 重新审计所有 contrib / third-party 扩展  
   看它们是否使用：
   - 进程级 `static`
   - 非线程安全库
   - 假定单执行流的 hook 逻辑
   - 与错误恢复/MemoryContext 强绑定的代码

6. 最现实的方案是引入兼容层  
   为旧扩展提供“线程绑定的 backend facade”，否则现有生态几乎无法无缝兼容。

换句话说：

> 真正困难的不是把 core 改成多线程，而是把 PostgreSQL 数十年积累下来的扩展 ABI 和编程模型一起迁移到多线程语义。

---

## ✅ 12. 技术分享时可直接使用的总结

### 一句话总结

PostgreSQL 扩展机制本身非常优雅：用 control 文件描述安装元数据，用 SQL 脚本创建对象，用 fmgr + dfmgr 完成动态加载和统一调用，再用 `pg_depend` 把对象归属到扩展。

### 两句话总结

它之所以能稳定工作，是因为 PostgreSQL 给扩展提供了一个强约束运行时：每个 backend 进程独占自己的内存上下文、资源 owner、错误栈、中断状态和静态缓存。  
一旦改成多线程，这些“默认私有”的状态会变成“线程共享”，而现有扩展 ABI 没有为此设计，所以大量扩展会从语义上失效，而不仅仅是出现少量锁竞争。

### 分享时建议重点展开的 5 个点

1. `CREATE EXTENSION` 并不是“加载 so”，而是“先建 catalog 对象，再执行安装脚本”。
2. `MODULE_PATHNAME`、`PG_MODULE_MAGIC`、`PG_FUNCTION_INFO_V1` 分别解决路径替换、ABI 兼容、调用约定识别。
3. 扩展成员资格靠 `pg_depend` 的 `DEPENDENCY_EXTENSION`，不是靠文件目录归类。
4. fmgr 把所有 SQL 可调用函数统一封装成 `Datum func(FunctionCallInfo)`。
5. 多线程改造真正破坏的是 backend 私有上下文假设，而这正是现有扩展生态赖以成立的基础。

---

## 📚 13. 参考源码

- `src/backend/commands/extension.c`
- `src/backend/catalog/pg_depend.c`
- `src/backend/utils/fmgr/dfmgr.c`
- `src/backend/utils/fmgr/fmgr.c`
- `src/backend/utils/fmgr/README`
- `src/include/fmgr.h`
- `src/include/utils/palloc.h`
- `src/include/utils/resowner.h`
- `src/include/storage/proc.h`
- `src/include/miscadmin.h`
- `src/backend/postmaster/postmaster.c`
- `src/backend/tcop/postgres.c`
- `src/test/modules/test_bloomfilter/test_bloomfilter.control`
- `src/test/modules/test_bloomfilter/test_bloomfilter--1.0.sql`
- `src/test/modules/test_bloomfilter/test_bloomfilter.c`
- `contrib/auto_explain/auto_explain.c`

---

## 📄 14. 附：一个适合口头讲解的结束语

如果把 PostgreSQL 看成一个“插件系统”，很容易低估问题；但如果把它看成“建立在多进程隔离契约之上的数据库内核运行时”，就会明白：  
扩展机制之所以成功，不只是因为 `dlopen` 做得好，而是因为整个 backend 执行环境为扩展提供了稳定且私有的宿主语义。  
多线程化真正打碎的，正是这个宿主语义。
