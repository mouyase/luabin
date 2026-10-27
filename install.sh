#!/usr/bin/env sh
# luabin — macOS / Linux 一键安装（下载预编译包）
#
# 用法:
#   curl -fsSL https://raw.githubusercontent.com/mouyase/luabin/main/install.sh | sh
#   sh install.sh [version]
#
# 默认行为:
#   macOS  → 从 GitHub Release 下载对应架构的 .tar.gz 到 $HOME/.local
#   Linux  → 没有预编译包，转发到 build-linux.sh 现场编译
#
# 环境变量:
#   LUABIN_VERSION   Lua 版本，默认 5.5.1
#   PREFIX           安装前缀，默认 $HOME/.local
#   LUABIN_REPO      OWNER/REPO，默认 mouyase/luabin
#   LUABIN_FORCE     设为 1 时覆盖已存在的安装
#
# 为什么用 curl 而不是让用户去浏览器下载 .pkg：
#   curl 下载的文件不带 com.apple.quarantine 扩展属性，
#   Gatekeeper 不会拦截。浏览器下载的 .pkg 会带标记，双击直接拒绝。
#   这一点实测过：xattr 查看 curl 下载的 tar.gz 输出为空，
#   而浏览器下载的 .dmg 带 com.apple.quarantine。

set -eu

LUABIN_VERSION="${LUABIN_VERSION:-${1:-5.5.1}}"
PREFIX="${PREFIX:-$HOME/.local}"
LUABIN_REPO="${LUABIN_REPO:-mouyase/luabin}"
LUABIN_FORCE="${LUABIN_FORCE:-0}"
LUABIN_MIRROR="${LUABIN_MIRROR:-}"

# GitHub 在部分地区直连不通（raw.githubusercontent.com 与 github.com
# 都可能直接断流）。按顺序试：用户指定镜像 → 官方 → 第三方代理。
# 镜像前缀直接拼在原 URL 前面，是这类代理的标准用法。
# 无论走哪条通道，最终都用官方 .sha256 校验，内容被改会立刻暴露。
#
# 尝试顺序：用户指定镜像（若有）→ 直连 → 内置代理
# 直连用 @DIRECT 占位：空串放进列表会被字段分割吃掉，
# "直连"这一项就静默消失了（实测踩过）。
if [ -n "$LUABIN_MIRROR" ]; then
  # 用户指定的镜像排最前，其余照旧；若它恰好等于内置代理则去重
  _USER_MIRROR="${LUABIN_MIRROR%/}"
  MIRROR_ORDER="$_USER_MIRROR @DIRECT"
  for _p in https://ghfast.top https://gh-proxy.com; do
    [ "$_p" = "$_USER_MIRROR" ] || MIRROR_ORDER="$MIRROR_ORDER $_p"
  done
  unset _USER_MIRROR _p
else
  MIRROR_ORDER="@DIRECT https://ghfast.top https://gh-proxy.com"
fi

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[33m警告: %s\033[0m\n' "$*" >&2 ; }
die() { printf '\n\033[31m错误: %s\033[0m\n' "$*" >&2 ; exit 1 ; }

need() { command -v "$1" >/dev/null 2>&1 || die "需要 $1，请先安装" ; }

# ------------------------------------------------ 平台判定
say "检测平台"

OS=$(uname -s)
RAW_ARCH=$(uname -m)

case "$OS" in
  Darwin) PLAT=macos ;;
  Linux)  PLAT=linux ;;
  *) die "不支持的系统: $OS" ;;
esac

case "$RAW_ARCH" in
  arm64|aarch64) ARCH=arm64 ;;
  x86_64|amd64)  ARCH=x64 ;;
  *) die "不支持的架构: $RAW_ARCH" ;;
esac

info "系统: $OS ($RAW_ARCH) → $PLAT-$ARCH"
info "版本: $LUABIN_VERSION"

# ------------------------------------------------ Linux：没有预编译包，转去编译
if [ "$PLAT" = "linux" ]; then
  say "Linux 需要从源码编译"
  info "没有预编译包的原因：glibc 符号版本化，预编译产物在老发行版上会报"
  info "  version 'GLIBC_x.yz' not found"
  info "本地编译约 30 秒，比处理兼容性省事。"
  printf '\n'

  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT
  need curl
  curl -fsSL -o "$TMP/build-linux.sh" \
    "https://raw.githubusercontent.com/${LUABIN_REPO}/main/scripts/build-linux.sh" \
    || die "下载 build-linux.sh 失败"
  LUA_VERSION="$LUABIN_VERSION" PREFIX="$PREFIX" sh "$TMP/build-linux.sh"
  exit 0
fi

# ------------------------------------------------ macOS：下载预编译包
need curl
need tar

TAG="lua-${LUABIN_VERSION}-macos-${ARCH}"
FILENAME="${TAG}.tar.gz"
BASE="https://github.com/${LUABIN_REPO}/releases/download/v${LUABIN_VERSION}"

if [ "$LUABIN_FORCE" != "1" ] && [ -x "$PREFIX/bin/lua" ]; then
  EXISTING=$("$PREFIX/bin/lua" -v 2>/dev/null || echo "unknown")
  warn "已存在安装: $EXISTING"
  warn "路径: $PREFIX/bin/lua"
  warn "继续会覆盖。设置 LUABIN_FORCE=1 跳过此检查"
  printf '\n'
  printf '继续安装? [y/N] '
  read -r ans </dev/tty || ans=n
  case "$ans" in
    y|Y|yes|YES) ;;
    *) info "已取消" ; exit 0 ;;
  esac
fi

say "下载 ${FILENAME}"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# 进度条只在交互终端下开：管道/CI 里 --progress-bar 会刷出大量控制字符
if [ -t 1 ]; then
  CURL_PROGRESS="--progress-bar"
else
  CURL_PROGRESS="-sS"
fi

# 逐个通道尝试。
# 空串代表直连，用 @DIRECT 占位再还原——直接放空串在列表里会被
# 字段分割吃掉，"直连"这一项就消失了（实测踩过）。
USED_PREFIX=""
DOWNLOADED=0
for token in $MIRROR_ORDER; do
  if [ "$token" = "@DIRECT" ]; then
    pfx=""
    url="$BASE/$FILENAME"
    # 变量值保持 ASCII：macOS 自带 bash 3.2 在 set -u 下处理
    # 多字节字符串会误报 unbound variable（实测 label 取中文值即崩）。
    label="direct"
  else
    pfx="$token"
    url="$pfx/$BASE/$FILENAME"
    label="$pfx"
  fi
  info "尝试 [$label]"
  if curl -fL $CURL_PROGRESS --connect-timeout 15 --max-time 300 \
       -o "$TMP/$FILENAME" "$url" 2>/dev/null; then
    if [ -s "$TMP/$FILENAME" ] && [ "$(wc -c < "$TMP/$FILENAME")" -gt 10240 ]; then
      USED_PREFIX="$pfx"
      DOWNLOADED=1
      info "下载成功（${label}）"
      break
    fi
    info "失败: 文件过小，可能是错误页"
  else
    info "失败"
  fi
  rm -f "$TMP/$FILENAME"
done

[ "$DOWNLOADED" = "1" ] || die "下载失败，所有通道都不可用。

  排查办法：
    1. 手动下载后解压到 $PREFIX
       $BASE/$FILENAME
    2. 或用 gh 命令行
       gh release download v${LUABIN_VERSION} -R ${LUABIN_REPO}
    3. 或指定可用镜像
       LUABIN_MIRROR=https://your-proxy sh install.sh"

# 校验 sha256（Release 里同时提供 .sha256 文件）
# 从下载成功的通道取，失败再退回直连
if [ -n "$USED_PREFIX" ]; then
  SHA_URL="$USED_PREFIX/$BASE/$FILENAME.sha256"
else
  SHA_URL="$BASE/$FILENAME.sha256"
fi
if ! curl -fsSL --connect-timeout 15 --max-time 60 -o "$TMP/$FILENAME.sha256" "$SHA_URL" 2>/dev/null; then
  curl -fsSL --connect-timeout 15 --max-time 60 -o "$TMP/$FILENAME.sha256" "$BASE/$FILENAME.sha256" 2>/dev/null || true
fi
if [ -s "$TMP/$FILENAME.sha256" ]; then
  EXPECTED=$(cut -d' ' -f1 < "$TMP/$FILENAME.sha256")
  ACTUAL=$(shasum -a 256 "$TMP/$FILENAME" | cut -d' ' -f1)
  if [ "$EXPECTED" != "$ACTUAL" ]; then
    die "sha256 校验失败
  期望: $EXPECTED
  实际: $ACTUAL"
  fi
  info "sha256 校验通过"
else
  warn "未找到 .sha256 文件，跳过校验"
fi

# ------------------------------------------------ 安装
say "安装到 $PREFIX"

tar -C "$TMP" -xzf "$TMP/$FILENAME"

mkdir -p "$PREFIX"
# 用 cp -R 而不是 mv：保留目录结构，且能覆盖旧文件
cp -R "$TMP/bin"     "$PREFIX/"
cp -R "$TMP/include" "$PREFIX/"
cp -R "$TMP/lib"     "$PREFIX/"
mkdir -p "$PREFIX/share"
cp -R "$TMP/share/." "$PREFIX/share/"
[ -f "$TMP/BUILD-INFO" ] && cp "$TMP/BUILD-INFO" "$PREFIX/BUILD-INFO"
[ -f "$TMP/LICENSE" ]   && cp "$TMP/LICENSE"   "$PREFIX/LICENSE"

chmod 0755 "$PREFIX/bin/lua" "$PREFIX/bin/luac"

# 去掉可能存在的 quarantine 标记（保险，curl 下载本不该有）
xattr -d com.apple.quarantine "$PREFIX/bin/lua" 2>/dev/null || true
xattr -d com.apple.quarantine "$PREFIX/bin/luac" 2>/dev/null || true

info "已安装:"
info "  $PREFIX/bin/lua"
info "  $PREFIX/bin/luac"
info "  $PREFIX/include/lua*.h"
info "  $PREFIX/lib/liblua.a"

# ------------------------------------------------ 验证
say "验证"
"$PREFIX/bin/lua" -v
"$PREFIX/bin/lua" -e 'print("hello from lua", _VERSION)'

# ------------------------------------------------ PATH
say "完成"

case ":$PATH:" in
  *":$PREFIX/bin:"*)
    info "PATH 已包含 $PREFIX/bin，可直接使用 lua 命令"
    ;;
  *)
    printf '\n'
    info "$PREFIX/bin 不在 PATH 里。加进 shell 配置："
    printf '\n'
    case "${SHELL:-}" in
      */zsh)  printf '    echo '"'"'export PATH="%s/bin:$PATH"'"'"' >> ~/.zshrc\n' "$PREFIX" ;;
      */bash) printf '    echo '"'"'export PATH="%s/bin:$PATH"'"'"' >> ~/.bashrc\n' "$PREFIX" ;;
      *)      printf '    export PATH="%s/bin:$PATH"\n' "$PREFIX" ;;
    esac
    printf '\n'
    info "然后重开终端，或手动 source 对应配置文件"
    ;;
esac
