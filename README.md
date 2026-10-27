# luabin

把 [Lua](https://www.lua.org/) 官方源码编成 Windows 和 macOS 的预编译包，覆盖 5.1 到 5.5 各个系列。

Lua 官方只发源码。第三方预编译站 [LuaBinaries](https://luabinaries.sourceforge.net/) 更新滞后，macOS 包还是 Intel-only 的 10.11 目标，在 Apple Silicon 上得靠 Rosetta。

非官方构建。源码版权属 PUC-Rio。

## 安装

macOS 装到 `~/.local`，Windows 装到 `%LOCALAPPDATA%\Programs\Lua\<版本>`，都不需要管理员权限。

### macOS

```sh
curl -fsSL https://raw.githubusercontent.com/mouyase/luabin/main/install.sh | sh
```

指定版本（默认装最新的 5.5.1）。

```sh
curl -fsSL https://raw.githubusercontent.com/mouyase/luabin/main/install.sh | sh -s 5.4.9
```

### Windows

```powershell
irm https://raw.githubusercontent.com/mouyase/luabin/main/install.ps1 | iex
```

指定版本。

```powershell
$env:LUABIN_VERSION='5.4.9'; irm https://raw.githubusercontent.com/mouyase/luabin/main/install.ps1 | iex
```

### Linux

不发预编译包，现场编译，约 30 秒。

```sh
curl -fsSL https://raw.githubusercontent.com/mouyase/luabin/main/scripts/build-linux.sh | sh
```

指定版本。

```sh
curl -fsSL https://raw.githubusercontent.com/mouyase/luabin/main/scripts/build-linux.sh | sh -s 5.4.9
```

GitHub 直连不通的话，脚本会自动按「直连 → ghfast.top → gh-proxy.com」重试，也可以自己指定 `LUABIN_MIRROR`。走哪条通道都会用官方 `.sha256` 强校验。

也可以直接从 [Releases](../../releases) 下载解压，`bin/lua` 就能用。

## 文档

- [构建实现说明](docs/build-notes.md)，流水线结构、各平台的坑、测试取舍
- [版本覆盖范围](docs/version-matrix.md)，编了哪些版本、为什么这么选
- [为什么 Linux 不给二进制](docs/why-no-linux-binaries.md)，glibc 与 musl 的两难
- [网络受限地区的安装](docs/network-restricted.md)，镜像回退与校验机制
- [不签名的代价](docs/unsigned-distribution.md)，Gatekeeper 与 SmartScreen 的实际表现

## License

本项目的打包脚本和 workflow 用 [MIT](LICENSE)。Lua 本身也是 MIT，版权属 PUC-Rio，见 [lua.org/license.html](https://www.lua.org/license.html)，每个分发包里都带了完整文本。
