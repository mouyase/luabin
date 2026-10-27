# luabin

把 [Lua](https://www.lua.org/) 官方源码在 GitHub Actions 上编成 Windows 和 macOS 的预编译包。

Lua 官方只发源码。第三方预编译站 [LuaBinaries](https://luabinaries.sourceforge.net/) 更新滞后（目前最新只有 5.5.0，没有 5.5.1），macOS 包还是 Intel-only 的 macOS 10.11 目标，在 Apple Silicon 上得靠 Rosetta。这个项目补的就是这个缺口。

非官方构建，源码版权属 PUC-Rio，MIT 许可。

## 快速安装

### macOS

```sh
curl -fsSL https://raw.githubusercontent.com/mouyase/luabin/main/install.sh | sh
```

装到 `~/.local`，不需要 sudo。默认取 `PATH` 里已有的目录结构，装完提示怎么配 PATH。

也可以从 [Releases](../../releases) 直接下 `.tar.gz` 解压，或下 `.pkg` 双击安装。

### Windows

```powershell
irm https://raw.githubusercontent.com/mouyase/luabin/main/install.ps1 | iex
```

> 如果直连 GitHub 不通（报 `unexpected EOF`、`0 bytes from the transport stream`），
> 两个脚本都会自动按「直连 → ghfast.top → gh-proxy.com」顺序重试。
> 也可手动指定镜像：`$env:LUABIN_MIRROR='https://你的代理'`（Windows）或
> `LUABIN_MIRROR=https://你的代理 sh install.sh`（macOS）。
> 无论走哪条通道，最终都用官方 `.sha256` 校验。

装到 `%LOCALAPPDATA%\Programs\Lua\5.5.1`，写用户级 `PATH`，不需要管理员权限。

或从 Releases 下 `.zip` 解压，或下 `-setup.exe` 走安装向导（可装到 `Program Files`，可关联 `.lua` 文件）。

### Linux

不发预编译包，现场编译：

```sh
curl -fsSL https://raw.githubusercontent.com/mouyase/luabin/main/scripts/build-linux.sh | sh
```

约 30 秒。装到 `~/.local`，可用 `PREFIX` 环境变量改。

## 网络受限地区

`raw.githubusercontent.com` 和 `github.com` 在部分地区会直接断流（不是慢，是报
`unexpected EOF or 0 bytes from the transport stream`，PowerShell 和 curl 都一样）。

两个安装脚本内置了通道回退：

```
直连 → https://ghfast.top → https://gh-proxy.com
```

镜像前缀直接拼在原 URL 前面（`https://ghfast.top/https://github.com/...`），
这是这类代理的标准用法。可用 `LUABIN_MIRROR` 环境变量插到最前面。

**安全性**：不管走哪条通道，下载完都会拿官方 Release 的 `.sha256` 强校验，
内容被代理改动会立刻失败退出。实测过经代理下载的二进制哈希与官方完全一致。

Windows 侧用 `System.Net.Http.HttpClient` 而不是 `Invoke-WebRequest`：
后者在部分网络故障下 `TimeoutSec` 不生效（连不可路由地址会无限挂住），
`HttpClient.Timeout` 是硬超时，实测设 6 秒即 6.1 秒返回。

## 为什么 Linux 不给二进制

不是偷懒，是两条路都有硬伤。

**glibc 版会挑发行版。** glibc 的符号是版本化的。在 Ubuntu 24.04 上编出来的二进制链接的是 `GLIBC_2.39` 的符号，拿到 Debian 11 或 CentOS 7 上直接报：

```
version 'GLIBC_2.38' not found
```

要覆盖全部发行版得在最老的容器里构建（`debian:bullseye` 之类），还要为每个发行版测一遍。

**musl 静态版会废掉 `dlopen`。** 全静态 musl 编译出来的二进制确实是单文件、任何内核都能跑，但静态链接后 `dlopen` 不可用。而 Lua 的 `require` 加载 C 扩展（`lfs`、`luasocket`、`lpeg`）走的正是 `dlopen`，静态版会让这批库全部失效。

取舍是：**能装 C 扩展但挑发行版**，或**到处能跑但只能用纯 Lua 模块**。既然编译只要 30 秒，把选择权交给用户更诚实。

## 产物清单

每次构建产出：

| 平台 | 架构 | 文件 |
|---|---|---|
| macOS | arm64 | `lua-5.5.1-macos-arm64.tar.gz` |
| macOS | arm64 | `lua-5.5.1-macos-arm64.pkg` |
| macOS | x64 | `lua-5.5.1-macos-x64.tar.gz` |
| macOS | x64 | `lua-5.5.1-macos-x64.pkg` |
| Windows | x64 | `lua-5.5.1-windows-x64.zip` |
| Windows | x64 | `lua-5.5.1-windows-x64-setup.exe` |
| Windows | arm64 | `lua-5.5.1-windows-arm64.zip` |
| Windows | arm64 | `lua-5.5.1-windows-arm64-setup.exe` |

每个文件附 `.sha256`，Release 里另有汇总的 `SHA256SUMS.txt`。

## 包内结构

```
bin/lua         解释器
bin/luac        字节码编译器
bin/lua55.dll   Windows 的动态库
include/        lua.h luaconf.h lualib.h lauxlib.h lua.hpp
lib/liblua.a    静态库（Windows 另有 lua55.dll.a 导入库）
share/lua/5.5/  纯 Lua 模块安装位置
LICENSE         Lua 的 MIT 许可
README-lua.html 官方文档
BUILD-INFO      构建元数据（架构、编译器、时间）
```

## 成本

公共仓库的标准 GitHub-hosted runner **免费且不限量**，包括 Windows 和 macOS。

这 5 个 job 里最慢的是两个 Windows（MSYS2 装包）和两个 macOS（跑完整测试套件），整套跑完约 10 分钟。Lua 本身编译只要十几秒。

私有仓库按分钟计费：Linux $0.006、Windows $0.010、macOS $0.062。

## 触发

```sh
# 手动，可指定版本
gh workflow run build --field version=5.5.1

# 打 tag 自动构建并发布
git tag v5.5.1 && git push origin v5.5.1
```

PR 也会构建，只上传 artifact 不发布。

## 实现要点

这些都是实际踩过并验证的，改动时别拆掉。

### 源码单点下载

`source` job 下载一次官网 tarball、算 sha256，其余 job 通过 artifact 复用同一份文件并硬校验哈希。避免 5 个 job 各自下载、各自可能拿到不同内容。

### macOS 必须显式指定部署目标

`make macosx` 默认继承构建机的 SDK 版本。CI 上跑出来是 `minos 27.0`，只有最新系统能装。脚本强制 `MACOSX_DEPLOYMENT_TARGET=11.0`，并在打包后断言 `otool -l` 里的 `minos` 不超过目标值。

### 不能对 `posix` 目标传 `SYSCFLAGS`

```make
posix:
	$(MAKE) $(ALL) SYSCFLAGS="-DLUA_USE_POSIX"
```

recipe 内部重新赋值 `SYSCFLAGS`，命令行传进去的 `-DLUA_USE_LINUX` 会被整个吃掉。实测 `make -n` 输出里只剩 `-DLUA_USE_POSIX`，`LUA_USE_DLOPEN` 丢失，`require` 加载 C 扩展会失效。Linux 侧直接用 `make linux`。

### mingw 目标只覆盖 `CC`

```make
mingw:
	$(MAKE) "LUA_A=lua55.dll" ... \
	"AR=$(CC) -shared -o" "RANLIB=strip --strip-unneeded" ...
```

它借用 `$(CC)` 把 `.o` 直接链成 DLL，`AR`/`RANLIB` 是 recipe 内的命令行赋值。外层若也传 `AR=`/`RANLIB=` 会和这些赋值打架，容易产出错架构或空 DLL。只传 `CC=x86_64-w64-mingw32-gcc` 最稳，recipe 里的 `$(CC)` 会自动展开成带前缀的交叉编译器。

### Windows 不复用 `all.lua`

官方测试套件默认假设 Linux（`/dev/full`、`/dev/null`、fork、符号链接、chmod 检查）。Windows 上跑 `all.lua` 必然挂一堆与编译质量无关的用例。改跑 15 个与编译器/ABI/运行时相关的核心用例。

### macOS 要摘掉一段测试

`files.lua` 里这段在 macOS 必然失败：

```lua
do print("testing flush")
  local f = io.output("/dev/full")
```

`/dev/full` 是 Linux 专有设备节点，而且这段没有 `_port` 守卫（`_port=true` 跳不过去）。脚本用 perl 正则把整块删掉，其余全部照跑，最终 `all.lua` 输出 `final OK !!!`。

### Lua 的 `gsub` 返回两个值

```lua
io.write(_VERSION:gsub("Lua ",""))     -- 错，得到 "5.51"
io.write((_VERSION:gsub("Lua ","")))   -- 对，外层括号截断
```

第二个返回值是替换次数。实际踩过，产物目录变成 `share/lua/5.51/`。

### readline 判定要编译探针

Linux 上不能只看 `/usr/include/readline/readline.h` 是否存在。`linux-readline` 目标会真的 `-lreadline` 链接，头文件在但库缺失（或反之）在精简镜像上常见。脚本实际编译一个最小程序做探针，两边都通才启用。

没有 readline 时自动降级到 `make linux`，产物只依赖 libc。

### Inno Setup 的中文语言文件

位置在各版本间变过：

- 6.7+ → `Languages\ChineseSimplified.isl`
- 6.5.x → `Languages\Unofficial\ChineseSimplified.isl`

用 `FileExists` 做条件编译，找不到就只保留英文，保证 `ISCC` 一定能编过。另外 `.iss` 含中文必须存成 **UTF-8 with BOM**，否则 Inno 按本地代码页读会乱码。

### pkgbuild 的 `write: Permission denied`

生成 Bom 时会打四条这个警告，用最小用例也能复现，是 `pkgbuild` 在系统路径上的固有行为，不影响产物。验证方式是 `pkgutil --payload-files` 确认文件齐全、`lsbom` 确认权限位是 `100755`。

## 不签名的代价

Windows 和 macOS 都没买签名证书，所以：

**macOS**，浏览器下载的 `.pkg` / `.tar.gz` 会带 `com.apple.quarantine` 扩展属性，双击被 Gatekeeper 直接拒绝（不是警告，是打不开）。但 **`curl` 下载不带这个标记**（实测 `xattr` 输出为空），所以 `install.sh` 这条路径完全不受影响。README 和 Release 说明都把脚本列为首选。

**Windows**，未签名的 `.exe` 触发 SmartScreen 的「更多信息 → 仍要运行」，属于警告而非拦截，比 macOS 宽松。

真要做正经分发，需要 Apple Developer Program（$99/年）做签名+公证，Windows 需要 Azure Trusted Signing（约 $10/月）或 EV 证书配云 HSM。这两笔都不在预算内。

## 分支策略

版本靠 workflow 的 `version` 输入单点控制，没有矩阵化多版本。要同时出 5.4 和 5.5，得在 workflow 里加一层 `matrix.version`，工作量不大但会让 job 数翻倍。

LuaJIT 不在范围内。它是独立实现（不是 Lua 的分支），固定 5.1 语义，ABI 与官方 Lua 不兼容，上游没有 tag 只能锁 commit hash。要覆盖它应该独立一个仓库，别混进同一个矩阵。

## License

打包脚本和 workflow 是本项目的，随便用。

Lua 本身是 MIT，版权属 PUC-Rio，见 [lua.org/license.html](https://www.lua.org/license.html)。每个分发包里都带了完整许可文本。
