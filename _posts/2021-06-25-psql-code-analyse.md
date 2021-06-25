---
layout:	post
title:	"psql-code-analyse"
date:	2021-06-25 22:24:00 +0800
categories:	[postgres]
---

> **psql简介**

psql客户端为postgreSQL默认自带的交互式客户端，通过psql客户端我们可以很轻松的与postgreSQL互动。今天我们就来分析其源代码。

以下为精简后的psql源码(startup.c)：

```c
int
main(int argc, char *argv[])
{
    ...		//查看psql参数是否为-?或者--help,如果是就调用usage输出帮助信息
	pset.progname = get_progname(argv[0]);//获取项目psql的名称
    setDecimalLocale();//设置和获取地域化信息 。主要结构体struct lconv。实现函数 extlconv = localeconv()
	PQenv2encoding();	//从环境变量PGCLIENTENCODING获取编码信息
	EstablishVariableSpace();//创建struct_variable空间并设置钩子函数
    SetVariable(...);//给指定变量赋值，如果存在，更新并返回
    parse_psql_options(argc, argv, &options);//解析命令行参数并存储在options中
	PQconnectdbParams(keywords, values, true);//连接PG
    if(cell->action == ACT_SINGLE_QUERY)
    {
		successResult = SendQuery(cell->val)//如果psql加了-c指定了执行某固定query则直接在这里发送至后台
    }else if（cell->action == ACT_SINGLE_SLASH）{//也是指定了-c选项，但是query是以“\\”开头
        HandleSlashCmds(...);//功能命令
    }
    MainLoop(stdin)//进入交互式终端，循环处理交互命令
    {
        createPQExpBuffer(...);//创建空间保存query、当前和历史命令
		while(successResult == EXIT_SUCCESS)  //主要循环
        {
			get_prompt(prompt_status, cond_stack);//获取交互终端提示符，如字符串“postgres=# ”
 			gets_interactive();//获取行--主要为调用result = readline((char *) prompt),注意result返回的不包含提示符，值获取输入行内容
			...//检查result是不是quit、exit、help命令
            psql_scan_setup(...);//解析输入行内容，查找命令分隔符，使用了了lex技术
            while (success || !die_on_error)//该循环用于判断内容是否满足发送条件
            {
                psql_scan(scan_state, query_buf, &prompt_tmp);//使用lex分析解析行，返回状态（PSCAN_SEMICOLON、,PSCAN_EOL等）
				if(PSCAN_SEMICOLON);//遇见分号就发送至后端
                {
                    pg_append_history;
                    pg_send_history(history_buf);//   将命令存储在历史命令中
					SendQuery(query_buf->data);//将数据发送至后台
                }else if(PSCAN_BACKSLASH){ //处理"\"开头的功能命令
                	HandleSlashCmds;//处理功能命令
                }
            }
        }
    }
}
```

> **get_promt函数**

该函数根据第一个参数的状态来确定选择提示符（pset.prompt1、pset.prompt2或者pset.prompt3）和通过psql_scan函数获取prompt_status.

> **总结**

psql客户端通过两个while循环实现了psql的交互功能，其中比较重要的一个函数是psql_scan_setup，该函数会解析（通过lex来解析：psqlscan.l）终端输入的内容，根据该函数的返回值确定是否需要将数据发送至后端。

