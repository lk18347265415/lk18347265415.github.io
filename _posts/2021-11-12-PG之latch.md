---
layout: post
title:  "PG之latch"
date:   2021-11-12 11:06:00 +0700
categories: [postgres]
---

## 什么是Latch

Latch翻译为闩锁，PG中latch就是一个布尔变量，在latch被设置前，它将一直阻塞等待。它的实现采用了self-pipe trick技术，即维护一个管道并监控管道读端事件，当在信号来到时，向管道写端写入数据，以此触发管道读段读事件来打断阻塞条件。

## Latch的实现

PG中有两种Latch：

1）local latch：local latch被InitLatch函数初始化，并且它只能被同一进程内设置。local latch可以用来等待信号的到达，通过函数SetLatch来触发信号处理操作。

2）share latch：share latch被InitSharedLatch函数初始化，在share latch被使用前，必须使用OwnLatch使latch关联进程。只有进程拥有的latch可以用于等待事件，但是任何进程都可以设置它(SetLatch),即任何进程都能唤醒它。

**代码实现：**

```c
//local latch的初始化
void InitializeLatchSupport(void)
{
	if (pipe(pipefd) < 0)//维护一个本地管道
		elog(FATAL, "pipe() failed: %m");
	if (fcntl(pipefd[0], F_SETFL, O_NONBLOCK) == -1)
		elog(FATAL, "fcntl(F_SETFL) failed on read-end of self-pipe: %m");
	if (fcntl(pipefd[1], F_SETFL, O_NONBLOCK) == -1)
		elog(FATAL, "fcntl(F_SETFL) failed on write-end of self-pipe: %m");
	if (fcntl(pipefd[0], F_SETFD, FD_CLOEXEC) == -1)
		elog(FATAL, "fcntl(F_SETFD) failed on read-end of self-pipe: %m");
	if (fcntl(pipefd[1], F_SETFD, FD_CLOEXEC) == -1)
		elog(FATAL, "fcntl(F_SETFD) failed on write-end of self-pipe: %m");
	
	selfpipe_readfd = pipefd[0];
	selfpipe_writefd = pipefd[1];
	selfpipe_owner_pid = MyProcPid;
}
MyLatch = &LocalLatchData;
void InitLatch(Latch *latch)
{
	latch->is_set = false;
	latch->owner_pid = MyProcPid;
	latch->is_shared = false;
	Assert(selfpipe_readfd >= 0 && selfpipe_owner_pid == MyProcPid);
}


//share latch的初始化
void InitSharedLatch(Latch *latch)
{
	latch->is_set = false;
	latch->owner_pid = 0;
	latch->is_shared = true;
}
		
void OwnLatch(Latch *latch)//将当前进程和latch绑定
{
	Assert(latch->is_shared);//必须为share-latch
	Assert(selfpipe_readfd >= 0 && selfpipe_owner_pid == MyProcPid);
	if (latch->owner_pid != 0)
		elog(ERROR, "latch already owned");
	latch->owner_pid = MyProcPid;
}
void DisownLatch(Latch *latch)//放弃当前进程拥有的latch
{
	Assert(latch->is_shared);
	Assert(latch->owner_pid == MyProcPid);	
	latch->owner_pid = 0;
}

void SetLatch(Latch *latch)//设置latch并唤醒latch的等待
{
	pg_memory_barrier();
	if (latch->is_set)//如果latch已经被设置，则直接退出
			return;
	latch->is_set = true;
	owner_pid = latch->owner_pid;
	if (owner_pid == 0)//防止latch被disowned
		return;
	else if (owner_pid == MyProcPid)//latch拥有进程和该进程为同一进程
	{
		if (waiting)//全局变量，检查当前是否在WaitLatch阻塞中，是则为true
			sendSelfPipeByte();//向管道中写入一个字节，唤醒waitlatch
	}
	else
		kill(owner_pid, SIGUSR1);//该进程不是当前进程直接调用kill向latch拥有进程发送SIGUSR1信号
}

int WaitLatch(Latch *latch, int wakeEvents, long timeout,uint32 wait_event_info)
{//一直等待，直到latch被设置
	return WaitLatchOrSocket(latch, wakeEvents, PGINVALID_SOCKET, timeout, ait_event_info);
}
int WaitLatchOrSocket(Latch *latch, int wakeEvents, pgsocket sock,long timeout, uint32 wait_event_info)
{//等待latch被设置或者socket时间发生
	WaitEventSet *set = CreateWaitEventSet(CurrentMemoryContext, 3);//创建epoll实例
	if (wakeEvents & WL_LATCH_SET)//添加Latch事件，其实就是监听selfpipe_readfd描述符
		AddWaitEventToSet(set, WL_LATCH_SET, PGINVALID_SOCKET,latch, NULL);
	if ((wakeEvents & WL_POSTMASTER_DEATH) && IsUnderPostmaster)//监听PM死亡事件，监听postmaster_alive_fds读端
		AddWaitEventToSet(set, WL_POSTMASTER_DEATH, PGINVALID_SOCKET,NULL, NULL);
	if ((wakeEvents & WL_EXIT_ON_PM_DEATH) && IsUnderPostmaster)//同上，只是需要做立即退出处理
		AddWaitEventToSet(set, WL_EXIT_ON_PM_DEATH, PGINVALID_SOCKET,NULL, NULL);
	if (wakeEvents & WL_SOCKET_MASK)
		{//添加socket监听事件
			int ev = wakeEvents & WL_SOCKET_MASK;
			AddWaitEventToSet(set, ev, sock, NULL, NULL);
		}
	rc = WaitEventSetWait(set, timeout, &event, 1, wait_event_info);//epoll_wait,没有时间发生将会在这里阻塞
	FreeWaitEventSet(set);//close epoll_fd
	return ret;
}
======================================================
//latch等待事件的通用场景如下：
for(;;)
{
	ResetLatch();
	if (work to do)
		Do Stuff();
	 WaitLatch();//SetLatch将会打断latch的等待
}
```

## Latch使用场景

1. 使用在walsender休眠中，这样一旦事物完成，walsender就会被唤醒，立即将WAL发送到备用服务器，这样能减少主备之间的延迟。
2. 使用在checkpointer中，当命令行输入checkpoint时，需要立即完成checkpoint操作，这时首先会给checkpointer进程发送SIGINT信号，checkpointter收到该信号时，信号处理函数在发送SIGUSR1信号，checkpointer的SIGUSR1处理函数会调用setlatch操作来唤醒checkpoint进程，从而执行checkpoint操作。
3. 像bgwriter和pgarch这样后台进程下都有latch的使用，因为latch能可靠的替换常用模式下pg_usleep和或者select()等待信号到达才结束等待的场景。

