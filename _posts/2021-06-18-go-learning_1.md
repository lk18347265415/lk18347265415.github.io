---

layout: post
title:  "go learning_1"
date:   2021-06-18 19:06:00 +0800
categories: [go]

---

> **变量、类型和保留字**

Go内置变量类型：

```
//数字类型
uint8		uint16		uint32	uint64	int8
int16		int32		int64	flat32	flat64	
complex64	complex128	byte	rune	uint
int			uintptr		bool	string
```

注：rune是int的别名

Go同其他语言不同的地方在于变量的类型在变量的后面。不是：int a,而是 a int.且默认赋值为变量类型的null值。那么var a int后，a的值为0，而var s strin意味着s被赋值为零长度字符串，即“”。且Go中声明和赋值两个过程可以连在一起，如下：

```go
//用例1：								//用例2（声明和定义连在一起，变量的类型由值推演出来，这一形式只可用在函数内）：
var a int								a := 15
var b bool 								b := false
a = 15
b = false
//============================
//var声明可以成组：
var(
	x int
    b bool
)
//相同类型的多个变量可以在一行内完成声明：var x,y int 让x和y都是int类型变量，同样可以使用平行赋值：
a, b = 20,16
//特殊变量_(下划线)，任何赋给它的值都被丢弃。在这个例子中将35赋值给b，同时丢弃34：
_, b := 34, 35
//常量constant,在编译时被创建，只能是数字、字符串或布尔值；const x = 42生成x这个常量。可以使用itoa生成枚举值：
const (
	a = itoa
	b = itoa        //第一个之后的= itoa可以省略不写
)
//数组的用法
var a []int			//声明个int类型的数组a
s := "hello"
c := []byte(s)		//将s转换为字节数据
c[0] = 'c'			//修改数组的第一个元素
s2 := string(c)		//创建新的字符串s2保存修改
//slice（引用类型）用法0，slice和array接近，但是在新的元素加入的时候可以增加长度，slice总是指向底层的一个array，所有slice和array成对出现
//引用类型使用make创建
sl := make([]int,10)	//创建了一个保存有10个元素的slice

```

> **Go保留关键字**

```
break		default		func	interface	select
case		defer		go		map			struct
chan		else		goto	package		switch
const		fallthrough	if		range		type
continue	for			import	return		var
```

- func用于定义函数和方法
- go用于并行
- select用于选择不同类型的通讯
- interface用于定义接口类型
- struct用于抽象数据类型
- range（迭代器）可用于循环，可用在slice、array、string、map和channel

> **内建函数**

Go内建函数的引用不需要任何包就可以使用，以下列出了所有的内建函数：

```
close	new		panic	complex
delete	make	recover	real
len		append	print	imag
cap		copy	println
```

- close用于channel通讯，使用它来关闭channel
- delete用于在map中删除实例
- len和cap用于不同的类型，len用于返回字符串、slice和数组长度。cap返回slice长度（左指针到array尾的长度）
- new用于各种类型的内存分配
- make用于内建类型（map、slice和channel）的内存分配
- copy用于赋值slice，append用于追加slice
- panic和recover用于异常处理机制
- complex、real和imag用于处理复数

------

> **总结**

Go变量的声明和C中的变量声明形式相反，即变量名在类型名前面，且变量可以平行赋值（即没有逗号模式），_(下划线变量)为特殊变量，赋予它的值都会被丢弃。表达式的左大括号不能单独起一行，必须与表达式在统一行（Go硬性语法规定）。Go和C的另一个明显区别是C以分号结束一个表达式，而Go表达式后不需要分号。