# 网络受限地区的安装

`raw.githubusercontent.com` 和 `github.com` 在部分地区会直接断流。表现是这样几行提示，然后连接就断了。

```
Invoke-RestMethod: Received an unexpected EOF or 0 bytes from the transport stream.
```

```
curl: (28) Failed to connect to github.com port 443
```

两个安装脚本都内置了通道回退。

## 回退顺序

```
直连 → https://ghfast.top → https://gh-proxy.com
```

镜像前缀直接拼在原 URL 前面，长这样。

```
https://ghfast.top/https://github.com/mouyase/luabin/releases/download/v5.5.1/lua-5.5.1-windows-x64.zip
```

这是这类代理的标准用法，不是自定义协议。

## 指定自己的镜像

`LUABIN_MIRROR` 环境变量会把你的镜像插到最前面。

macOS 上这样写。

```sh
LUABIN_MIRROR=https://你的代理 sh install.sh
```

Windows 上这样写。

```powershell
$env:LUABIN_MIRROR='https://你的代理'; irm https://ghfast.top/https://raw.githubusercontent.com/mouyase/luabin/main/install.ps1 | iex
```

注意 `irm` 那一句本身也要能下载到脚本。如果连脚本都取不到，先用代理前缀把脚本拉下来。

```powershell
irm https://ghfast.top/https://raw.githubusercontent.com/mouyase/luabin/main/install.ps1 | iex
```

## 安全性

走第三方代理下载二进制，担心内容被替换是合理的。

保护措施是强制校验。不管走哪条通道，下载完都会去取官方 Release 的 `.sha256`，比对哈希，不一致就退出，不会把文件装进去。

实测过一次。经 `ghfast.top` 下载的 `lua-5.5.1-windows-x64.zip`，本地算出的哈希是这个值。

```
e83543c95c5fee56d41d8316d22b143318dde1be68183060dc0fb4b15912e839
```

与官方 Release 的 `.sha256` 完全一致。

代理能篡改内容的话，校验就会失败。所以它只能帮你搬运，改不了东西。

## Windows 侧为什么用 HttpClient

脚本一开始用 `Invoke-WebRequest`，配 `-TimeoutSec`。测试时发现它对某些网络故障不管用。连一个不可路由地址，设了五秒超时，它挂在那里不返回。

改成 `System.Net.Http.HttpClient`。它的 `Timeout` 是硬超时，实测设六秒、6.1 秒返回。

这个改动还带来一个好处。`HttpClient` 在拿不到响应时会抛明确的异常，能区分「连接被拒」和「超时」，日志里看得清楚是哪种失败。

## 都不通的时候

三条路。

**用 gh 命令行。** 它走的是另一套通道，实测在 curl 直连失败的环境下能下。

```sh
gh release download v5.5.1 -R mouyase/luabin -D .
```

**手动下载。** 浏览器打开 https://github.com/mouyase/luabin/releases/tag/v5.5.1 ，下对应的 zip 或 tar.gz，解压后 `bin/lua` 直接能用，不装也行。

**从源码编译。** Linux 用户本来就该这么干，三十秒的事。

```sh
curl -fsSL https://ghfast.top/https://raw.githubusercontent.com/mouyase/luabin/main/scripts/build-linux.sh | sh
```

脚本本身很小，用代理拉下来就能跑，后续下载 Lua 源码走的是 lua.org，通常不受影响。
