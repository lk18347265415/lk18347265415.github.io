---
layout:	post
title:	"postgres源码解析(main)"
date:	2021-07-09 13:58:00 +0800
categories:	[postgres]
---

> postgres源码解析--main函数

```c
//"src/backend/main.c"
int
main(int argc, char *argv[])
{
	progname = get_progname(argv[0]);//获取程序名称
	startup_hacks(progname);//初始化dummy_spinlock
	
	argv = save_ps_display_args(argc, argv);//利用argv修改ps显示的进程信息
	MemoryContextInit();//启动内存上下文子系统
	
	set_pglocale_pgservice(argv[0], PG_TEXTDOMAIN("postgres"));//设置本地环境信息（如LC_ALL和程序绝对路径信息）
	init_locale(...);//初始化LC_COLLATE、LC_CTYPE等
	unsetenv("LC_ALL");//删除所有LC_ALL的设置
	
	if (strcmp(argv[1], "--help") == 0 || strcmp(argv[1], "-?") == 0)
	{
		help(progname);//显示程序帮助信息
		exit(0);
	}else if(strcmp(argv[1], "--version") == 0 || strcmp(argv[1], "-V") == 0){
		fputs(PG_BACKEND_VERSIONSTR, stdout);
		exit(0);
	}
#ifdef EXEC_BACKEND        //EXEC_BACKEND是在WIN32平台情况下定义，该宏定义在pg_config_manual.h中
	if (argc > 1 && strncmp(argv[1], "--fork", 6) == 0)
		SubPostmasterMain(argc, argv);	/* does not return */
#endif

	if (argc > 1 && strcmp(argv[1], "--boot") == 0)
		AuxiliaryProcessMain(argc, argv);//引导模式
	else if (argc > 1 && strcmp(argv[1], "--describe-config") == 0)
		GucInfoMain();//显示内部服务器配置选项及描述
	else if (argc > 1 && strcmp(argv[1], "--single") == 0)//单用户模式
		PostgresMain(argc, argv,
					 NULL,
					 strdup(get_user_name_or_exit(progname)));
	else
		PostmasterMain(argc, argv);//正常数据库启动走该分支
	abort();
}
```

> 总结

postgres重要的三个模式就是--boot、--single和正常模式（PostmasterMain），其中在initdb时引用过--boot和--single模式。后续会分别介绍这几种模式。
