# luabin

把 [Lua](https://www.lua.org/) 官方源码编成 Windows 和 macOS 的预编译包。

Lua 官方只发源码。第三方预编译站 [LuaBinaries](https://luabinaries.sourceforge.net/) 更新滞后，目前最新只有 5.5.0，没有 5.5.1，macOS 包还是 Intel-only 的 10.11 目标，在 Apple Silicon 上得靠 Rosetta。这个项目补的就是这个缺口。

非官方构建。源码版权属 PUC-Rio。

## 安装

### macOS

```sh
curl -fsSL https://raw.githubusercontent.com/mouyase/luabin/main/install.sh | sh
```

装到 `~/.local`，不需要 sudo。

### Windows

```powershell
irm https://raw.githubusercontent.com/mouyase/luabin/main/install.ps1 | iex
```

装到 `%LOCALAPPDATA%\Programs\Lua\5.5.1`，写用户级 `PATH`，不需要管理员权限。

### Linux

不发预编译包，现场编译，约 30 秒能完。

```sh
curl -fsSL https://raw.githubusercontent.com/mouyase/luabin/main/scripts/build-linux.sh | sh
```

### 直连不通

GitHub 在部分地区会直接断流。两个安装脚本都会自动按「直连 → ghfast.top → gh-proxy.com」重试，也可以自己指定镜像。

```sh
LUABIN_MIRROR=https://你的代理 sh install.sh
```

走哪条通道都会用官方 `.sha256` 强校验，内容被改会立刻失败。细节见 [docs/network-restricted.md](docs/network-restricted.md)。

## 产物

| 平台 | 架构 | 文件 |
|---|---|---|
| macOS | arm64 | `.tar.gz` / `.pkg` |
| macOS | x64 | `.tar.gz` / `.pkg` |
| Windows | x64 | `.zip` / `-setup.exe` |
| Windows | arm64 | `.zip` / `-setup.exe` |

每个文件附 `.sha256`，Release 里另有 `SHA256SUMS.txt`。包内有 `bin/lua`、`bin/luac`、C 头文件、`liblua.a`，Windows 另有 `lua55.dll`。不想跑安装脚本的话，直接从 [Releases](../../releases) 下载解压，`bin/lua` 就能用。

## 构建

```sh
# 手动跑，可指定版本
gh workflow run build --field version=5.5.1

# 打 tag 自动构建并发布
git tag v5.5.1 && git push origin v5.5.1
```

公共仓库的标准 runner 免费且不限量，整套跑完约 10 分钟。

## 文档

- [构建实现说明](docs/build-notes.md)，讲流水线结构、各平台的坑、测试套件的取舍
- [为什么 Linux 不给二进制](docs/why-no-linux-binaries.md)，关于 glibc 与 musl 的两难
- [网络受限地区的安装](docs/network-restricted.md)，讲镜像回退与校验机制
- [不签名的代价](docs/unsigned-distribution.md)，Gatekeeper 与 SmartScreen 的实际表现

## 适用范围

只构建官方 Lua，不含 LuaJIT。LuaJIT 是独立实现，固定 5.1 语义，ABI 与官方 Lua 不兼容，上游没有 tag 只能锁 commit hash，要覆盖它应该另开仓库。

目前单版本控制，没有矩阵化多版本。要同时出 5.4 和 5.5 得在 workflow 里加一层 `matrix.version`。

## License

本项目的打包脚本和 workflow 用 [MIT](LICENSE)。

Lua 本身也是 MIT，版权属 PUC-Rio，见 [lua.org/license.html](https://www.lua.org/license.html)。每个分发包里都带了完整许可文本。
