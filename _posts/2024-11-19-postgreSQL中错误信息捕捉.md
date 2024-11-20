---
layout: post
title:  "PostgreSQL中错误信息捕捉原理"
date:   2024-11-19 11:06:00 +0700
categories: [postgres]
---

## 引言

​	PostgreSQL中使用了PG_TRY()、PG_CATCH()、PG_FINALLY()、PG_END_TRY()这几个宏实现了高级语言中的错误信息捕捉功能。今天就从看一下PostgreSQL中这几个宏设计的精巧之处。



## 异常捕捉的使用用例

​	以下用例中，将可能出错的代码包装在了PG_TRY块中，如果在该模块中有错误发生，那么错误信息将会被PG_CATCH捕捉，并执行PG_CATCH块中的代码，PG_CATCH块中获取了PG_TRY中发生的错误码，如果匹配到了想要的错误码，将错误信息整改为了警告信息。从而实现了捕捉错误信息，并将其整改成了警告。

```c
PG_TRY();
{//执行可能抛出错误的代码
	seqform->seqincrement = defGetInt64(increment_by);
	if (seqform->seqincrement == 0)
		ereport(ERROR,
			(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
			errmsg("INCREMENT must not be zero")));
		seqdataform->log_cnt = 0;
}
PG_CATCH();
{//捕捉PG_TRY中的错误，并错误恢复代码
	errcod = geterrcode();
	if(errcod == ERRCODE_NUMERIC_VALUE_OUT_OF_RANGE)
	{
		ereport(WARNING,
				(errcode(ERRCODE_NUMERIC_VALUE_OUT_OF_RANGE),
				errmsg("Increment value is out of range for data type bigint")));
	}
}
PG_END_TRY();
```



## 异常捕捉的功能和限制

PG_TRY()宏用于处理可能发生错误的代码，PG_CATCH()可用于捕捉PG_TRY()中的错误，捕捉错误信息后可自由实现处理代码，而PG_FINALLY()也可以捕捉PG_TRY()中的错误信息，但是该宏的作用是为了释放报错前的一些资源，然后再重新抛出错误。PostgreSQL中PG_TRY()、PG_CATCH()、PG_FINALLY()、PG_END_TRY()这几个宏有如下限制：

- 不能在pg_try和pg_end_try之间同时使用PG_CATCH()和PG_FINALLY()
- 在代码恢复段，在弹出错误堆栈前，保持代码简单且不会产生任何错误
- FATAL不会被捕捉，将会直接调用proc_exit退出。所以如果在PG_TRY()阶段包含了FATAL错误，将不会执行到错误恢复代码阶段。如果要捕捉FATAL可以使用PG_ENSURE_ERROR_CLEANUP宏。

## 异常捕捉代码实现

​	以下几十行代码便是PostgreSQL中异常处理的宏实现，处处体现了PostgreSQL源码的精妙之处。总体看PG_TRY()和PG_END_TRY()是被do{...}while(0)代码块包围，为了让调用的每个宏像一个完整的命令，宏的实现最后都缺省了分号，所以在调用宏时，必须以分号结束。然后看PG_CATCH()和PG_FINALLY()的实现就知道了为啥它俩不能同时使用，因为这两个宏都是sigsetjmp返回不为0时执行的代码块。PG_FINALLY()中将_do_rethrow变量置为了ture，所以在PG_END_TRY()宏中会重新抛出PG_TRY()块中的错误信息。至于实现错误捕捉的的原理，主要是在报错的函数errfinish中调用了pg_re_throw函数，该函数中判断到PG_exception_stack不为空，则调用siglongjmp(*PG_exception_stack, 1)，通过siglongjmp函数，则会跳转到 PG_TRY()宏中的sigsetjmp跳转处，且返回值将为1。则会执行else中的用户使用的PG_CATCH()或者PG_FINALLY()。

```c
//src/include/utils/elog.h
#define PG_TRY()  \
	do { \
		sigjmp_buf *_save_exception_stack = PG_exception_stack; \
		ErrorContextCallback *_save_context_stack = error_context_stack; \
		sigjmp_buf _local_sigjmp_buf; \
		bool _do_rethrow = false; \
		if (sigsetjmp(_local_sigjmp_buf, 0) == 0) \
		{ \
			PG_exception_stack = &_local_sigjmp_buf

#define PG_CATCH()	\
		} \
		else \
		{ \
			PG_exception_stack = _save_exception_stack; \
			error_context_stack = _save_context_stack

#define PG_FINALLY() \
		} \
		else \
			_do_rethrow = true; \
		{ \
			PG_exception_stack = _save_exception_stack; \
			error_context_stack = _save_context_stack

#define PG_END_TRY()  \
		} \
		if (_do_rethrow) \
				PG_RE_THROW(); \
		PG_exception_stack = _save_exception_stack; \
		error_context_stack = _save_context_stack; \
	} while (0)
```



## 总结

PostgreSQL代码中异常处理基本就两套用法，一套PG_TRY()、PG_CATCH()，PG_END_TRY()搭配使用，用于错误恢复。另一套PG_TRY()、PG_FINALLY()，PG_END_TRY()的搭配使用，用于释放错误发生时持有的资源信息，然后再继续报错处理。捕捉错误信息主要使用了sigsetjmp和sigsetjmp用于错误跳转，再搭配这几个宏的精妙设计，就实现了高级语法中的错误捕捉功能。