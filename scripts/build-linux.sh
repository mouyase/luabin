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

# 5.0.x 的包里 test/lua -> ../bin/lua 这类符号链接，解包时目标不存在，
# tar 会报错退出。容忍它。
tar zxf "${PKG}.tar.gz" || echo "tar 有警告（符号链接），继续" >&2
cd "$PKG"

# ------------------------------------------------ 编译
say "编译（$JOBS 并行）"

# 构建系统在 5.0 到 5.5 之间变过，按版本分档。
case "$LUA_VERSION" in
  5.0|5.0.*) MAJOR=50 ;;
  5.1|5.1.*) MAJOR=51 ;;
  5.2|5.2.*) MAJOR=52 ;;
  5.3|5.3.*) MAJOR=53 ;;
  5.4|5.4.*) MAJOR=54 ;;
  5.5|5.5.*) MAJOR=55 ;;
  *) die "不支持的版本: $LUA_VERSION" ;;
esac
info "构建系统: $MAJOR 档"

if [ "$MAJOR" = "50" ]; then
  # 5.0 靠 config 文件，没有 make 平台目标。产物落在 bin/ lib/ include/。
  sed -i.bak \
    -e "s|^LOADLIB=.*|LOADLIB= -DUSE_DLOPEN=1|" \
    -e "s|^DLLIB=.*|DLLIB= -ldl|" \
    -e "s|^MYLDFLAGS=.*|MYLDFLAGS= -Wl,-E|" \
    config
  rm -f config.bak
  # src/Makefile 列了 ltests.o，但发布包里编不出来，摘掉
  sed -i.bak '/ltests\.o/d' src/Makefile
  rm -f src/Makefile.bak
  make
else
  # 5.1+ 用平台目标。
  #
  # 5.5 的 linux 目标不硬链 readline（运行时 dlopen），5.1-5.4 会硬链
  # -lreadline，精简环境里编不过。所以：
  #   有 readline 且是 5.5  → linux-readline（交互带行编辑）
  #   有 readline 且是旧版  → linux（目标本身已经带上）
  #   无 readline 且是 5.5  → linux（不链，运行时尝试）
  #   无 readline 且是旧版  → generic + 手动定宏
  if [ "$HAVE_RL" = "1" ]; then
    # 有 readline，用官方 linux 目标（5.5 用 linux-readline 才启用行编辑）
    if [ "$MAJOR" = "55" ]; then
      make linux-readline -j"$JOBS"
    else
      make linux -j"$JOBS"
    fi
  else
    # 没有 readline，必须避开 LUA_USE_LINUX 在旧版本上的副作用。
    #
    # luaconf.h 的实际差异：
    #   5.1 / 5.2 / 5.3   LUA_USE_LINUX 会连带定义 LUA_USE_READLINE
    #   5.4 / 5.5         只有 POSIX + DLOPEN，不含 readline
    #
    # 所以 5.1-5.3 得拆开传 POSIX 和 DLOPEN。
    case "$MAJOR" in
      51|52|53)
        make generic -j"$JOBS" \
          "SYSCFLAGS=-DLUA_USE_POSIX -DLUA_USE_DLOPEN" \
          "SYSLIBS=-Wl,-E -ldl"
        ;;
      *)
        make generic -j"$JOBS" "SYSCFLAGS=-DLUA_USE_LINUX" "SYSLIBS=-Wl,-E -ldl"
        ;;
    esac
  fi
fi

# ------------------------------------------------ 定位产物
# 5.0 的产物在 bin/，5.1+ 在 src/
if [ "$MAJOR" = "50" ]; then
  LUA_BIN="$PWD/bin/lua"
  LUAC_BIN="$PWD/bin/luac"
  INC_DIR="$PWD/include"
  LIB_DIR="$PWD/lib"
else
  LUA_BIN="$PWD/src/lua"
  LUAC_BIN="$PWD/src/luac"
  INC_DIR="$PWD/src"
  LIB_DIR="$PWD/src"
fi

[ -x "$LUA_BIN" ] || die "没找到 $LUA_BIN"
[ -x "$LUAC_BIN" ] || die "没找到 $LUAC_BIN"

# ------------------------------------------------ 自检
say "自检"
"$LUA_BIN" -v
"$LUA_BIN" -e '
  -- 5.0.x 的 _VERSION 是完整补丁号（"Lua 5.0.3"），
  -- 5.1+ 只到次版本号（"Lua 5.1"）。用前缀匹配两边都成立。
  assert(_VERSION:find("^Lua '"$LUA_LANG"'"), "版本不符: " .. tostring(_VERSION))
  -- 5.3+ 才有整数子类型和 utf8 库，按版本分支
  if _VERSION >= "Lua 5.3" then
    assert(math.maxinteger and math.maxinteger > 2^62, "缺少 64 位整数")
    assert(utf8 and utf8.len("汉字") == 2, "缺少 utf8 库")
  end
  local co = coroutine.wrap(function() for i = 1, 3 do coroutine.yield(i * i) end end)
  assert(co() == 1 and co() == 4 and co() == 9, "协程异常")
  print("自检通过:", _VERSION)
'

# ------------------------------------------------ 安装
say "安装到 $PREFIX"

mkdir -p "$PREFIX/bin" "$PREFIX/include" "$PREFIX/lib" "$PREFIX/share/lua/${LUA_LANG}"

install -m 0755 "$LUA_BIN"  "$PREFIX/bin/lua"
install -m 0755 "$LUAC_BIN" "$PREFIX/bin/luac"

# 头文件：5.1 的 lua.hpp 在 etc/，其他版本在 src/
for h in lua.h luaconf.h lualib.h lauxlib.h; do
  [ -f "$INC_DIR/$h" ] && install -m 0644 "$INC_DIR/$h" "$PREFIX/include/"
done
if [ -f "$INC_DIR/lua.hpp" ]; then
  install -m 0644 "$INC_DIR/lua.hpp" "$PREFIX/include/"
elif [ -f "$PKG/etc/lua.hpp" ]; then
  install -m 0644 "$PKG/etc/lua.hpp" "$PREFIX/include/"
fi

# 静态库：5.0 有两个
[ -f "$LIB_DIR/liblua.a" ]    && install -m 0644 "$LIB_DIR/liblua.a"    "$PREFIX/lib/"
[ -f "$LIB_DIR/liblualib.a" ] && install -m 0644 "$LIB_DIR/liblualib.a" "$PREFIX/lib/"

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
