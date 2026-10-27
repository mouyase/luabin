# 构建实现说明

流水线的形状，以及每个地方为什么要这么写。这些都是实际跑出来的结论，改代码前先看一眼。

## 流水线结构

五个 job，一条链。

`source` 从 `lua.org/ftp/` 下载一次官方 tarball，算出 sha256，上传成 artifact。后面所有平台都从这一个 artifact 取源码，并在开工前校验哈希。

这么做的原因是并行。四个平台 job 同时跑，各自下载的话就同时向 lua.org 发四个请求，还可能拿到不同时刻的文件。单点下载把不确定因素收成一处。

`build-macos` 和 `build-windows` 各自走矩阵，`verify-linux-script` 在 `debian:bookworm-slim` 里跑一遍那个 Linux 编译脚本。Linux 不发二进制，但脚本必须保证能用，否则这条路径就是死的。

`release` 只在 tag 推送时执行，汇总所有 artifact 并生成 Release。

## macOS

### 部署目标必须显式指定

`make macosx` 默认继承构建机的 SDK 版本。CI 上跑出来的是 `minos 27.0`，只有最新系统能装。这在本地开发机上完全看不出来，本机装的就是最新系统。

脚本强制 `MACOSX_DEPLOYMENT_TARGET=11.0`，并在打包后断言 `otool -l` 里的 `minos` 不超过目标值。断言这一步不能省，环境变量被后续步骤覆盖的情况我遇到过。

### 交叉编译的两个坑

`macos-15-intel` 是原生 Intel runner，不需要交叉编译。但如果要在 arm64 机器上出 x64 包，有两处会绊住。

**环境变量的 `CFLAGS` 无效。** `src/Makefile` 里有这么一行。

```make
CFLAGS= -O2 -Wall -Wextra $(SYSCFLAGS) $(MYCFLAGS)
```

这是 make 赋值，会直接覆盖环境变量里传进来的 `CFLAGS`。`export CFLAGS="-arch x86_64"` 编出来还是宿主架构。必须走命令行参数。

**命令行参数不能被空格拆开。** 下面这样写是错的。

```sh
MAKE_ARGS="CFLAGS=-O2 -Wall -Wextra -arch x86_64"; make macosx $MAKE_ARGS
```

`$MAKE_ARGS` 展开后按空格分成五个参数，`-Wall` 被 make 当成自己的选项，报 `invalid option -- a`。正确写法得用位置参数。

```sh
set -- "CFLAGS=-O2 -Wall -Wextra -arch x86_64"; make macosx "$@"
```

**`-arch x64` 是无效的。** clang 只认 `x86_64`。产物命名用 `x64` 是业界习惯，传给编译器和 `hostArchitectures` 必须映射。脚本里 `ARCH` 和 `MACHO_ARCH` 是两个变量，就是为这个。

### pkg 的构建

`pkgbuild --root` 要求目录树就是最终安装树，所以先把 stage 内容按 `/usr/local` 结构铺好，再打组件包，最后用 `productbuild` 套一层带欢迎页的分发配置。

`--distribution` 必须传真实文件路径。进程替换 `<(...)` 是 bash 专有语法，POSIX sh 下不成立，脚本里是先写 XML 文件再引用。

安装包的架构字段要用 Mach-O 的名字，`x86_64` 或者 `arm64`，写 `x64` 会被判定不兼容。

```
hostArchitectures="x86_64"    ← 正确
hostArchitectures="x64"       ← 错误，安装器判定不兼容，直接拒绝安装
```

这个错了不会有任何报错提示，表现只是用户装不上。

### pkgbuild 那四条警告

生成 Bom 时会打四条 `write: Permission denied`。用最小用例也能复现。

```sh
mkdir -p mini/root/usr/local/bin && echo x > mini/root/usr/local/bin/t && chmod 755 mini/root/usr/local/bin/t && pkgbuild --root mini/root --identifier t.t2 --version 1.0 --install-location / mini/t.pkg
```

这样连下来是一条命令，复制粘贴就能跑。照样四条。这是 `pkgbuild` 在系统路径上的固有行为，与产物无关。判断产物是否正常要看两个地方，一是 `pkgutil --payload-files` 的文件清单，二是 `lsbom` 输出的权限位，`bin/lua` 应该是 `100755`。

## Windows

### mingw 目标只覆盖 CC

Lua 的 mingw 目标内部自己指定了这些参数。

```make
mingw:
	$(MAKE) "LUA_A=lua55.dll" "LUA_T=lua.exe" \
	"AR=$(CC) -shared -o" "RANLIB=strip --strip-unneeded" ...
```

它借用 `$(CC)` 把 `.o` 直接链成 DLL。`AR` 和 `RANLIB` 是 recipe 内的命令行赋值，优先级高于外层传入的同名变量。外层如果再传 `AR=` 或 `RANLIB=`，会和 recipe 内的赋值打架，产出错架构或空 DLL 都有可能。

只传 `CC` 最稳。recipe 里的 `$(CC)` 会自动展开成你给的那个编译器，交叉前缀跟着一起过去。

### 编译器名字各环境不同

MSYS2 有三套环境，编译器的名字各不相同。

| 环境 | 编译器 |
|---|---|
| MINGW64 | `x86_64-w64-mingw32-gcc` |
| UCRT64 | `gcc` |
| CLANGARM64 | `aarch64-w64-mingw32-gcc` |

硬编码任何一个前缀都会绑死在某套环境上。脚本改成先试 `gcc`，再退回带前缀的形式，三套都能用。

MINGW64 的 MSVCRT 运行时已被 MSYS2 标记为 deprecated，所以 x64 那条线现在跑在 UCRT64 上。

### 架构检查不用 objdump

`objdump` 不在 `mingw-w64-*-gcc` 包里，binutils 是独立包。CI 上直接报 `command not found`。

改成直接读 PE 头。偏移 60（0x3C）处是 4 字节的 `e_lfanew`，指向 `PE\0\0` 签名，签名后紧跟 2 字节的 Machine 字段，取值是这样。

```
0x8664 = x86-64
0xAA64 = ARM64
0x014C = i386
```

`od` 是 POSIX 工具，MSYS2 的 base 包自带。

还有个容易误判的地方。`setup.exe` 自己的 PE 头是 `0x014C`，两个架构都是。这是 Inno Setup 的 32 位引导程序，跟它打包的内容无关。别拿它当架构检查的依据。

### DLL 导出检查用字符串搜

一开始用 `nm -g` 找 `luaL_newstate`，UCRT64 下报缺少符号，但 `strings` 明明能搜到。

原因是 PE 的导出表不是普通符号表，`nm` 对 DLL 的输出随 binutils 版本和构建配置变化很大。改成就用 `grep -a` 在 DLL 里搜名字。导出表本身以明文存放符号名，这个判定稳定。

### MSYS2 的路径 PowerShell 不认

`build-windows.sh` 跑在 MSYS2 里，`$PWD` 是 `/c/a/luabin/...` 这种形式。写进交接文件后，PowerShell 的 `Test-Path` 认不出来，报「stage 目录不存在」。

必须用 `cygpath -w` 转成 `C:\a\luabin\...` 再写。脚本里留了手写退路，注意 `cut -c3-` 会吃掉盘符后的分隔符，得自己补回来，否则 `c:\luabin` 变成 `c:luabin`。

### Inno Setup

**架构标识符不是 `x64`。** 有效值是 `x64compatible`、`arm64`、`x86compatible` 这些。传 `x64` 会让 Setup 直接报错退出。`ArchitecturesAllowed` 和 `ArchitecturesInstallIn64BitMode` 取值规则一样。

**中文语言文件的路径变过。**

```
6.7+   → Languages\ChineseSimplified.isl
6.5.x  → Languages\Unofficial\ChineseSimplified.isl
```

旧版本可能根本没带。用 `FileExists` 做条件编译，找不到就只保留英文，保证 `ISCC` 一定能编过。

**`.iss` 含中文必须存成 UTF-8 with BOM。** 否则 Inno 按本地代码页读，向导里的中文全是乱码。

## Linux

不给二进制，只给编译脚本。原因见 [why-no-linux-binaries.md](why-no-linux-binaries.md)。

### readline 判定要编译探针

只检查 `/usr/include/readline/readline.h` 存不存在不够。`linux-readline` 目标会真的 `-lreadline` 链接，头文件在但库缺失（或者反过来）在精简镜像上很常见。

脚本实际编译一个最小程序做探针，两句都通才启用。探针失败就降级到 `make linux`，产物只依赖 libc。

### 不能对 posix 目标传 SYSCFLAGS

```make
posix:
	$(MAKE) $(ALL) SYSCFLAGS="-DLUA_USE_POSIX"
```

recipe 内部重新赋值 `SYSCFLAGS`，命令行传进去的 `-DLUA_USE_LINUX` 会被整个吃掉。`make -n` 的输出里只剩 `-DLUA_USE_POSIX`。

后果是 `LUA_USE_DLOPEN` 丢失，`require` 加载 C 扩展（`.so`）会静默失效。编是不会报错的，跑起来才发现。Linux 侧直接用 `make linux`。

## 测试套件的取舍

### macOS 要摘掉一段

`files.lua` 里这段在 macOS 必然失败。

```lua
do print("testing flush")
  local f = io.output("/dev/full")
```

`/dev/full` 是 Linux 专有设备节点，macOS 没有。而且这段没有 `_port` 守卫，`_port=true` 跳不过去。脚本用 perl 正则把整块删掉，其余全部照跑，最终 `all.lua` 输出 `final OK !!!`。

### Windows 不复用 all.lua

官方套件默认假设 Linux 环境，会用到 `/dev/full`、`/dev/null`、fork、符号链接、chmod 检查。Windows 上跑必然挂一堆与编译质量无关的用例，而且失败信息会把真正的编译问题埋掉。

改跑 15 个与编译器、ABI、运行时相关的核心用例，包括 `constructs`、`calls`、`closure`、`strings`、`math`、`sort`、`coroutine`、`vararg`、`nextvar`、`events`、`bitwise`、`goto`、`locals`、`tpack`、`utf8`。

## 语言层面的坑

### gsub 返回两个值

```lua
io.write(_VERSION:gsub("Lua ",""))     -- 得到 "5.51"
io.write((_VERSION:gsub("Lua ","")))   -- 得到 "5.5"
```

`string.gsub` 返回替换结果和替换次数两个值。作为函数参数时只有最后一个位置的函数调用会展开成多值，`io.write` 收到的就是两个参数。外面套一层括号截断成单值。

实际踩过。产物目录变成 `share/lua/5.51/`。

### 交叉编译时不要执行产物

读版本号、跑自检、跑测试套件，都要执行刚编出来的二进制。交叉编译时这是做不到的，arm64 机器上跑不了 x86_64 产物（没装 Rosetta 的话直接 `Bad CPU type in executable`）。

脚本里有个 `CAN_RUN` 判断。不同架构且跑不起来时，跳过自检和测试套件并说明原因，打包照常进行。版本号从 `VERSION` 变量推导，不靠执行取 `_VERSION`。

CI 上每个架构都有原生 runner，所以这些检查会正常执行。本地验证交叉编译时会看到跳过提示，属于预期。

## 发布

### 源码包必须排除

`lua-5.5.1.tar.gz` 和产物 `lua-5.5.1-macos-arm64.tar.gz` 通配相同，`find -name '*.tar.gz'` 会把源码也收进 Release。

第一次修用了 `needs.source.outputs.version` 拼排除名，但 release job 里那个 output 取不到，变量变空，`! -name ""` 就失去意义。改用 workflow 级 `env.LUA_VERSION`，并加一道 `rm -f` 兜底。

### sha256 文件要一起发

`install.sh` 和 `install.ps1` 会去 Release 下载 `<file>.sha256` 做校验。只发二进制会导致校验永远取不到文件，退化成「跳过校验」而不是报错，很难发现。

## 脚本编写注意事项

### $var 后面紧跟中文要加花括号

这是 macOS 自带 bash 3.2 的坑。写过这么一行。

```sh
info "下载成功（$label）"
```

崩溃信息长这样。

```
install.sh: line 155: label\xef\xbc\x89: unbound variable
```

全角括号 `）` 是多字节字符，旧版 bash 会把它当成变量名的一部分，变量名就被解析成 `label）`。

加花括号就行。

```sh
info "下载成功（${label}）"
```

新版本 bash 不受影响，所以这个问题只在 macOS 系统自带的 `/bin/sh` 上暴露。

### 列表里的空串会被吃掉

镜像列表里用空串代表直连，`for x in $LIST` 展开时空串直接消失，"直连"那一项静默不见。改用 `@DIRECT` 占位再还原。

### while read 可能跑在子 shell

`while ... done <<EOF` 在部分 sh 实现里会让循环体跑在子 shell，`break`、变量赋值都可能丢。遍历列表用 `for` 更稳。

## 成本

公共仓库的标准 GitHub-hosted runner 免费且不限量，Windows 和 macOS 一样。

这五个 job 里最慢的是两个 Windows（MSYS2 装包占大头）和两个 macOS（跑完整测试套件）。整套跑完十分钟左右，Lua 本身编译只要十几秒。

私有仓库按分钟计费，Linux $0.006、Windows $0.010、macOS $0.062。
