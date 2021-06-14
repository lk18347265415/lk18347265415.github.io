---
layout: post
title:  "why there has $$ signs in plpgsql"
date:   2021-05-24 16:18:23 +0800
categories: [postgres]
---


## `Introduction`

In PG,Procedure language blocks are always surrounded by the  "$$" sign or single quotes.But oracle does not.Why is PG designed like this? Let's take a look at the difference between oralce and postgreSQL's PL function:

{% highlight sql %}

CREATE FUNCTION sales_tax(subtotal real) RETURNS real AS $$
BEGIN
	RETURN subtotal * 0.06;
END;
$$ LANGUAGE plpgsql;

{% endhighlight %}

{% highlight sql %}

CREATE FUNCTION sales_tax(subtotal real) RETURN real AS
BEGIN
	RETURN subtotal * 0.06;
END;
/

{% endhighlight %}

## Why there need "$$" signs

The direct reason is that the backend parser does not want to parse the PL BLOCK which is surrounded by double-dollar signs. They just want to directly pass the original PL BLOCK to PL/pgsql for processing. But what should the backend parser do? The answer is as follows,Parser mudle just pass the PL BLOCK to the plpgsql modle,and do nothing else.

![dollar](.dollar.png)

The psql interactive client also requires double-dollar signs here. Because before there is no double-dollar signs,the psql client will think that the sql input is complete when it meets a semicolon.But now a function/procedure has mutiple semicolons.So the double-dollar signs has become the psql client to handle sql statements with mutiple semicolons.

