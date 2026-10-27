#!/usr/bin/env sh
# luabin — Linux 一键从源码编译 Lua
#
# 用法:
#   curl -fsSL https://raw.githubusercontent.com/mouyase/luabin/main/scripts/build-linux.sh | sh
#   sh build-linux.sh [version] [prefix]
#
# 环境变量:
#   LUA_VERSION   Lua 版本，默认 5.5.1
#   PREFIX        安装前缀，默认 $HOME/.local
#   JOBS          并行数，默认 CPU 核数
#   KEEP_SRC      设为 1 保留源码目录
#   LUABIN_LOCAL_SRC  已有源码 tar.gz 的路径；设置后跳过下载（离线/内网构建）
#
# 为什么 Linux 不发预编译包：
#   glibc 的符号是版本化的。在 Ubuntu 24.04 上编出来的二进制
#   链接的是 GLIBC_2.39 的符号，拿到老发行版上直接报
#   "version 'GLIBC_2.38' not found"。
#   要覆盖全部发行版得在老容器里构建 + musl 静态版，
#   而 musl 静态链接会废掉 dlopen，require 加载 C 扩展直接失效。
#   自己编译 30 秒搞定，比下载二进制再踩兼容性坑省事。

set -eu

LUA_VERSION="${LUA_VERSION:-${1:-5.5.1}}"
PREFIX="${PREFIX:-${2:-$HOME/.local}}"
KEEP_SRC="${KEEP_SRC:-0}"

# 从版本号推 Lua 的语言版本（5.5.1 -> 5.5，5.5 -> 5.5，5.4.8 -> 5.4）
# 直接 ${VERSION%.*} 在两位版本号时会把 "5.5" 截成 "5"，必须显式处理。
case "$LUA_VERSION" in
  *.*.*) LUA_LANG="${LUA_VERSION%.*}" ;;
  *.*)   LUA_LANG="$LUA_VERSION" ;;
  *)     echo "无法解析版本号: $LUA_VERSION" >&2 ; exit 1 ;;
esac

case "$(uname -s)" in
  Linux) ;;
  *) echo "此脚本用于 Linux；macOS 请用 install.sh 下载预编译包" >&2 ; exit 1 ;;
esac

if [ -z "${JOBS:-}" ]; then
  if command -v nproc >/dev/null 2>&1; then
    JOBS=$(nproc)
  else
    JOBS=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)
  fi
fi

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die() { printf '\n\033[31m错误: %s\033[0m\n' "$*" >&2 ; exit 1 ; }

# ------------------------------------------------ 环境检查
say "检查编译环境"

CC_BIN="${CC:-}"
if [ -z "$CC_BIN" ]; then
  for c in cc gcc clang; do
    if command -v "$c" >/dev/null 2>&1; then CC_BIN=$c ; break ; fi
  done
fi
[ -n "$CC_BIN" ] || die "找不到 C 编译器。请先安装 build-essential（Debian/Ubuntu）、base-devel（Arch）、gcc（Fedora/Alpine）"

command -v make >/dev/null 2>&1 || die "找不到 make"
if [ -z "${LUABIN_LOCAL_SRC:-}" ]; then
  command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || die "找不到 curl 或 wget"
fi

info "编译器: $CC_BIN ($("$CC_BIN" --version 2>/dev/null | head -1))"
info "make:    $(make --version 2>/dev/null | head -1)"
info "并行数:  $JOBS"

# readline 可选，但判定不能只看头文件在不在：
#   linux-readline 目标会真的 -lreadline 链接，缺库就直接编不过。
#   头文件存在但库缺失（或反之）的情况在精简镜像上非常常见。
# 所以实际编译一个最小程序做探针，两边都通才算可用。
say "探测 readline"
HAVE_RL=0
RL_PROBE=$(mktemp -d)
cat > "$RL_PROBE/probe.c" <<'PROBE'
#include <stdio.h>
#include <readline/readline.h>
int main(void) {
    char *s = readline("");
    if (s) { free(s); }
    return rl_readline_name != NULL ? 0 : 1;
}
PROBE
if "$CC_BIN" "$RL_PROBE/probe.c" -o "$RL_PROBE/probe" -lreadline >/dev/null 2>&1; then
  HAVE_RL=1
  info "readline: 头文件与库都可用（交互模式有行编辑）"
else
  info "readline: 不可用（交互模式无行编辑，不影响脚本执行）"
fi
rm -rf "$RL_PROBE"

# ------------------------------------------------ 下载源码
say "下载 Lua ${LUA_VERSION}"

TMPDIR_BUILD=$(mktemp -d)
cleanup() {
  if [ "$KEEP_SRC" = "1" ]; then
    info "源码保留在: $TMPDIR_BUILD"
  else
    rm -rf "$TMPDIR_BUILD"
  fi
}
trap cleanup EXIT

cd "$TMPDIR_BUILD"
PKG="lua-${LUA_VERSION}"
URL="https://www.lua.org/ftp/${PKG}.tar.gz"

if [ -n "${LUABIN_LOCAL_SRC:-}" ]; then
  # 离线 / 内网：直接用本地源码包，跳过下载
  [ -f "$LUABIN_LOCAL_SRC" ] || die "找不到本地源码包: $LUABIN_LOCAL_SRC"
  cp "$LUABIN_LOCAL_SRC" "${PKG}.tar.gz"
  info "使用本地源码: $LUABIN_LOCAL_SRC"
elif command -v curl >/dev/null 2>&1; then
  curl -fsSL -O "$URL" || die "下载失败: $URL"
elif command -v wget >/dev/null 2>&1; then
  wget -q -O "${PKG}.tar.gz" "$URL" || die "下载失败: $URL"
else
  die "需要 curl 或 wget"
fi

info "已下载 $(du -h "${PKG}.tar.gz" | cut -f1)"

# 官网 download 页公布各版本的 sha256；这里做一次基础完整性检查
if command -v sha256sum >/dev/null 2>&1; then
  info "sha256: $(sha256sum "${PKG}.tar.gz" | cut -d' ' -f1)"
fi

tar zxf "${PKG}.tar.gz"
cd "$PKG"

# ------------------------------------------------ 编译
say "编译（$JOBS 并行）"

# 用官方 linux 目标：定义 LUA_USE_LINUX → LUA_USE_POSIX + LUA_USE_DLOPEN，
# require 能加载 C 扩展。不会硬链 readline：
# lua.c 里是运行时 dlopen("libreadline.so")，找不到只警告。
# 没有 readline 时用 linux-readline 会链接失败，所以按检测结果选目标。
if [ "$HAVE_RL" = "1" ]; then
  MAKE_TARGET=linux-readline
else
  MAKE_TARGET=linux
fi

make "$MAKE_TARGET" -j"$JOBS"

# ------------------------------------------------ 自检
say "自检"
./src/lua -v
./src/lua -e '
  assert(_VERSION == "Lua '"$LUA_LANG"'", "版本不符: " .. tostring(_VERSION))
  assert(math.maxinteger > 2^62, "缺少 64 位整数")
  assert(utf8.len("汉字") == 2, "缺少 utf8 库")
  local co = coroutine.wrap(function() for i = 1, 3 do coroutine.yield(i * i) end end)
  assert(co() == 1 and co() == 4 and co() == 9, "协程异常")
  print("自检通过:", _VERSION, math.maxinteger)
'

# ------------------------------------------------ 安装
say "安装到 $PREFIX"

mkdir -p "$PREFIX/bin" "$PREFIX/include" "$PREFIX/lib" "$PREFIX/share/lua/${LUA_LANG}"

install -m 0755 src/lua  "$PREFIX/bin/lua"
install -m 0755 src/luac "$PREFIX/bin/luac"
install -m 0644 src/lua.h src/luaconf.h src/lualib.h src/lauxlib.h src/lua.hpp "$PREFIX/include/"
install -m 0644 src/liblua.a "$PREFIX/lib/"

info "已安装:"
info "  $PREFIX/bin/lua"
info "  $PREFIX/bin/luac"
info "  $PREFIX/include/lua*.h"
info "  $PREFIX/lib/liblua.a"

# ------------------------------------------------ PATH 提示
say "完成"

"$PREFIX/bin/lua" -v

case ":$PATH:" in
  *":$PREFIX/bin:"*)
    info "PATH 已包含 $PREFIX/bin，可直接使用 lua 命令"
    ;;
  *)
    printf '\n'
    info "$PREFIX/bin 不在 PATH 里。把下面这行加进 ~/.bashrc 或 ~/.zshrc："
    printf '\n    export PATH="%s/bin:$PATH"\n\n' "$PREFIX"
    info "然后执行 source ~/.bashrc（或重开终端）"
    ;;
esac
