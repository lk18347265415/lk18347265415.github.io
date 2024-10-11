---
layout:	post
title:	"postgres源码解析(--boot)"
date:	2021-07-14 15:58:00 +0800
categories:	[postgres]
---

> postgres引导模式

在intdb源码解析中我们知道template1模板的生成是在postgres的引导模式中生成的，即在管道中执行了postgres --boot -x1 -X 16777216 -F，然后向管道中写入postgres.bki文件中的内容（引导模式下服务器会把换行符当成命令输入的终止符），最后生成了template1模板。今天我们分析postgres引导模式(--boot)的代码。

```c
//postgres服务入口函数
main(int argc,char* argv[])
{
    ...;//省略代码见postgres源码解析（main）
    if (argc > 1 && strcmp(argv[1], "--boot") == 0)
		AuxiliaryProcessMain(argc, argv);	/* does not return */
}

/* 辅助进程的主要入口点，比如bgwriter,walwriter,walreceiver,bootrapper和共享内存检查代码*/
void
AuxiliaryProcessMain(int argc, char *argv[])
{
    if (!IsUnderPostmaster)//如果是在postmaster子进程中，则IsUnderPostmaster为true，表明运行在多用户模式。
		InitStandaloneProcess(argv[0]);//为可执行进程初始化基本的环境信息
    
    if (!IsUnderPostmaster)//在InitPostmasterChild中将IsUnderPostmaster置为true，所以initdb时为false
		InitializeGUCOptions();//初始化GUC参数
    
    /* 忽略initial的--boot选项 */
    if (argc > 1 && strcmp(argv[1], "--boot") == 0)
	{
		argv++;
		argc--;
	}
    /* 如果没有-x选项，默认辅助进程类型为CheckerProcess */
    MyAuxProcType = CheckerProcess;
    
    while ((flag = getopt(argc, argv, "B:c:d:D:Fkr:x:X:-:")) != -1)//解析命令行参数
    {
        switch(flag)
        {//以下只列出了重要的一些选项
            case 'B':
                SetConfigOption("shared_buffers", optarg, PGC_POSTMASTER, PGC_S_ARGV);
                break;
        	case 'F':
                SetConfigOption("fsync", "false", PGC_POSTMASTER, PGC_S_ARGV);
                break;
            case 'x':
                MyAuxProcType = atoi(optarg);
                break;
        	case 'X':
                {
                    int			WalSegSz = strtoul(optarg, NULL, 0);
                    SetConfigOption("wal_segment_size", optarg, PGC_INTERNAL,PGC_S_OVERRIDE);
                }
        		break;
        }
    }
    /* 选择辅助进程的类型（根据参数-x后面的数字来决定类型） */
    switch (MyAuxProcType)
	{
		case StartupProcess:
			MyBackendType = B_STARTUP;
			break;
		case BgWriterProcess:
			MyBackendType = B_BG_WRITER;
			break;
		case CheckpointerProcess:
			MyBackendType = B_CHECKPOINTER;
			break;
		case WalWriterProcess:
			MyBackendType = B_WAL_WRITER;
			break;
		case WalReceiverProcess:
			MyBackendType = B_WAL_RECEIVER;
			break;
		default:
			MyBackendType = B_INVALID;
	}
    /* 获取配置参数，除非从postmaster继承 */
    if (!IsUnderPostmaster)
    {
        if (!SelectConfigFiles(userDoption, progname))
            proc_exit(1);
    }
    /* 验证datadir的存在并切换进datadir目录（如果在postmaster下，已经完成该步骤）*/
    if (!IsUnderPostmaster)
	{
		checkDataDir();
		ChangeToDataDir();
	}
    /* 为datadir创建锁文件postmaster.pid*/
    if (!IsUnderPostmaster)
		CreateDataDirLockFile(false);
    /* 设置全局变量mode为BootstrapProcessing */
    SetProcessingMode(BootstrapProcessing);
    IgnoreSystemIndexes = true;
    
    /* 初始化MaxBackends数 */
    if (!IsUnderPostmaster)
		InitializeMaxBackends();
    
    BaseInit();//backend初始化
    {
        InitCommunication();//创建共享内存和信号量
        DebugFileOpen();//初始化错误信息输出文件(-r选项指定)
        InitFileAccess();//初始化vfdCache
        InitSync();//如果需要（不在postmaster之下或者启动了checkpointer时）创建pending-operation hashtable
        smgrinit();//初始化storage  manager（mdinit）
        InitBufferPoolAccess();//初始化对共享内存的访问数PrivateRefCount 100
    }
    
    if (IsUnderPostmaster)//当是一个辅助进程的时候，我们不需要处理InitPostgres的所有步骤
    {
        #ifndef EXEC_BACKEND
			InitAuxiliaryProcess();
		#endif
        ProcSignalInit(MaxBackends + MyAuxProcType + 1);//为辅助进程分配ProcSignalSlot
        InitBufferPoolBackend();//完成设置buffer清理工作
        CreateAuxProcessResourceOwner();//为当前进程创建一个AuxProcessResourceOwner
        pgstat_initialize();//初始化pgstats状态，并设置我的的on-proc-exit钩子
        pgstat_bestart();//在PgBackendStatus数组中初始化此后端的条目
        before_shmem_exit(ShutdownAuxiliaryProcess, 0);//为lwlock清理注册一个关闭前的回调函数
    }
    SetProcessingMode(NormalProcessing);//将Mode设置为NormalProcessing
    switch (MyAuxProcType)
    {
           case CheckerProcess://-x0
            	CheckerModeMain();//只做退出处理
				proc_exit(1);		/* should never return */
           case BootstrapProcess://-x1
           		SetProcessingMode(BootstrapProcessing);
            	bootstrap_signals();//为bootrap进程设置信号处理函数
            	BootStrapXLOG();//创建并写入信息到global/pg_control和初始化XLOG segment
            	BootstrapModeMain();//引导模式用于初始化template数据库模板
            	proc_exit(1);
           case StartupProcess:
            	StartupProcessMain();//pg启动时调用该函数执行数据库恢复操作
            	proc_exit(1);
           case BgWriterProcess:
            	BackgroundWriterMain();//启动后台写进程
            	proc_exit(1);
           case CheckpointerProcess:
            	CheckpointerMain();//启动checkpointer进程
            	proc_exit(1);
           case WalWriterProcess:
            	InitXLOGAccess();
            	WalWriterMain();
           		proc_exit(1);
           case WalReceiverProcess:
            	WalReceiverMain();
            	proc_exit(1);
           default:
            	elog(PANIC, "unrecognized process type: %d", (int) MyAuxProcType);
            	proc_exit(1);
    }
}

/* 引导模式用于初始化template数据库模板 */
static void
BootstrapModeMain(void)
{
    InitProcess();//为此后端初始化每个进程的数据结构MyProc全局进程链表
    
    InitPostgres(NULL, InvalidOid, NULL, InvalidOid, NULL, false);

    for (i = 0; i < MAXATTR; i++)//初始化用于引导文件处理的东西，MAXATTR为关系表中支持的最大列为40
	{
		attrtypes[i] = NULL;
		Nulls[i] = false;
	}
    /* 处理引导程序的输入 */
    StartTransactionCommand();
	boot_yyparse();//解析管道传入的cmd命令（来自postgres.bki文件）
	CommitTransactionCommand();
                    
    RelationMapFinishBootstrap();//booststrap完成将初始化关系映射写入pg_filenode.map
}

void
InitPostgres(const char *in_dbname, Oid dboid, const char *username,
			 Oid useroid, char *out_dbname, bool override_allow_connections)
{
    InitProcessPhase2();//添加Myproc到ProcArry中
    
    /*设置MyBackendId,一个唯一的后端标识符*/
    MyBackendId = InvalidBackendId;
    SharedInvalBackendInit(false);
    
    ProcSignalInit(MyBackendId);//已经设置好了MyBackendId,现在将其加入ProcSignal中
    
    InitBufferPoolBackend();//注册回调函数AtProcExit_Buffers
    if (IsUnderPostmaster)
    {
        (void) RecoveryInProgress();
    }else{
        CreateAuxProcessResourceOwner();//设置AuxProcessResourceOwner所有者为AuxiliaryProcess
        StartupXLOG();//检查目录pg_wal和该目录下的archive_status
        ReleaseAuxProcessResources(true);
        CurrentResourceOwner = NULL;
        on_shmem_exit(ShutdownXLOG, 0);//注册ShutdownXLOG回调函数
    }
    RelationCacheInitialize();//初始化relcache
    InitCatalogCache();//对syscache做初始化
    InitPlanCache();//注册了8个callback函数
    
    EnablePortalManager();//初始化portal管理器，创建了一个portal hash的hash表
    RelationCacheInitializePhase2();//为共享系统表加载relcache条目，加载relcache文件：pg_internal.init
    
    before_shmem_exit(ShutdownPostgres, 0);//设置进程对出回调函数进行关机前清理
    if (bootstrap || IsAutoVacuumWorkerProcess())
	{
		InitializeSessionUserIdStandalone();//设置sessionUserId为BOOTSTRAP_SUPERUSERID（10）
		am_superuser = true;
	}
    if (bootstrap)
	{
		MyDatabaseId = TemplateDbOid;//TemplateDbOid为1
		MyDatabaseTableSpace = DEFAULTTABLESPACE_OID;//1663
	}
    MyProc->databaseId = MyDatabaseId;
    InvalidateCatalogSnapshot();//CatalogSnapshot为空，不做任何处理
    /* 现在我们可以安全访问database director了,base/1 */
    fullpath = GetDatabasePath(MyDatabaseId, MyDatabaseTableSpace);//fullpath为base/1
    SetDatabasePath(fullpath);//设置全局变量DatabasePath为base/1
    RelationCacheInitializePhase3();//第三阶段初始化relcache，pg_class、pg_attribute、pg_proc、pg_type
    initialize_acl();//bootstrap阶段不处理
    process_settings(MyDatabaseId, GetSessionUserId());//从pg_db_role_setting表加载GUC集
    InitializeSearchPath();//设置baseSearchPath链表、baseCreationNamespace、namespaceUser等
    InitializeClientEncoding();//初始化客户端编码
    InitializeSession();//初始化去全局变量CurrentSession  
}
```

> 总结 

1. 当initdb向管道中传入postgres.bki中的数据时，在bootstrap模式下会在**boot_yyparse()**处接收到管道中传入的数据，然后经bootscanner.l和bootparse.y词法语法的解析postgres.bki中所有命令。

2. 其中postgres.bki的生成格式命令为以下方式：genbki.pl Catalog.pm pg_xxx1.h pg_xxx2.h, …, pg_xxxN.h, pg_ext.h -I $(postgres_base_dir)/src/include/backend/catalog –set-version=13.0

3. 引导模式主要的任务是创建template1模板，那么template1是怎么创建的?在postgres.bki文件中记录了向表pg_database插入了template1数据：

   ```sql
   --postgres.bki
   ...
   open pg_database
   insert ( 1 template1 10 ENCODING LC_COLLATE LC_CTYPE t t -1 0 0 1 1663 _null_ )
   close pg_database
   ...
   ```

4. 系统表中BKI_BOOTSTRAP参数，在生成postgres.bki文件后为bootstrap，该参数的作用？

   在bootparse.y中我们可以看到创建系统表使用了heap_create和heap_create_with_catalog，其中带**bootstrap**参数的系统表使用heap_create函数，如果声明了bootstrap，那么该表将只在磁盘上创建；不会向pg_class、pg_attribute等表里面输入任何与该表相关的东西 ，如果create系统表时没有bootstrap参数，则仅会创建包含堆表本身的表，不会自动创建包含相关的系统目录创建的表。且在postgres.bki文件中，带**bootstrap**的表创建后可以直接insert，而没有**bootstrap**参数的表需要打开表再插入数据。其中postgreSQL中pg_proc、pg_type、pg_attribute和pg_class都是boostrap表。

