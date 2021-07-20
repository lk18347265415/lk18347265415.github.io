---
layout:	post
title:	"postgres源码解析(--single)"
date:	2021-07-19 15:58:00 +0800
categories:	[postgres]
---

> 单用户模式

单用户模式的服务器会把换行符当做命令输入的终止符。在单用户模式下，我们可以做一些维护和修复等操作。比如多用户模式下无法工作时、修复系统表和initdb时会使用单用户模式，今天我们研究initdb时的单用户模式。

```c
main(int argc,char* argv[])
{
    ...;//省略代码见postgres源码解析（main）
    if (argc > 1 && strcmp(argv[1], "--single") == 0)
		PostgresMain(argc, argv,
					 NULL,		/* no dbname */
					 strdup(get_user_name_or_exit(progname)));	/* does not return */
}

void
PostgresMain(int argc, char *argv[],const char *dbname,const char *username)
{
   	if (!IsUnderPostmaster)//如果是在postmaster子进程中，则IsUnderPostmaster为true
		InitStandaloneProcess(argv[0]);//为可执行进程初始化基本的环境信息
    
    SetProcessingMode(InitProcessing);//设置全局变量mode为InitProcessing
    if (!IsUnderPostmaster)//初始化GUC参数
		InitializeGUCOptions();
    
    /* 解析命令行参数 */
    process_postgres_switches(argc, argv, PGC_POSTMASTER, &dbname);//获取到命令行参数dbname为template1
    
    if (dbname == NULL)//必须获取到database名，否则使用默认的用户名作为database名
	{
		dbname = username;
		if (dbname == NULL)
			ereport(FATAL,
					(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
					 errmsg("%s: no database nor user name specified",
							progname)));
	}
    if (!IsUnderPostmaster)
	{
		if (!SelectConfigFiles(userDoption, progname))//选择配置文件：postgres.conf、pg_hba.conf、pg_ident.conf
			proc_exit(1);
	}
    
    /* 设置信号处理函数 */
    pqsignal(SIGHUP, SignalHandlerForConfigReload);//重新加载配置文件
	pqsignal(SIGINT, StatementCancelHandler);	/* cancel current query */
	pqsignal(SIGTERM, die); /* cancel current query and exit */
    ...;
    
    if (!IsUnderPostmaster)
    {
        checkDataDir();//检查DataDir
        ChangeToDataDir();//切换到DataDir
        CreateDataDirLockFile(false);//检查postmaster.pid文件是否存在，并写入进程号、DataDir、启动时间、端口号信息
        LocalProcessControlFile(false);//读取并加载pg_control文件
		InitializeMaxBackends();//初始化MaxBackends
    }
    BaseInit();//backend初始化
    #ifdef EXEC_BACKEND
	if (!IsUnderPostmaster)
		InitProcess();
	#else
		InitProcess();//为此后端初始化每个进程的数据结构MyProc全局进程链表
	#endif
    PG_SETMASK(&UnBlockSig);//初始化期间允许SIGINT
    
    InitPostgres(dbname, InvalidOid, username, InvalidOid, NULL, false);
    {//该函数和--boot时调用一致，除了参数，所以这里只分析有参数影响部分。
        if (in_dbname != NULL)
        {
            HeapTuple	tuple;
			Form_pg_database dbform;

			tuple = GetDatabaseTuple(in_dbname);
			if (!HeapTupleIsValid(tuple))
				ereport(FATAL,
						(errcode(ERRCODE_UNDEFINED_DATABASE),
						 errmsg("database \"%s\" does not exist", in_dbname)));
			dbform = (Form_pg_database) GETSTRUCT(tuple);
			MyDatabaseId = dbform->oid;
			MyDatabaseTableSpace = dbform->dattablespace;
			/* take database name from the caller, just for paranoia */
			strlcpy(dbname, in_dbname, sizeof(dbname));
        }
    }
    SetProcessingMode(NormalProcessing);//设置全局变量mode为NormalProcessing
    BeginReportingGUCOptions();//whereToSendOutput为DestDebug，直接返回
    
    process_session_preload_libraries();//在backend启动前预加载库
    
    /* Welcome banner for standalone case */
	if (whereToSendOutput == DestDebug)
		printf("\nPostgreSQL stand-alone backend %s\n", PG_VERSION);
    
    /*在main loop中创建信息上下文，没循环一次，该上下文信息就会被重置 */
    MessageContext = AllocSetContextCreate(TopMemoryContext,
										   "MessageContext",
										   ALLOCSET_DEFAULT_SIZES);
    MemoryContextSwitchTo(row_description_context);
	initStringInfo(&row_description_buf);
	MemoryContextSwitchTo(TopMemoryContext);
    
    if (!IsUnderPostmaster)
		PgStartTime = GetCurrentTimestamp();//记住backend启动时间
    
    /* 主要的循环处理流程 */
    if (sigsetjmp(local_sigjmp_buf, 1) != 0)
    {
        error_context_stack = NULL;
        HOLD_INTERRUPTS();//清理是防止中断，做InterruptHoldoffCount++
        
        disable_all_timeouts(false);//禁用信号处理程序，从活动列表中删除所有超时
        QueryCancelPending = false;//第二个避免竞争条件 
        DoingCommandRead = false;
        pq_comm_reset();//确保libpq是正常状态
    }
    PG_exception_stack = &local_sigjmp_buf;
	if (!ignore_till_sync)
		send_ready_for_query = true;	/* initially, or after error */
    for (;;)
    {
        doing_extended_query_message = false;
        
        MemoryContextSwitchTo(MessageContext);
		MemoryContextResetAndDeleteChildren(MessageContext);
        
        initStringInfo(&input_message);
        InvalidateCatalogSnapshotConditionally();
        
        /*（1）如果我们抵达了idle state，通知前端我们已经准备好了一个新的查询 */
        if (send_ready_for_query)
        {
            ProcessCompletedNotifies();
            pgstat_report_stat(false);
            set_ps_display("idle");//直接返回
            pgstat_report_activity(STATE_IDLE, NULL);
            ReportChangedGUCOptions();
            ReadyForQuery(whereToSendOutput);
            send_ready_for_query = false;
        }
        /*(2)如果异步信号在我们等待客户端输入时传入，则允许它立即执行*/
        DoingCommandRead = true;
        /*(3)读取管道输入（stdin）命令（循环处理）*/
        firstchar = ReadCommand(&input_message);
        /*(4)关闭the idle-in-transaction和idle-session timeouts*/
        if (idle_in_transaction_timeout_enabled)
		{
			disable_timeout(IDLE_IN_TRANSACTION_SESSION_TIMEOUT, false);
			idle_in_transaction_timeout_enabled = false;
		}
		if (idle_session_timeout_enabled)
		{
			disable_timeout(IDLE_SESSION_TIMEOUT, false);
			idle_session_timeout_enabled = false;
		}
        /*(5)再次禁用异步信号条件*/
        CHECK_FOR_INTERRUPTS();
        DoingCommandRead = false;
        /*(6)检查睡眠时发生的事件*/
        if (ConfigReloadPending)
		{
			ConfigReloadPending = false;
			ProcessConfigFile(PGC_SIGHUP);
		}
		/*(7)处理命令，但是我们如果直接跳到同步，则忽略它*/
        if (ignore_till_sync && firstchar != EOF)
			continue;
        switch (firstchar)
        {
             case 'Q':			/* simple query*/
                {
                    const char *query_string;
                    SetCurrentStatementStartTimestamp();//设置stmtStartTimestamp
                    query_string = pq_getmsgstring(&input_message);//获取管道获取的字符串信息
                    pq_getmsgend(&input_message);//检查message的cursor和len是否相等
                    if (am_walsender)
					{//如果是walsender进程
						if (!exec_replication_command(query_string))
							exec_simple_query(query_string);
					}
					else
						exec_simple_query(query_string);//执行query_string
                    send_ready_for_query = true;
                }
                break;
            case 'P':    /* parse */
            case 'B':	/* bind */
            case 'E':	/* execute */
            case 'F':			/* fastpath function call */
            case 'C':			/* close */
            case 'D':			/* describe */
            case 'H':			/* flush */
            case 'S':			/* sync */
            case 'd':			/* copy data */
            case 'c':			/* copy done */
            case 'f':			/* copy fail */
            default:
        }
    }
}
```

> 总结

单模式中已经可以交互式的接受命令行命令，initdb是借助template1模板可以执行system_views.sql、snowball_create.sql、information_schema.sql中的sql命名、加载pl/pgsql模块、创建template0模板和postgres数据库。

