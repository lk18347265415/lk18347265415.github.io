---
layout: post
title:  "postgreSQL怎么修改进程显示信息的?"
date:   2024-10-12 11:06:00 +0700
categories: [postgres]
---

## 定制ps显示postgreSQL进程显示信息

当我们使用ps命令查看postgreSQL相关进程信息时，有没有想过这些信息是怎么被postgreSQL定制的呢？今天探索一下Unix-like环境下postgreSQL数据库怎么修改各进程显示信息。

![](D:\git资料\lk18347265415.github.io\_posts\pic\display_processinfo.png)



## 需要提前了解的知识点

- 在 Unix-like 系统中，`argv` 通常是进程在命令行中的显示名称，用户可以使用 `ps` 命令查看
- 父进程的argc和argv变量在栈中，所以可以继承到子进程中，子进程可以自由修改argc和argv的值，不影响父进程

## 代码实现

PostgreSQL中通过**init_ps_display**函数实现更改进程显示信息，该函数通过后台进程类型返回要显示的字符串，然后再将字符串信息拷贝到**ps_buffer**中。其中**set_ps_display**函数的作用为今天添加更详细信息，添加的信息为传入的字符串参数。

```c
// src/backend/main/main.c
int
main(int argc, char *argv[])
{
	char	  **
	save_ps_display_args(int argc, char **argv)
	{
		save_argc = argc;
		save_argv = argv;
        /* 处理postgres进程显现信息 */
    	...
    	return argv;
	}
}
//src/backend/utils/misc/ps_status.c

#if defined(__linux__) || defined(_AIX) || defined(__sgi) || (defined(sun) && !defined(BSD)) || defined(__svr5__) || defined(__darwin__)
#define PS_USE_CLOBBER_ARGV
#if defined(_AIX) || defined(__linux__) || defined(__darwin__)
#define PS_PADDING '\0'

static char *ps_buffer;			/* will point to argv area */
static size_t ps_buffer_size;	/* space determined at run time */
static size_t last_status_len;	/* use to minimize length of clobber */

static int	save_argc;
static char **save_argv;

init_ps_display(NULL);
{
	if (!fixed_part)
		fixed_part = GetBackendTypeDesc(MyBackendType);//返回要显示进程信息
#ifdef PS_USE_CLOBBER_ARGV
	{
		int			i;

		/* make extra argv slots point at end_of_area (a NUL) */
		for (i = 1; i < save_argc; i++)
			save_argv[i] = ps_buffer + ps_buffer_size;
	}
#endif							/* PS_USE_CLOBBER_ARGV */
	if (*cluster_name == '\0')
	{//在这里之后，ps就已经能显示指定的进程信息了，但是后面可能会有多余字串(继承自父进程)
		snprintf(ps_buffer, ps_buffer_size, PROGRAM_NAME_PREFIX "%s ",fixed_part);
	}
	else
	{
		snprintf(ps_buffer, ps_buffer_size,PROGRAM_NAME_PREFIX "%s: %s ",
				 cluster_name, fixed_part);
	}
	ps_buffer_cur_len = ps_buffer_fixed_size = strlen(ps_buffer);

	/*
	 * On the first run, force the update.
	 */
	save_update_process_title = update_process_title;
	update_process_title = true;
	set_ps_display("");
	{
		/* 将传入参数添加到显示信息后面 */
		strlcpy(ps_buffer + ps_buffer_fixed_size, activity,
			ps_buffer_size - ps_buffer_fixed_size);
		ps_buffer_cur_len = strlen(ps_buffer);
		#ifdef PS_USE_CLOBBER_ARGV
			/* 填充未使用的内存(\0)；只需清除旧状态字符串的剩余部分 */
			if (last_status_len > ps_buffer_cur_len)
				MemSet(ps_buffer + ps_buffer_cur_len, PS_PADDING,
						last_status_len - ps_buffer_cur_len);
			last_status_len = ps_buffer_cur_len;
		#endif							/* PS_USE_CLOBBER_ARGV */
	}
	update_process_title = save_update_process_title;
}
```



## 简单程序案例

我们写一个简单的c程序案例(test.c)，该案例也是基于同样的规则修改ps显示该程序运行时的信息。

```c
include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char *argv[]) {
    // 指定要ps显示的消息
    char *new_name = "mypro";
    size_t len = strlen(new_name);

    size_t old_len = strlen(argv[0]);
    // 确保有足够的空间来保存新名称
    if (len < strlen(argv[0])) {
        strcpy(argv[0], new_name);//更改argv[0]信息
    } else {
        fprintf(stderr, "新名称太长，无法放入 argv[0] 中\n");
        return 1;
    }
    //如果新名称比久名称短，清理残余旧名称
    memset(argv[0]+len, 0 , old_len - len);

    // 主循环
    while (1) {
        // 模拟做一些工作
        sleep(1);
    }

    return 0;
}
```

通过**gcc -o set_ps test.c**编译好以上程序后，我们使用ps命令查看该进程信息，我们指定的**mypro**信息就显示出来了。

![](D:\git资料\lk18347265415.github.io\_posts\pic\psspe.png)



## 总结

​	PostgreSQL中postmaster程序的显示信息是通过**save_ps_display_args**函数修改，辅助进程的显示信息都是通过init_ps_display函数修改。其中的逻辑都是修改argv参数信息。如果是BSD类系统环境，且定义了宏**PS_USE_SETPROCTITLE**，那么PostgreSQL会使用**setproctitle**函数修改进程显示信息。