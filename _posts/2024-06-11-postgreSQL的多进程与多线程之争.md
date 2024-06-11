---
layout: postgres
title:  "postgreSQL的多进程与多线程之争"
date:   2024-06-11 11:06:00 +0700
categories: [postgres]
---

[TOC]

## postgreSQL进程架构

postgreSQL使用的经典的客户端/服务端模型。同时在服务端使用的是多进程架构，其中最重要的进程是postmaster守护进程和后台服务进程postgres。守护进程postmaster负责整个系统的启动和关闭，监听客户端的连接请求，当有客户端请求连接时，postmaster守护进程会为客户端分配postgres服务进程。同时postmaster守护进程也是各辅助进程的父进程。

![](D:\git资料\lk18347265415.github.io\_posts\pic\postmaster.png)

## postgreSQL代码架构

首先main函数为postgreSQL服务端总入口函数，postmaster守护进程负责创建监听套接字，负责监听各服务进程状态，并启动后台进程和服务进程。其中postmaster都采用了fork系统调用产生子进程。

```c
int
main(int argc, char *argv[])
{
	if (argc > 1 && strcmp(argv[1], "--boot") == 0)
		AuxiliaryProcessMain(argc, argv);	/* 引导模式 */
	else if (argc > 1 && strcmp(argv[1], "--describe-config") == 0)
		GucInfoMain();			/* 配置描述 */
	else if (argc > 1 && strcmp(argv[1], "--single") == 0)
		PostgresMain();	/* 单用户模式 */
	else
		PostmasterMain(); /* postmaster服务进程 */
		{
			reset_shared(); /* 创建进程间共享内存 */
			SysLoggerPID = SysLogger_Start();	/* 启动日志收集辅助进程 */
			/* 套接字监听客户端连接 */
			socket();
			bind();
			listen();
			
			StartupPID = StartupDataBase(); /* 启动日志回放进程 */
			maybe_start_bgworkers(); /* 检查是否需要启动后台工作者进程 */
			status = ServerLoop();
			{
				for(;;)
				{
					selres = select(); /* 多路复用检查是否有客户端连接 */
					/* 启动后端服务进程postgres */
					if (selres > 0)
						BackendStartup(port);
						{
							pid = fork();
							if (pid == 0)
								BackendRun(port);	/* 后端服务进程入口 */
						}
					/* 如果日志收集进程异常，重启日志进程 */
					if (SysLoggerPID == 0 && Logging_collector)
						SysLoggerPID = SysLogger_Start();
						{
							sysloggerPid = fork();
							if (sysloggerPid == 0)
								SysLoggerMain(); /* 系统日志进程入口 */
						}
					/* 启动checkpoint和后台写进程 */
					if (CheckpointerPID == 0)
						CheckpointerPID = StartCheckpointer();
					if (BgWriterPID == 0)
						BgWriterPID = StartBackgroundWriter();
					/* 启动写wal日志进程 */
					if (WalWriterPID == 0 && pmState == PM_RUN)
						WalWriterPID = StartWalWriter();
					/* 启动垃圾回收进程 */
					if(AutoVacPID == 0 && (AutoVacuumingActive() || 
					   start_autovac_launcher) && pmState == PM_RUN)
						AutoVacPID = StartAutoVacLauncher();
					/* 启动收集信息统计进程 */
					if (PgStatPID == 0 && pmState == PM_RUN)
						PgStatPID = pgstat_start();
					/* 启动日志归档进程 */
					if (PgArchPID == 0 && PgArchStartupAllowed())
						PgArchPID = StartArchiver();
					/* 启动了wal日志接收进程 */
					if (WalReceiverRequested)
						MaybeStartWalReceiver();
					/* 启动后台工作者进程 */
					if (StartWorkerNeeded || HaveCrashedWorker)
						maybe_start_bgworkers();
				}
			}
		}
}
```

## 社区postgreSQL多线程架构讨论

​	postgreSQL社区中很早(17年之前)都有讨论是否放弃现有的多进程架构，并引用多线程架构。此话题迅速引起了社区广泛讨论，并且形成了两个派别。一个派别是积极支持postgreSQL线程的，并给出了线程化后的优势：

1. 线程更轻量化、现成切换更快速和更低的内存消耗

2. 不需要现阶段的共享内存、更加高效的同步源语

3. 更有效的使用虚拟内存和更快的后端启动等。

而反对postgreSQL线程派同样给出了不可实施的理由：

1. 实施的困难，需要大量的代码更改，不仅仅是简单的将fork改为pthread_create函数。
2. postgreSQL中现在存在大量的静态全局变量，线程化后可能需要将其改为线程局部变量（例如gcc提供的 __thread关键字定义的变量放置在段寄存器中）。
3. 扩展中同样使用了大量的全局变量或破坏多线程环境的情况。
4. 需要使用线程安全的库或者函数以及信号处理的改变等等

甚至Konstantin 还创建了线程分支（https://github.com/postgrespro/postgresql.pthreads.git），并做了简单的线程处理。pgbench得出线程版比进程版性能提升50%以上，在多线程模式下处理大量连接时性能比多进程更好，多进程模型在大量连接的模式下性能下降明显。并且，postgreSQL线程化后连接池内置实现就很方便了，就省去了现在使用第三方连接池的烦恼。

​	引入线程后的缺陷：

1. 线程依赖于编译器和硬件特性，降低了可移植性
2. 在线程终止时可能会遇到信号处理和资源管理的问题
3. postmaster与辅助进程之间的交互复杂
4. 线程对比进程的隔离性和稳健性都稍弱

