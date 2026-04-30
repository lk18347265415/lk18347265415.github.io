# 🔐 PostgreSQL 权限系统设计逻辑与实现方案

> 📌 适用版本：PostgreSQL 14.13 / 当前 IvorySQL 代码基线  
> 👥 适用对象：数据库内核开发者、DBA、需要排查权限问题的后端工程师  
> 🎯 阅读目标：理解 PostgreSQL 权限模型的设计逻辑、核心数据结构、执行时检查链路和扩展方式
> 🧭 阅读方式：建议先看目录或总览，再进入实现细节、源码摘录和总结部分。

## 🧭 目录

- [🎯 1. 分享目标](#1-分享目标)
- [🧱 2. 权限系统的设计边界](#2-权限系统的设计边界)
- [📄 3. 用户可见模型](#3-用户可见模型)
- [🧩 4. 权限位与 ACL 数据结构](#4-权限位与-acl-数据结构)
- [🧭 5. 系统目录设计](#5-系统目录设计)
- [⚙️ 6. GRANT 与 REVOKE 的实现流程](#6-grant-与-revoke-的实现流程)
- [📄 7. 权限检查核心：aclmask](#7-权限检查核心aclmask)
- [⚙️ 8. SQL 执行路径中的权限检查](#8-sql-执行路径中的权限检查)
- [📄 9. Schema、Function 与 Sequence 的特殊点](#9-schemafunction-与-sequence-的特殊点)
- [📄 10. 行级安全 RLS](#10-行级安全-rls)
- [📄 11. 内置特权角色](#11-内置特权角色)
- [📄 12. 对象所有权、依赖与角色删除](#12-对象所有权依赖与角色删除)
- [📄 13. 从一条 SQL 看完整链路](#13-从一条-sql-看完整链路)
- [🧭 14. 实现源码地图](#14-实现源码地图)
- [⚙️ 15. 扩展新对象权限的实现方案](#15-扩展新对象权限的实现方案)
- [📄 16. 调试权限问题的方法](#16-调试权限问题的方法)
- [💡 17. 分享建议结构](#17-分享建议结构)
- [✅ 18. 总结](#18-总结)

---

<a id="1-分享目标"></a>
## 🎯 1. 分享目标

本文面向已经具备 PostgreSQL 使用经验、希望进一步理解内核权限实现的读者。目标不是罗列所有 `GRANT` 语法，而是回答三个工程问题：

- PostgreSQL 为什么把权限系统设计成“角色 + 所有者 + ACL + RLS”的组合模型？
- 一条 SQL 从解析到执行，权限检查到底发生在哪些阶段？
- 如果要调试权限问题、扩展新对象权限，应该从哪些源码入口入手？

本文基于当前仓库中的 PostgreSQL 14.13 代码线索整理。IvorySQL 在此基础上增加了部分对象类型和兼容层逻辑，例如 `PACKAGE` 相关 ACL 路径，但主干设计仍沿用 PostgreSQL 的权限框架。

核心源码定位如下：

| 主题 | 关键文件 |
| --- | --- |
| 角色属性 | `src/include/catalog/pg_authid.h` |
| 角色成员关系 | `src/include/catalog/pg_auth_members.h` |
| ACL 结构与权限位 | `src/include/utils/acl.h` |
| ACL 通用计算 | `src/backend/utils/adt/acl.c` |
| 对象权限检查与授权 | `src/backend/catalog/aclchk.c` |
| 查询权限字段 | `src/include/nodes/parsenodes.h` |
| 解析阶段权限标记 | `src/backend/parser/parse_relation.c` |
| 执行阶段权限检查 | `src/backend/executor/execMain.c` |
| 行级安全 | `src/backend/rewrite/rowsecurity.c` |
| 默认权限 | `src/include/catalog/pg_default_acl.h` |

> 快速阅读建议：如果只关心权限报错排查，优先读第 7、8、13、16 节；如果要扩展新对象权限，优先读第 5、6、14、15 节。

---

<a id="2-权限系统的设计边界"></a>
## 🧱 2. 权限系统的设计边界

PostgreSQL 的权限系统可以分为两类问题：

- “你是谁”：认证、会话用户、当前用户、角色继承关系。
- “你能做什么”：对象级权限、列级权限、默认权限、行级安全策略。

认证解决的是客户端能不能登录进来，权限系统解决的是登录之后能不能访问某个数据库对象。本文讨论的是后者。

从内核视角看，权限系统的核心目标有四个：

- 表达能力足够细：支持 database、schema、table、column、sequence、function、type 等多类对象。
- 继承模型可组合：用户可以继承多个角色的权限，减少重复授权。
- 检查路径可控：权限检查要在解析、重写、执行等阶段和 SQL 语义结合。
- 元数据可维护：对象 owner、ACL、依赖关系要支持 `DROP ROLE`、`REASSIGN OWNED`、`pg_dump` 等运维操作。

因此 PostgreSQL 没有把权限实现成单张“用户-对象-权限”关系表，而是采用：

```text
┌──────────────┐       ┌──────────────────────────┐
│  角色身份    │       │ pg_authid / pg_auth_members │
└──────────────┘       └──────────────────────────┘

┌──────────────┐       ┌──────────────────────────┐
│  对象所有者  │       │ 各对象系统目录的 owner 字段 │
└──────────────┘       └──────────────────────────┘

┌──────────────┐       ┌──────────────────────────┐
│  对象 ACL    │       │ 各对象系统目录的 aclitem[] │
└──────────────┘       └──────────────────────────┘

┌──────────────┐       ┌──────────────────────────┐
│  默认权限    │       │ pg_default_acl             │
└──────────────┘       └──────────────────────────┘

┌──────────────┐       ┌──────────────────────────┐
│  行级权限    │       │ pg_policy + rewrite 注入条件 │
└──────────────┘       └──────────────────────────┘
```

这种设计的好处是对象元数据和对象权限靠近存储，检查时可以通过系统缓存快速取到 owner 和 ACL；角色继承则集中在 `acl.c` 中处理，避免每个对象类型重复实现角色遍历。

> 关键结论：PostgreSQL 权限系统不是一个独立模块，而是系统目录、解析器、重写器、执行器、依赖管理共同构成的一条链路。

---

<a id="3-用户可见模型"></a>
## 📄 3. 用户可见模型

这一层是 DBA 和应用开发者直接接触到的权限模型。可以先记住下面这张表：

| 模型元素 | 典型 SQL | 内核落点 | 作用 |
| --- | --- | --- | --- |
| Role | `CREATE ROLE app_readonly` | `pg_authid` | 表示身份和角色属性 |
| Membership | `GRANT app_readonly TO alice` | `pg_auth_members` | 表示角色继承关系 |
| Owner | `ALTER TABLE t OWNER TO app_owner` | 对象目录 owner 字段 | 表示对象控制者 |
| Object ACL | `GRANT SELECT ON t TO alice` | 对象目录 ACL 字段 | 表示显式授权 |
| Default ACL | `ALTER DEFAULT PRIVILEGES ...` | `pg_default_acl` | 表示未来对象的默认授权 |
| RLS Policy | `CREATE POLICY ...` | `pg_policy` | 表示行级过滤规则 |

### 3.1 Role 是唯一身份抽象

PostgreSQL 中用户和角色本质上都是 role：

```sql
CREATE ROLE app_readonly;
CREATE USER alice PASSWORD '...';
GRANT app_readonly TO alice;
```

`CREATE USER` 可以理解为带 `LOGIN` 属性的 `CREATE ROLE`。角色属性存储在 `pg_authid`，成员关系存储在 `pg_auth_members`。

`pg_authid` 的关键字段包括：

```c
bool rolsuper;
bool rolinherit;
bool rolcreaterole;
bool rolcreatedb;
bool rolcanlogin;
bool rolreplication;
bool rolbypassrls;
```

含义如下：

| 字段 | 用户可见属性 | 作用 |
| --- | --- | --- |
| `rolsuper` | `SUPERUSER` | 绕过绝大多数权限检查 |
| `rolinherit` | `INHERIT` | 是否自动继承成员角色权限 |
| `rolcreaterole` | `CREATEROLE` | 是否可创建和管理角色 |
| `rolcreatedb` | `CREATEDB` | 是否可创建数据库 |
| `rolcanlogin` | `LOGIN` | 是否可登录 |
| `rolreplication` | `REPLICATION` | 是否具备复制权限 |
| `rolbypassrls` | `BYPASSRLS` | 是否绕过行级安全 |

`pg_auth_members` 表示角色成员关系：

```c
Oid roleid;        /* 被授予的角色 */
Oid member;        /* 成员角色 */
Oid grantor;       /* 授予者 */
bool admin_option; /* 是否可继续管理该成员关系 */
```

示例：

```sql
GRANT app_readonly TO alice;
```

在概念上表示 `alice` 成为 `app_readonly` 的成员。权限检查时，不只看 `alice` 被直接授予了什么，还会看 `alice` 通过角色链继承了什么。

### 3.2 对象所有者天然拥有控制权

大多数数据库对象都有 owner：

| 对象类型 | owner 字段 |
| --- | --- |
| table/view/sequence | `pg_class.relowner` |
| schema | `pg_namespace.nspowner` |
| database | `pg_database.datdba` |
| function/procedure | `pg_proc.proowner` |
| type | `pg_type.typowner` |

对象 owner 默认拥有对象上的全部可用权限，并且可以把权限授予别人。内核实现中，owner 判断并不是简单比较 `roleid == ownerId`，而是调用：

```c
has_privs_of_role(roleid, ownerId)
```

也就是说，如果当前角色通过继承链拥有 owner 角色的权限，也会被视为 owner 权限持有者。

> 注意：owner 权限不是简单地写在 ACL 数组里。即使对象 ACL 字段为 `NULL`，owner 仍然会通过 `aclmask()` 的 owner 判断获得对象权限。

### 3.3 ACL 表示显式授权

用户执行：

```sql
GRANT SELECT ON TABLE app.orders TO analyst;
```

显式授权会落到目标对象系统目录中的 ACL 字段。表、视图、序列存储在 `pg_class.relacl`；schema 存储在 `pg_namespace.nspacl`；函数存储在 `pg_proc.proacl`。

一个典型 ACL 文本可能长这样：

```text
{owner=arwdDxt/owner,analyst=r/owner}
```

其中：

- `owner=arwdDxt/owner` 表示 `owner` 拥有 insert/select/update/delete/truncate/references/trigger。
- `analyst=r/owner` 表示 `analyst` 被 `owner` 授予 `SELECT`。
- `/` 后面是 grantor。

ACL 字段为 `NULL` 不代表没有权限，而是使用该对象类型的默认 ACL。默认 ACL 由 `acldefault()` 生成。

### 3.4 PUBLIC 是隐式全体角色

`PUBLIC` 不是普通角色，而是所有角色的集合。授予 `PUBLIC` 的权限对所有用户生效：

```sql
GRANT USAGE ON SCHEMA app TO PUBLIC;
REVOKE EXECUTE ON FUNCTION dangerous_func() FROM PUBLIC;
```

内核检查 ACL 时会先考虑 `PUBLIC` 权限，再考虑当前角色和其继承角色的权限。

---

<a id="4-权限位与-acl-数据结构"></a>
## 🧩 4. 权限位与 ACL 数据结构

权限位定义在 `src/include/nodes/parsenodes.h` 和 `src/include/utils/acl.h` 中。常见权限包括：

```c
#define ACL_INSERT      (1<<0)
#define ACL_SELECT      (1<<1)
#define ACL_UPDATE      (1<<2)
#define ACL_DELETE      (1<<3)
```

权限字符定义示例：

| 权限 | ACL 字符 | 常见对象 |
| --- | --- | --- |
| `SELECT` | `r` | table、view、sequence、column |
| `INSERT` | `a` | table、column |
| `UPDATE` | `w` | table、sequence、column |
| `DELETE` | `d` | table |
| `TRUNCATE` | `D` | table |
| `REFERENCES` | `x` | table、column |
| `TRIGGER` | `t` | table |
| `EXECUTE` | `X` | function/procedure |
| `USAGE` | `U` | schema、sequence、type、language |
| `CREATE` | `C` | database、schema、tablespace |
| `CONNECT` | `c` | database |

单条 ACL item 的核心结构是：

```c
typedef struct AclItem
{
    Oid     ai_grantee;
    Oid     ai_grantor;
    AclMode ai_privs;
} AclItem;
```

`AclMode` 同时存储普通权限和 grant option：

```text
低 16 位：实际权限
高 16 位：WITH GRANT OPTION 对应权限
```

相关宏：

```c
#define ACL_GRANT_OPTION_FOR(privs) (((AclMode) (privs) & 0xFFFF) << 16)
#define ACL_OPTION_TO_PRIVS(privs)  (((AclMode) (privs) >> 16) & 0xFFFF)
```

因此：

```sql
GRANT SELECT ON t TO alice;
```

只设置低位 `ACL_SELECT`。而：

```sql
GRANT SELECT ON t TO alice WITH GRANT OPTION;
```

会同时设置高位 grant option，使 `alice` 有能力继续把 `SELECT` 授予其他角色。

<a id="5-系统目录设计"></a>
## 🧭 5. 系统目录设计

### 5.1 身份与成员关系

| 系统目录 | 作用 | 关键字段 |
| --- | --- | --- |
| `pg_authid` | 存储 role 属性 | `rolname`、`rolsuper`、`rolinherit`、`rolcanlogin` |
| `pg_auth_members` | 存储 role membership | `roleid`、`member`、`grantor`、`admin_option` |

角色成员检查的关键函数：

- `roles_is_member_of()`
- `has_privs_of_role()`
- `has_rolinherit()`

这些函数位于 `src/backend/utils/adt/acl.c`。

### 5.2 对象 ACL 字段

| 对象类型 | 系统目录 | ACL 字段 | owner 字段 |
| --- | --- | --- | --- |
| table/view/sequence | `pg_class` | `relacl` | `relowner` |
| database | `pg_database` | `datacl` | `datdba` |
| schema | `pg_namespace` | `nspacl` | `nspowner` |
| function/procedure | `pg_proc` | `proacl` | `proowner` |
| type/domain | `pg_type` | `typacl` | `typowner` |
| language | `pg_language` | `lanacl` | `lanowner` |
| tablespace | `pg_tablespace` | `spcacl` | `spcowner` |
| foreign server | `pg_foreign_server` | `srvacl` | `srvowner` |
| foreign data wrapper | `pg_foreign_data_wrapper` | `fdwacl` | `fdwowner` |

IvorySQL 扩展中还可以看到 `PACKAGE` 相关 ACL 检查路径，例如 `pg_package_aclmask()` 和 `pg_package_aclcheck()`。

### 5.3 默认权限

`ALTER DEFAULT PRIVILEGES` 使用 `pg_default_acl`：

```c
Oid     defaclrole;
Oid     defaclnamespace;
char    defaclobjtype;
aclitem defaclacl[1];
```

它只影响未来创建的对象，不会回填已有对象。

示例：

```sql
ALTER DEFAULT PRIVILEGES
FOR ROLE app_owner
IN SCHEMA app
GRANT SELECT ON TABLES TO app_readonly;
```

含义是：以后 `app_owner` 在 `app` schema 下创建表时，默认给 `app_readonly` 授予 `SELECT`。

---

<a id="6-grant-与-revoke-的实现流程"></a>
## ⚙️ 6. GRANT 与 REVOKE 的实现流程

### 6.1 GRANT 的主流程

用户执行：

```sql
GRANT SELECT, UPDATE ON TABLE app.orders TO analyst;
```

内核处理流程可以简化为：

```text
SQL parser
  -> GrantStmt
     -> ExecGrantStmt()
        -> 解析权限名为 AclMode
        -> 解析 grantee role OID
        -> 解析目标对象 OID
        -> ExecGrantStmt_oids()
           -> restrict_and_check_grant()
           -> 更新对象 ACL 字段
           -> updateAclDependencies()
```

换成数据流视角，可以理解为：

```text
权限名         grantee 名称       对象名称
  │                │              │
  ▼                ▼              ▼
AclMode        role OID        object OID
  │                │              │
  └──────────────┬─┴──────────────┘
                 ▼
        检查 grant option / owner
                 │
                 ▼
          修改对象 ACL 字段
                 │
                 ▼
        维护 ACL 与 role 的依赖
```

关键函数：

- `ExecGrantStmt()`：处理 `GRANT/REVOKE` 语句入口。
- `ExecGrantStmt_oids()`：对象已解析为 OID 后的统一处理。
- `restrict_and_check_grant()`：检查 grantor 是否有足够 grant option。
- `select_best_grantor()`：当前用户通过多个角色拥有 grant option 时，选择最合适的 grantor。
- `updateAclDependencies()`：维护 ACL 对 role 的依赖。

### 6.2 为什么需要 grant option 检查

普通权限和“继续授权的能力”是分离的：

```sql
GRANT SELECT ON t TO alice;
```

`alice` 可以查询 `t`，但不能再把 `SELECT` 授给别人。

```sql
GRANT SELECT ON t TO alice WITH GRANT OPTION;
```

`alice` 才能执行：

```sql
GRANT SELECT ON t TO bob;
```

`restrict_and_check_grant()` 的核心职责就是确保授权者确实拥有对应权限的 grant option，或者是对象 owner/superuser。

### 6.3 REVOKE 与级联撤销

`REVOKE` 的复杂点在于 grant option 可能形成授权链：

```text
owner -> alice WITH GRANT OPTION
alice -> bob
bob   -> carol
```

当 owner 撤销 alice 的 grant option 时，bob 和 carol 的权限是否还合法，取决于他们是否还有其他授权路径。如果没有，就需要递归撤销。

这部分逻辑在 `src/backend/utils/adt/acl.c` 的 `recursive_revoke()` 中实现。

`REVOKE ... CASCADE` 与 `REVOKE ... RESTRICT` 的语义也依赖这套授权链分析：

- `CASCADE`：允许连带撤销依赖该授权链的后续权限。
- `RESTRICT`：如果存在依赖该授权的后续权限，则报错。

> 关键结论：`GRANT/REVOKE` 不只是更新一段 ACL 文本，它还必须检查授权能力、维护授权链，并更新 ACL 对 role 的依赖关系。

---

<a id="7-权限检查核心aclmask"></a>
## 📄 7. 权限检查核心：aclmask

最重要的底层函数是：

```c
AclMode
aclmask(const Acl *acl, Oid roleid, Oid ownerId,
        AclMode mask, AclMaskHow how)
```

参数含义：

| 参数 | 含义 |
| --- | --- |
| `acl` | 对象 ACL 数组 |
| `roleid` | 要检查的角色 |
| `ownerId` | 对象 owner |
| `mask` | 希望检查的权限位 |
| `how` | 要求任意权限还是全部权限 |

`AclMaskHow` 常见模式：

```text
ACLMASK_ANY：只要拥有 mask 中任意一个权限即可
ACLMASK_ALL：必须拥有 mask 中全部权限
```

`aclmask()` 的逻辑可以理解为：

```text
输入：acl、roleid、ownerId、mask、how
  │
  ▼
是否拥有 owner 权限？
  ├─ 是：返回 owner 默认拥有的权限
  └─ 否：
      │
      ▼
   合并 PUBLIC 权限
      │
      ▼
   合并直接授予 roleid 的权限
      │
      ▼
   展开角色继承链，合并成员角色权限
      │
      ▼
   按 ACLMASK_ANY / ACLMASK_ALL 判断结果
```

对象类型不会直接暴露 `aclmask()`，而是封装为对象专用函数：

```c
pg_class_aclmask()
pg_database_aclmask()
pg_proc_aclmask()
pg_namespace_aclmask()
pg_tablespace_aclmask()
pg_foreign_server_aclmask()
pg_type_aclmask()
```

然后再封装为更易用的 check 函数：

```c
pg_class_aclcheck()
pg_database_aclcheck()
pg_proc_aclcheck()
pg_namespace_aclcheck()
pg_type_aclcheck()
```

`*_aclcheck()` 通常只返回：

```text
ACLCHECK_OK
ACLCHECK_NO_PRIV
```

而 `*_aclmask()` 返回实际拥有的权限位，适合需要进一步判断的场景。

> 调试建议：权限检查结果异常时，优先确认 `roleid`、`ownerId`、对象 ACL 和角色继承链。大多数问题都能在这四个输入里定位。

---

<a id="8-sql-执行路径中的权限检查"></a>
## ⚙️ 8. SQL 执行路径中的权限检查

### 8.1 RangeTblEntry 中的权限信息

SQL 解析后，每个参与查询的关系会形成 `RangeTblEntry`，其中包含权限检查字段：

```c
AclMode     requiredPerms;
Oid         checkAsUser;
Bitmapset  *selectedCols;
Bitmapset  *insertedCols;
Bitmapset  *updatedCols;
```

含义：

| 字段 | 作用 |
| --- | --- |
| `requiredPerms` | 表级需要的权限位 |
| `checkAsUser` | 以哪个用户身份检查，视图/规则场景会用到 |
| `selectedCols` | 需要 `SELECT` 权限的列 |
| `insertedCols` | 需要 `INSERT` 权限的列 |
| `updatedCols` | 需要 `UPDATE` 权限的列 |

整体链路如下：

```text
SQL 文本
  │
  ▼
Parser / Analyzer
  │  标记 requiredPerms、selectedCols、insertedCols、updatedCols
  ▼
Rewrite
  │  处理视图 checkAsUser，注入 RLS policy
  ▼
Planner
  │  基于改写后的 Query 生成计划
  ▼
Executor
  │  ExecCheckRTEPerms()
  ▼
ACL 检查通过后执行计划
```

### 8.2 SELECT 权限检查

示例：

```sql
SELECT id, name FROM app.users WHERE status = 'active';
```

解析阶段会标记：

```text
requiredPerms 包含 ACL_SELECT
selectedCols 包含 id、name、status
```

即使 `status` 不在输出列中，只要它出现在 `WHERE` 条件里，也需要 `SELECT` 权限。

执行阶段会调用 `ExecCheckRTEPerms()`：

```text
ExecCheckRTEPerms()
  -> pg_class_aclmask(relOid, userid, requiredPerms, ACLMASK_ALL)
  -> 如果表级权限不足，继续检查列级权限
  -> pg_attribute_aclcheck_all() / pg_attribute_aclcheck()
```

因此 PostgreSQL 支持列级授权：

```sql
GRANT SELECT (id, name) ON app.users TO analyst;
```

此时：

```sql
SELECT id, name FROM app.users;
```

可以通过，但：

```sql
SELECT password_hash FROM app.users;
```

会失败。

### 8.3 INSERT、UPDATE、DELETE 的细节

`INSERT`：

```sql
INSERT INTO app.users(id, name) VALUES (1, 'alice');
```

需要目标表或目标列上的 `INSERT` 权限。

`UPDATE`：

```sql
UPDATE app.users SET name = 'bob' WHERE id = 1;
```

需要：

- `name` 列的 `UPDATE` 权限。
- `id` 列的 `SELECT` 权限，因为 `WHERE` 读取了它。

`DELETE`：

```sql
DELETE FROM app.users WHERE id = 1;
```

需要：

- 表级 `DELETE` 权限。
- `id` 列的 `SELECT` 权限，因为 `WHERE` 读取了它。

这个设计体现了 PostgreSQL 的权限语义：修改某行和读取某列是两个动作，不能因为用户能更新某列就自动允许读取任意条件列。

### 8.4 视图场景中的 checkAsUser

视图会引入一个重要问题：访问底层表时应该检查调用者权限，还是视图 owner 权限？

PostgreSQL 默认视图行为类似 owner 权限模型。查询视图时，用户需要有视图上的权限；视图展开访问底层表时，通常以视图 owner 身份检查底层对象权限。这个身份通过 `RangeTblEntry.checkAsUser` 表达。

重写阶段会调整 RTE 的权限字段，使权限检查符合视图语义。

---

<a id="9-schemafunction-与-sequence-的特殊点"></a>
## 📄 9. Schema、Function 与 Sequence 的特殊点

### 9.1 Schema 权限

Schema 常见权限：

| 权限 | 含义 |
| --- | --- |
| `USAGE` | 允许解析 schema 内对象名 |
| `CREATE` | 允许在 schema 中创建对象 |

典型授权：

```sql
GRANT USAGE ON SCHEMA app TO app_user;
GRANT CREATE ON SCHEMA app TO app_owner;
```

容易踩的坑是：即使用户拥有表上的 `SELECT`，如果没有 schema 的 `USAGE`，对象名解析也可能失败。

### 9.2 Function 权限

函数权限主要是 `EXECUTE`。很多函数默认对 `PUBLIC` 有执行权限，因此安全敏感函数通常需要显式收紧：

```sql
REVOKE EXECUTE ON FUNCTION dangerous_func() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION dangerous_func() TO app_admin;
```

`SECURITY DEFINER` 函数要额外关注 `search_path`。否则攻击者可能通过同名对象劫持函数执行路径。

### 9.3 Sequence 权限

Sequence 常见权限：

| 权限 | 典型影响 |
| --- | --- |
| `USAGE` | 允许 `nextval()`、`currval()` |
| `SELECT` | 允许读取序列状态 |
| `UPDATE` | 允许 `setval()` |

表使用 `serial` 或 identity column 时，插入表通常还需要关联 sequence 的 `USAGE` 权限。

---

<a id="10-行级安全-rls"></a>
## 📄 10. 行级安全 RLS

ACL 决定“能不能访问这个对象”，RLS 决定“能访问对象中的哪些行”。

示例：

```sql
ALTER TABLE orders ENABLE ROW LEVEL SECURITY;

CREATE POLICY tenant_isolation ON orders
USING (tenant_id = current_setting('app.tenant_id')::int);
```

即使用户拥有：

```sql
GRANT SELECT ON orders TO app_user;
```

查询时也只能看到 policy 允许的行。

RLS 的主要处理入口在 `src/backend/rewrite/rowsecurity.c`：

```text
get_row_security_policies()
  -> check_enable_rls()
  -> 收集 permissive / restrictive policies
  -> 生成 securityQuals 和 withCheckOptions
  -> 注入 Query tree
```

绕过 RLS 的情况包括：

- 超级用户。
- 拥有 `BYPASSRLS` 的角色。
- 特定情况下的表 owner。
- 表被设置为不启用 RLS。

RLS 在 rewrite 阶段注入条件，因此它不是简单的 executor 末端过滤，而是参与后续优化和执行计划生成。

> 关键结论：ACL 通过不等于最终能看到数据。ACL 是对象入口权限，RLS 是行级可见性和可修改性约束。

---

<a id="11-内置特权角色"></a>
## 📄 11. 内置特权角色

PostgreSQL 14 引入或保留了一批预定义角色，例如：

- `pg_read_all_data`
- `pg_write_all_data`
- `pg_monitor`
- `pg_read_all_settings`
- `pg_read_all_stats`
- `pg_read_server_files`
- `pg_write_server_files`
- `pg_execute_server_program`
- `pg_signal_backend`

这些角色不是简单地给所有对象写入 ACL，而是在权限检查逻辑中有特殊处理。例如 `pg_class_aclmask()` 会检查当前角色是否属于 `pg_read_all_data` 或 `pg_write_all_data`，并据此补充权限位。

这种设计避免在每个对象 ACL 中写入大量重复授权，同时保留了“授予一个角色即可获得全局能力”的运维体验。

---

<a id="12-对象所有权依赖与角色删除"></a>
## 📄 12. 对象所有权、依赖与角色删除

权限系统不仅要处理“能不能访问”，还要处理“元数据是否可维护”。

创建对象时，系统会记录 owner 依赖：

```text
recordDependencyOnOwner()
```

修改 owner 时，系统会更新依赖：

```text
changeDependencyOnOwner()
```

删除角色时，如果该角色仍拥有对象或仍出现在 ACL 中，系统需要阻止或清理。相关逻辑会涉及：

- `pg_shdepend`
- `RemoveRoleFromObjectACL()`
- `REASSIGN OWNED`
- `DROP OWNED`

典型运维流程：

```sql
REASSIGN OWNED BY old_user TO new_owner;
DROP OWNED BY old_user;
DROP ROLE old_user;
```

这解释了为什么 PostgreSQL 不能只把 ACL 当成普通文本数组处理。ACL 中的 grantee/grantor 都可能成为 role 依赖，需要和系统依赖机制联动。

---

<a id="13-从一条-sql-看完整链路"></a>
## 📄 13. 从一条 SQL 看完整链路

示例准备：

```sql
CREATE ROLE app_readonly;
CREATE ROLE alice LOGIN;
GRANT app_readonly TO alice;

CREATE SCHEMA app;
CREATE TABLE app.users (
    id int,
    name text,
    password_hash text
);

GRANT USAGE ON SCHEMA app TO app_readonly;
GRANT SELECT (id, name) ON app.users TO app_readonly;
```

执行：

```sql
SET ROLE alice;
SELECT id, name FROM app.users;
```

内部链路：

| 步骤 | 内核动作 | 关键检查 |
| --- | --- | --- |
| 1 | 当前用户/角色为 `alice` | 会话身份和当前角色 |
| 2 | 名称解析 `app.users` | schema `USAGE` |
| 3 | 检查 schema 权限 | `pg_namespace_aclcheck(app, alice, ACL_USAGE)` |
| 4 | 展开角色继承链 | `has_privs_of_role(alice, app_readonly)` |
| 5 | parser 构造 `RangeTblEntry` | 记录目标关系 |
| 6 | 标记表级权限 | `requiredPerms = ACL_SELECT` |
| 7 | 标记列级权限 | `selectedCols = {id, name}` |
| 8 | executor 执行前检查 | `ExecCheckRTEPerms()` |
| 9 | 表级不足时检查列级权限 | `pg_attribute_aclcheck()` |
| 10 | `id`、`name` 权限满足 | 查询通过 |

如果执行：

```sql
SELECT password_hash FROM app.users;
```

则 `selectedCols` 包含 `password_hash`，列级 `SELECT` 不满足，最终报 `permission denied`。

> 示例要点：权限检查不是只看 SQL 的输出列，`WHERE`、`JOIN`、表达式、默认值和触发器等路径中读取的列也可能引入额外权限需求。

---

<a id="14-实现源码地图"></a>
## 🧭 14. 实现源码地图

### 14.1 创建和修改角色

| 功能 | 源码入口 |
| --- | --- |
| `CREATE ROLE/USER` | `src/backend/commands/user.c::CreateRole()` |
| `ALTER ROLE` | `src/backend/commands/user.c::AlterRole()` |
| `DROP ROLE` | `src/backend/commands/user.c::DropRole()` |
| `GRANT role TO role` | `src/backend/commands/user.c::GrantRole()` |
| 添加成员关系 | `src/backend/commands/user.c::AddRoleMems()` |
| 删除成员关系 | `src/backend/commands/user.c::DelRoleMems()` |

### 14.2 ACL 修改

| 功能 | 源码入口 |
| --- | --- |
| `GRANT/REVOKE` | `src/backend/catalog/aclchk.c::ExecGrantStmt()` |
| 对象 OID 级处理 | `src/backend/catalog/aclchk.c::ExecGrantStmt_oids()` |
| 授权能力检查 | `src/backend/catalog/aclchk.c::restrict_and_check_grant()` |
| 默认权限 | `src/backend/catalog/aclchk.c::SetDefaultACL()` |
| ACL 依赖更新 | `src/backend/catalog/aclchk.c::updateAclDependencies()` |

### 14.3 ACL 计算与检查

| 功能 | 源码入口 |
| --- | --- |
| 通用 ACL 计算 | `src/backend/utils/adt/acl.c::aclmask()` |
| 角色继承展开 | `src/backend/utils/adt/acl.c::roles_is_member_of()` |
| 是否拥有角色权限 | `src/backend/utils/adt/acl.c::has_privs_of_role()` |
| 表权限计算 | `src/backend/catalog/aclchk.c::pg_class_aclmask()` |
| schema 权限计算 | `src/backend/catalog/aclchk.c::pg_namespace_aclmask()` |
| 函数权限计算 | `src/backend/catalog/aclchk.c::pg_proc_aclmask()` |

### 14.4 查询执行权限

| 功能 | 源码入口 |
| --- | --- |
| RTE 权限字段定义 | `src/include/nodes/parsenodes.h::RangeTblEntry` |
| 关系引用标记 SELECT | `src/backend/parser/parse_relation.c` |
| 目标表权限标记 | `src/backend/parser/parse_clause.c`、`src/backend/parser/analyze.c` |
| 执行前权限检查 | `src/backend/executor/execMain.c::ExecCheckRTEPerms()` |
| 修改列权限检查 | `src/backend/executor/execMain.c::ExecCheckRTEPermsModified()` |

### 14.5 RLS

| 功能 | 源码入口 |
| --- | --- |
| RLS 主入口 | `src/backend/rewrite/rowsecurity.c::get_row_security_policies()` |
| 是否启用 RLS | `src/backend/rewrite/rowsecurity.c::check_enable_rls()` |
| policy 命令匹配 | `src/backend/rewrite/rowsecurity.c` |

---

<a id="15-扩展新对象权限的实现方案"></a>
## ⚙️ 15. 扩展新对象权限的实现方案

如果要为一种新的数据库对象接入 PostgreSQL 权限体系，通常需要完成以下工作。

扩展工作可以先按下面的实施清单拆分：

| 阶段 | 必做事项 | 主要风险 |
| --- | --- | --- |
| 系统目录 | 增加 owner 字段和 `aclitem[]` 字段 | 元数据缺失导致无法授权或无法清理依赖 |
| 默认 ACL | 在 `acldefault()` 中定义默认权限 | 默认开放过大或破坏兼容语义 |
| GRANT/REVOKE | 接入 `aclchk.c` 的对象分发逻辑 | 授权语法可用但实际 ACL 更新不完整 |
| 检查 API | 增加 `pg_xxx_aclmask()` 和 `pg_xxx_aclcheck()` | 各调用点重复实现检查逻辑 |
| 执行路径 | parser/rewrite/executor 或 DDL 命令入口调用检查 | 只在部分路径检查，留下绕过入口 |
| 测试 | 覆盖 owner、role inheritance、PUBLIC、grant option、drop role | 回归测试无法覆盖权限链路边界 |

### 15.1 系统目录层

对象系统目录需要包含：

```text
owner 字段
aclitem[] ACL 字段
```

例如：

```c
Oid     objowner;
aclitem objacl[1] BKI_DEFAULT(_null_);
```

还需要在对象创建时记录 owner 依赖：

```c
recordDependencyOnOwner(classId, objectId, ownerId);
```

修改 owner 时调用：

```c
changeDependencyOnOwner(classId, objectId, newOwnerId);
```

### 15.2 ACL 默认值

在 `acldefault()` 中定义新对象类型默认权限。需要回答：

- owner 默认拥有哪些权限？
- `PUBLIC` 默认是否有权限？
- 是否需要兼容 SQL 标准或 PostgreSQL 既有对象语义？

例如函数默认可被 `PUBLIC EXECUTE`，而表默认不对 `PUBLIC` 开放读写。

### 15.3 GRANT/REVOKE 支持

需要在 `aclchk.c` 中接入：

- 对象类型到权限集合的映射。
- 对象名称解析到 OID。
- ACL 字段读取与更新。
- 错误消息和对象描述。
- `pg_aclmask()` 分发。

如果对象支持：

```sql
GRANT USAGE ON NEW_OBJECT ...
```

就要定义 `USAGE` 是否有效、`ALL PRIVILEGES` 包含哪些位，以及不合法权限如何报错。

### 15.4 权限检查 API

通常新增：

```c
pg_newobject_aclmask()
pg_newobject_aclcheck()
```

其中 `pg_newobject_aclmask()` 负责：

```text
1. 读取对象 tuple。
2. 取 owner 和 ACL 字段。
3. ACL 为 NULL 时调用 acldefault()。
4. 调用 aclmask()。
5. 处理内置特权角色或特殊语义。
```

`pg_newobject_aclcheck()` 通常包装成：

```text
如果 aclmask(..., ACLMASK_ANY) 非零，则 ACLCHECK_OK，否则 ACLCHECK_NO_PRIV
```

### 15.5 SQL 执行路径接入

如果新对象参与查询执行，需要考虑：

- parser 是否需要在 AST/RTE 中记录 required permissions。
- rewrite 是否会改变检查身份。
- executor 何时调用 `*_aclcheck()`。
- `information_schema` 或系统视图是否需要过滤不可见对象。

如果新对象只是 DDL 对象，则可能只需要在命令入口处显式检查权限。

### 15.6 回归测试

建议覆盖：

- owner 默认权限。
- 普通用户无权限访问。
- 直接授权。
- 通过角色继承授权。
- `PUBLIC` 授权。
- `WITH GRANT OPTION`。
- `REVOKE CASCADE/RESTRICT`。
- `ALTER DEFAULT PRIVILEGES`，如果对象支持默认权限。
- `DROP ROLE` 时 ACL 依赖清理。
- dump/restore 后权限保持。

---

<a id="16-调试权限问题的方法"></a>
## 📄 16. 调试权限问题的方法

### 16.1 从 SQL 侧观察

查看当前身份：

```sql
SELECT current_user, session_user;
SELECT current_role;
```

查看角色继承：

```sql
SELECT
    r.rolname AS role,
    m.rolname AS member,
    am.admin_option
FROM pg_auth_members am
JOIN pg_roles r ON r.oid = am.roleid
JOIN pg_roles m ON m.oid = am.member;
```

查看对象 ACL：

```sql
SELECT relname, relacl
FROM pg_class
WHERE relname = 'users';
```

使用内置函数判断权限：

```sql
SELECT has_table_privilege('alice', 'app.users', 'SELECT');
SELECT has_column_privilege('alice', 'app.users', 'password_hash', 'SELECT');
SELECT has_schema_privilege('alice', 'app', 'USAGE');
```

### 16.2 从源码侧定位

如果是表访问报错，优先看：

```text
ExecCheckRTEPerms()
pg_class_aclmask()
pg_attribute_aclcheck()
aclmask()
has_privs_of_role()
```

如果是 `GRANT/REVOKE` 报错，优先看：

```text
ExecGrantStmt()
restrict_and_check_grant()
select_best_grantor()
recursive_revoke()
```

如果是 RLS 行过滤异常，优先看：

```text
get_row_security_policies()
check_enable_rls()
```

### 16.3 排查顺序

实际排查时建议按下面顺序收敛问题：

| 顺序 | 排查点 | 常用方式 |
| --- | --- | --- |
| 1 | 当前身份是否符合预期 | `current_user`、`session_user`、`current_role` |
| 2 | 角色继承是否符合预期 | 查 `pg_auth_members` / `pg_roles` |
| 3 | schema 是否可解析 | `has_schema_privilege(..., 'USAGE')` |
| 4 | 对象级权限是否具备 | `has_table_privilege()`、`has_function_privilege()` |
| 5 | 列级权限是否具备 | `has_column_privilege()` |
| 6 | 是否被 RLS 过滤 | 检查 `pg_policy` 和 `row_security` |
| 7 | 是否涉及视图或 SECURITY DEFINER | 检查 owner、`checkAsUser`、`search_path` |
| 8 | 是否是默认权限误解 | 检查 `pg_default_acl` 和对象创建者 |

### 16.4 常见误判

| 现象 | 常见原因 |
| --- | --- |
| 表已授权但仍无法访问 | 缺少 schema `USAGE` |
| 能访问视图但不能访问底表 | 视图权限和底表权限检查身份不同 |
| `UPDATE` 报缺 `SELECT` | `WHERE` 或表达式读取了未授权列 |
| 新表没有预期授权 | `ALTER DEFAULT PRIVILEGES` 只影响未来对象，且按创建者 role 匹配 |
| RLS 开启后少数据 | ACL 通过后又被 policy 过滤 |
| 函数可被所有人执行 | 函数默认可能对 `PUBLIC` 有 `EXECUTE` |

---

<a id="17-分享建议结构"></a>
## 💡 17. 分享建议结构

如果将本文拆成一次 45 分钟技术分享，可以按下面节奏：

| 时间 | 内容 |
| --- | --- |
| 5 分钟 | 权限系统解决什么问题，为什么是 role + owner + ACL |
| 8 分钟 | 系统目录与 ACL 数据结构 |
| 8 分钟 | `GRANT/REVOKE` 如何修改 ACL |
| 10 分钟 | 查询执行中的权限检查链路 |
| 6 分钟 | RLS、默认权限、内置特权角色 |
| 5 分钟 | 扩展新对象权限的方案 |
| 3 分钟 | 调试方法和常见坑 |

推荐用两个贯穿示例：

- `app_readonly` 通过列级授权访问 `app.users(id, name)`。
- `orders` 表开启 RLS 后，ACL 允许访问但行被 policy 过滤。

<a id="18-总结"></a>
## ✅ 18. 总结

PostgreSQL 权限系统的设计不是单点判断，而是一套贯穿系统目录、解析器、重写器、执行器和依赖管理的框架。

可以用一句话概括：

```text
角色系统决定“当前身份继承了谁的能力”，owner 和 ACL 决定“对象级/列级能做什么”，RTE 把 SQL 语义转换为待检查权限，aclmask() 负责计算最终权限，RLS 在对象权限通过后继续约束可见行。
```

理解这条链路后，调试权限问题通常就能从“SQL 报 permission denied”快速收敛到具体层次：

- 身份层：当前用户、当前角色、角色继承是否正确。
- 命名层：schema `USAGE` 是否具备。
- 对象层：表/函数/sequence ACL 是否具备。
- 列级层：表达式读取或修改的列是否具备权限。
- 行级层：RLS policy 是否过滤了数据。
- 依赖层：role 删除、owner 变更、默认权限是否正确维护。

这也是 PostgreSQL 权限系统能够长期支撑复杂数据库场景的关键：用户可见模型相对简洁，但内核实现把身份继承、对象元数据、执行语义和依赖管理分层组合起来，每一层都有明确职责。
