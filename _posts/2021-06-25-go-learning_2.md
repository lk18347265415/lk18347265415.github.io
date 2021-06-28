---
layout:	post
title:	"go learning_2"
date:	2021-06-25 22:09:00 +0800
categories: [go]
---

> **函数定义**

函数是构建Go 程序的基础部件，很多有趣的事情都是在它其中发生的。函数的定义看起来像这样：

```go
type mytype int			//新的类型

func(p mytype) funcname(q int)(r,s int){ return 0,0}
//	func:		定义函数关键字
//	(p mytype):	函数可以定义用于特定的类型，这类函数也称作method,这部分被称为receiver且是可选项。
//	funcname:	函数名
//	(q int):	函数入参，参数用pass-by-value方式传递（参数会被复制）
//	(r,s int):	函数返回值，GO和C的不同是，Go可以返回多个值
//	{ return 0,0 }:该部分是函数实现体
```

> **函数用法**

| 函数用法                                                    | 描述                                     |
| ----------------------------------------------------------- | ---------------------------------------- |
| [函数作为另一个函数的实参](#函数作为另一个函数的实参的实例) | 函数定义后可以作为另外一个函数的实参传入 |
| [闭包](#闭包实例)                                           | 闭包是匿名函数，可在动态编程中使用       |
| [方法](#方法实例)                                           | 方法就是一个包含了接受者的函数           |

## 函数作为另一个函数的实参的实例

```go
package main
import(
	"fmt"
    "math"
)
func mian(){
    /*声明函数变量*/
    getSquareRoot := func(x float64)float64{
        return math.Sqrt(x)
    }
    /*使用函数*/
    fmt.println(getSquareRoot(4))
}
//总结：这和C语言中的回调函数使用方法基本一致
```

## 闭包实例

```go
//Go支持闭包。闭包可以是一个函数里边返回的另一个匿名函数，该匿名函数包含了定义在它外面的值
func getSequence() func() int{
    i := 0
    return func() int {
        i+=1
        return i
    }
}
func main(){
    //nextNumber为一个函数
    nextNumber := getSquence()
}
```

##  方法实例

```go
//在Go语言中，可以给任意类型（包括内置，但不包括指针类型）添加相应的方法。
type Integer int	//新类型Integer

func (a Integer)Less(b Integer)bool{
    return a < b
}
//Integer和int没有本质区别，只是它为内置的int类型增加了一个新方法Less（）。
//可以像使用一个普通的类一样
func mian(){
    var a Integer = 1
    if a.Less(2){
        fmt.println(a,"Less 2")
    }
}
```

