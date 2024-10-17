---
layout: post
title:  "syslogger"
date:   2024-10-16 11:06:00 +0700
categories: [postgres]
---



## 引言

当把logging_collect参数设置为on时，postmaster进程会启动syslogger辅助进程。该进程主要收集postmaster和各辅助进程的错误报告和日志，然后将收集的信息写入日志文件中。



## 任务分析

syslogger的主要逻辑是syslog进程通过管道读端(syslogPipe[0])读取日志数据，当postmaster创建好syslog程序后，会将stdout和stderr重定向(dup2)到管道的写端(syslogPipe[1]),这样postmaster，后台进程和辅助进程产生的信息就被syslog读取然后写入日志文件了。

syslogger收集的日志分为协议结构日志（protocol structure）和非协议日志（non-protocol data），协议日志按块写入。非协议日志直接写入文件。协议日志的结构如下：

```c
#ifdef PIPE_BUF
#if PIPE_BUF > 65536
#define PIPE_CHUNK_SIZE  65536
#else
#define PIPE_CHUNK_SIZE  ((int) PIPE_BUF)
#endif
#else							/* not defined */
#define PIPE_CHUNK_SIZE  512
#endif

typedef struct
{
	char		nuls[2];		/* always \0\0 */
	uint16		len;			/* size of this chunk (counts data only) */
	int32		pid;			/* writer's pid */
	char		is_last;		/* last chunk of message? 't' or 'f' ('T' or
								 * 'F' for CSV case) */
	char		data[FLEXIBLE_ARRAY_MEMBER];	/* data payload starts here */
} PipeProtoHeader;

typedef union
{
	PipeProtoHeader proto;
	char		filler[PIPE_CHUNK_SIZE];
} PipeProtoChunk;
```

PostgreSQL中日志收集的大体框架如下所示：

![syslog结构1](D:\git资料\lk18347265415.github.io\_posts\pic\syslog结构1.png)



## 代码分析

syslogPipe管道在Postmaster进程创建，然后各子进程都会继承该管道信息。其中syslogger程序中监听syslogPipe读端，关闭写端。其它进程关闭读端，保留写端。并且将其它进程的stdout和stderr重定向到管道的写端。

```c
//syslogger.c
int
SysLogger_Start(void)
{
	if (syslogPipe[0] < 0)//检查是否要创建syslogPipe管道
	{
		if (pipe(syslogPipe) < 0)
			ereport(FATAL,"pipe error!");
	}
	(void) MakePGDirectory(Log_directory);//创建log目录

	/* 生成指定名称日志文件 */
	first_syslogger_file_time = time(NULL);
	filename = logfile_getname(first_syslogger_file_time, NULL);
	syslogFile = logfile_open(filename, "a", false);
	pfree(filename);
	/* 查看是否启用csv格式文件 */
	if (Log_destination & LOG_DESTINATION_CSVLOG)
	{
		filename = logfile_getname(first_syslogger_file_time, ".csv");
		csvlogFile = logfile_open(filename, "a", false);
		pfree(filename);
	}
	switch ((sysloggerPid = fork_process()))
	{
		case -1:
			ereport(LOG,"for error");
			return 0;
		case 0:
			/* 子进程 */
			InitPostmasterChild();
			ClosePostmasterPorts(true);
			dsm_detach_all();
			PGSharedMemoryDetach();
			SysLoggerMain(0, NULL);
			break;
		default:
			/* psotmaster 进程 */
			if (!redirection_done)
			{
				/*  将stdout标准输出和stderr错误重定向到syslogPipe写端 */
				fflush(stdout);
				if (dup2(syslogPipe[1], fileno(stdout)) < 0)
					ereport(FATAL, "dup2 error")
				fflush(stderr);
				if (dup2(syslogPipe[1], fileno(stderr)) < 0)
					ereport(FATAL, "dup2 error")
				close(syslogPipe[1]);
				syslogPipe[1] = -1;
				redirection_done = true;//标记重定向已经完成
			}
			/* postmaster不需要处理日志文件，所以关闭 */
			fclose(syslogFile);
			syslogFile = NULL;
			if (csvlogFile != NULL)
			{
				fclose(csvlogFile);
				csvlogFile = NULL;
			}
			return (int) sysloggerPid;
	}
}

NON_EXEC_STATIC void
SysLoggerMain(int argc, char *argv[])
{
	MyBackendType = B_LOGGER;
	init_ps_display(NULL);//设置syslogger进程ps显示信息
	
	if (syslogPipe[1] >= 0)//关闭syslogPipe写端
		close(syslogPipe[1]);
	syslogPipe[1] = -1;
	
	pqsignal(SIGUSR1, sigUsr1Handler);//处理请求日志轮换
	
	/* 设置日志文件名 */
	last_file_name = logfile_getname(first_syslogger_file_time, NULL);
	if (csvlogFile != NULL)
		last_csv_file_name = logfile_getname(first_syslogger_file_time, ".csv");

	/* 记住活动日志文件参数 */
	currentLogDir = pstrdup(Log_directory);
	currentLogFilename = pstrdup(Log_filename);
	currentLogRotationAge = Log_RotationAge;
	/* set next planned rotation time */
	set_next_rotation_time();
	update_metainfo_datafile();
	
	/* 创建latch和syslogpipe读端等待条件 */
	wes = CreateWaitEventSet(CurrentMemoryContext, 2);
	AddWaitEventToSet(wes, WL_LATCH_SET, PGINVALID_SOCKET, MyLatch, NULL);
	AddWaitEventToSet(wes, WL_SOCKET_READABLE, syslogPipe[0], NULL, NULL);
	
	/* syslogger进程的主工作循环 */
	for (;;)
	{
		ResetLatch(MyLatch);//重置MyLatch
		
		//处理最近收到的任何请求或信号
		if (ConfigReloadPending)
		{
			ConfigReloadPending = false;
			ProcessConfigFile(PGC_SIGHUP);
			//检查 postgresql.conf 中的日志目录或文件名模式是否发生更改。
			//如果是这样，请强制轮换以确保我们将日志文件写入正确的位置
			if (strcmp(Log_directory, currentLogDir) != 0)
			{
				pfree(currentLogDir);
				currentLogDir = pstrdup(Log_directory);
				rotation_requested = true;
				//如果不存在，则创建新目录
				(void) MakePGDirectory(Log_directory);
			}
			if (strcmp(Log_filename, currentLogFilename) != 0)
			{
				pfree(currentLogFilename);
				currentLogFilename = pstrdup(Log_filename);
				rotation_requested = true;
			}
			//如果 CSVLOG 输出刚刚打开或关闭，并且我们需要相应地打开或关闭 csvlogFile，则强制旋转
			if (((Log_destination & LOG_DESTINATION_CSVLOG) != 0) !=(csvlogFile != NULL))
				rotation_requested = true;
			//如果轮换时间参数改变，则重置下一次轮换时间，但不要立即强制旋转。
			if (currentLogRotationAge != Log_RotationAge)
			{
				currentLogRotationAge = Log_RotationAge;
				set_next_rotation_time();
			}
			//如果我们遇到轮换禁用失败，请在 SIGHUP 后重新启用轮换尝试，并立即强制执行一次。
			if (rotation_disabled)
			{
				rotation_disabled = false;
				rotation_requested = true;
			}
			//重新加载配置时强制重写最后一个日志文件名
			update_metainfo_datafile();
		}
		
		/* 等待latch或syslogpipe事件发生 */
		rc = WaitEventSetWait(wes, cur_timeout, &event, 1,
							  WAIT_EVENT_SYSLOGGER_MAIN);
		if (rc == 1 && event.events == WL_SOCKET_READABLE)
		{
			bytesRead = read(syslogPipe[0],
							 logbuffer + bytes_in_logbuffer,
							 sizeof(logbuffer) - bytes_in_logbuffer);
			//处理管道中读取到的日志信息
			process_pipe_input(logbuffer, &bytes_in_logbuffer);
			{
				char	   *cursor = logbuffer;
				int			count = *bytes_in_logbuffer;
				while (count >= (int) (offsetof(PipeProtoHeader, data) + 1))
				{
					PipeProtoHeader p;
					memcpy(&p, cursor, offsetof(PipeProtoHeader, data));
					if((p.nuls[0] == '\0' && p.nuls[1] == '\0' && ...)//如果是原始协议结构
					{
						chunklen = PIPE_HEADER_SIZE + p.len;
						if (count < chunklen)//写入数据量小于chunklen，则退出循环
							break;
						dest = (p.is_last == 'T' || p.is_last == 'F') ?
							LOG_DESTINATION_CSVLOG : LOG_DESTINATION_STDERR;
						/* 找到该pid的任何现有缓冲区 */
						List *buffer_list = buffer_lists[p.pid % NBUFFER_LISTS];
						foreach(cell, buffer_list)
						{
							save_buffer *buf = (save_buffer *) lfirst(cell);
							if (buf->pid == p.pid)
							{
								existing_slot = buf;
								break;
							}
							if (buf->pid == 0 && free_slot == NULL)
								free_slot = buf;
						}
						if (p.is_last == 'f' || p.is_last == 'F')
						{//将完整的非最终块保存在每个 pid 缓冲区中
							if (existing_slot != NULL)
							{
								str = &(existing_slot->data);
								appendBinaryStringInfo(str,cursor + PIPE_HEADER_SIZE,p.len);
							}
							else
							{//新的chunk块中，申请新内存空间
								if (free_slot == NULL)
								{
									free_slot = palloc(sizeof(save_buffer));
									buffer_list = lappend(buffer_list, free_slot);
									buffer_lists[p.pid % NBUFFER_LISTS] = buffer_list;
								}
								free_slot->pid = p.pid;
								str = &(free_slot->data);
								initStringInfo(str);
								appendBinaryStringInfo(str, cursor + PIPE_HEADER_SIZE, p.len);
							}
						}
						else
						{//最后一块，
							if (existing_slot != NULL)
							{
								str = &(existing_slot->data);
								appendBinaryStringInfo(str,cursor + PIPE_HEADER_SIZE,p.len);
								write_syslogger_file(str->data, str->len, dest);
								/* 将缓冲区标记为未使用，并回收字符串存储 */
								existing_slot->pid = 0;
								pfree(str->data);
							}
							else
							{
								/* 整个消息就是一块 */
								write_syslogger_file(cursor + PIPE_HEADER_SIZE, p.len,dest);
							}
						}
						/* 处理完成该块数据 */
						cursor += chunklen;
						count -= chunklen;
					}
					else
					{//处理非协议结构
						for (chunklen = 1; chunklen < count; chunklen++)
						{//如果查到了协议头，应该将数据重定向到协议结构格式中
							if (cursor[chunklen] == '\0')
								break;
						}
						/* 非协议数据该函数直接通过fwrite写入日志文件中 */
						write_syslogger_file(cursor, chunklen, LOG_DESTINATION_STDERR);
						cursor += chunklen;
						count -= chunklen;
					}
				}
			}
			continue;
		}
	}
}
```

postmaster进程和各辅助进程怎么产生日志消息？各进程中通过调用**EmitErrorReport**函数将收集的信息发送到管道中。其中**errfinish**也会引用该函数。

```c
void
EmitErrorReport(void)
{
	ErrorData  *edata = &errordata[errordata_stack_depth];
	MemoryContext oldcontext;

	recursion_depth++;
	CHECK_STACK_DEPTH();
	oldcontext = MemoryContextSwitchTo(edata->assoc_context);
    
    /* 如果开起了logger，向logger发送数据  */
	if (edata->output_to_server)
		send_message_to_server_log(edata);
    	{
            initStringInfo(&buf);
            log_line_prefix(&buf, edata);
			appendStringInfo(&buf, "%s:  ", _(error_severity(edata->elevel)));
            /* guc控制日志细节量 */
            if (Log_error_verbosity >= PGERROR_VERBOSE)
				appendStringInfo(&buf, "%s: ", unpack_sql_state(edata->sqlerrcode));
            ...
            /* 如果用户想让生成错误的查询记录下来，那么就记录下来 */
            if (is_log_level_output(edata->elevel, log_min_error_statement) && ...)
            {
                log_line_prefix(&buf, edata);
				appendStringInfoString(&buf, _("STATEMENT:  "));
				append_with_tabs(&buf, debug_query_string);
				appendStringInfoChar(&buf, '\n');
            }
            /* 如果log_destination设置成了syslog，则通过系统syslog守护进程写入日志 */
            if (Log_destination & LOG_DESTINATION_SYSLOG)
            {
                int			syslog_level;
                switch (edata->elevel)
                {//记录log的等级
                        case: DEBUG5:
                        ...
                        syslog_level = LOG_DEBUG/LOG_INFO/...;
                        ..
                }
                write_syslog(syslog_level, buf.data);
            }
            /* 写入stderr */
            if ((Log_destination & LOG_DESTINATION_STDERR) || whereToSendOutput == DestDebug)
            {
                /* 如果知道syslogger获取stderr消息，那么就使用块协议 */
                if (redirection_done && MyBackendType != B_LOGGER)
                   write_pipe_chunks(buf.data, buf.len, LOG_DESTINATION_STDERR); 
            }
            /* 如果在syslogger进程中，直接写入日志文件 */
            if (MyBackendType == B_LOGGER)
				write_syslogger_file(buf.data, buf.len, LOG_DESTINATION_STDERR);
            /* 写入CSV日志 */
            if (Log_destination & LOG_DESTINATION_CSVLOG)
            {
                if (redirection_done || MyBackendType == B_LOGGER)
                {
                    pfree(buf.data);
                    write_csvlog(edata);
                }
                else
                {//如果没有syslogger，错误消息直接定向到stderr
                    if (!(Log_destination & LOG_DESTINATION_STDERR) && ...)
                        write_console(buf.data, buf.len);
                }
            }
            else
            {
                pfree(buf.data);
            }
        }
    
    /* 错误信息发送到客户端 */
	if (edata->output_to_client)
		send_message_to_frontend(edata);

	MemoryContextSwitchTo(oldcontext);
	recursion_depth--;
}
```



## 总结

​	日志的实现首先是postmaster守护进程通过**pipe(syslogPipe)**函数创建管道，并通过**dup2**函数将stdout和stderr重定向到syslogPipe管道的写端。在syslogger进程中将关闭syslogPipe管道的写端，并在管道的读端创建监听事件，监听是否有数据到达。而其他辅助进程继承于postmaster进程，所以管道特性也继承了postmaster特性。当各进程产生错误消息时，都会调用**EmitErrorReport**函数将错误信息写入**syslogPipe**管道中。其中当syslogger进程自己产生错误消息时，就不用向管道写入数据了，直接写日志文件即可。



### 注意：

​	PostgreSQL中还有一个写日志的方式，当guc参数log_destination设置为syslog时，PostgreSQL写日志文件是通过操作系统依赖的syslog守护进程写入。不过在很多系统上syslog不是非常可靠，特别是在面对大量日志消息的情况下，它可能会将日志信息截断或者丢弃。PostgreSQL中syslog的实现从以上的**EmitErrorReport**函数里面可以看到，**write_syslog**函数就是使用syslog的机制写日志文件。