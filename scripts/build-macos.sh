#!/usr/bin/env sh
# luabin — 从 Lua 官方源码构建 macOS 产物
#
# 用法: build-macos.sh <version> <outdir> <workdir>
#   version  5.5.1
#   outdir   产物目录（.tar.gz / .pkg / .sha256）
#   workdir  已含 lua-<version>.tar.gz 的工作目录
#
# 环境变量:
#   EXPECTED_SHA256       源码 tar.gz 的 sha256，设置后强制校验
#   MACOSX_DEPLOYMENT_TARGET  最低系统版本，默认 11.0
#   ARCH                  arm64 | x86_64，交叉编译时用；默认取 uname -m
#   MAKE_UNIVERSAL        设为 1 时同时产出 universal2 包

set -eu

VERSION="${1:?usage: build-macos.sh <version> <outdir> <workdir>}"
OUTDIR="${2:?}"
WORKDIR="${3:?}"

PKG="lua-${VERSION}"
ARCH="${ARCH:-$(uname -m)}"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-11.0}"

# 命名用 x64，clang 只认 x86_64。两套体系必须显式映射：
#   -arch x64      → clang 把它当成无参数，然后报一堆 usage
#   file 输出里也永远是 x86_64 / arm64
case "$ARCH" in
  x64|x86_64) ARCH=x64 ; MACHO_ARCH=x86_64 ;;
  arm64|aarch64) ARCH=arm64 ; MACHO_ARCH=arm64 ;;
  *) echo "unsupported arch: $ARCH" >&2 ; exit 1 ;;
esac

# 语言版本号（5.5.1 -> 5.5，5.5 -> 5.5）。
# 不能靠执行产物去读 _VERSION：交叉编译时本机可能跑不了那个二进制。
case "$VERSION" in
  *.*.*) LUA_LANG="${VERSION%.*}" ;;
  *.*)   LUA_LANG="$VERSION" ;;
  *)     echo "无法解析版本号: $VERSION" >&2 ; exit 1 ;;
esac

# 脚本所在目录必须在开头就解析成绝对路径：
# 后面会 cd 到 workdir，届时 $0 的相对路径就失效了。
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

say() { printf '\n=== %s ===\n' "$*"; }

mkdir -p "$OUTDIR"
OUTDIR="$(cd "$OUTDIR" && pwd)"
WORKDIR="$(cd "$WORKDIR" && pwd)"
cd "$WORKDIR"

# ------------------------------------------------ 1. 源码校验
say "verify ${PKG}.tar.gz"
if [ ! -f "${PKG}.tar.gz" ]; then
  FOUND=$(find "$WORKDIR" -name "${PKG}.tar.gz" -type f 2>/dev/null | head -1 || true)
  if [ -n "${FOUND:-}" ]; then
    cp "$FOUND" "$WORKDIR/${PKG}.tar.gz"
  else
    echo "missing ${PKG}.tar.gz under $WORKDIR" >&2
    exit 1
  fi
fi

ACTUAL=$(shasum -a 256 "${PKG}.tar.gz" | cut -d' ' -f1)
if [ -n "${EXPECTED_SHA256:-}" ] && [ "$ACTUAL" != "$EXPECTED_SHA256" ]; then
  echo "sha256 mismatch: expected $EXPECTED_SHA256 got $ACTUAL" >&2
  exit 1
fi
echo "sha256: $ACTUAL"

# ------------------------------------------------ 2. 编译
say "build (arch=$ARCH, target=$MACOSX_DEPLOYMENT_TARGET)"

rm -rf "$PKG"
tar zxf "${PKG}.tar.gz"
cd "$PKG"

# 用 macosx 目标：它定义 LUA_USE_MACOSX →
#   LUA_USE_POSIX   （sigaction、popen 等）
#   LUA_USE_DLOPEN  （require 加载 .so，macOS 不需要 -ldl）
#   LUA_USE_READLINE（链接 -lreadline，实际解析到系统 libedit）
# 不要把 readline 去掉：lua.c 里 LUA_USE_DLOPEN + LUA_READLINELIB 的组合
# 会在每次启动时尝试 dlopen("libreadline.so")，macOS 上必然失败并打警告。
# 现在这样就只依赖 /usr/lib/libedit.3.dylib，任何 macOS 都有。
#
# 交叉编译必须用 make 命令行参数传 CFLAGS/LDFLAGS，不能用环境变量：
# src/Makefile 里有 `CFLAGS= -O2 -Wall -Wextra $(SYSCFLAGS) $(MYCFLAGS)`，
# 这是 make 赋值，会直接覆盖环境变量里的 CFLAGS。
# 实测环境变量方式编出来的仍是宿主架构，命令行方式才生效。
# 交叉编译参数必须作为单个 argv 传给 make。
# 用字符串变量再 $VAR 展开会被空格拆成多个参数，
# 导致 -Wall 被 make 当成自己的选项（invalid option -- a）。
# 位置参数数组是唯一可靠写法。
set --
if [ "$MACHO_ARCH" != "$(uname -m)" ]; then
  echo "cross-compiling: forced -arch ${MACHO_ARCH}"
  set -- "CFLAGS=-O2 -Wall -Wextra -DLUA_USE_MACOSX -arch ${MACHO_ARCH}" \
         "LDFLAGS=-arch ${MACHO_ARCH}"
fi

make macosx "$@"

# ------------------------------------------------ 3. 自检
say "self-check"

# 交叉编译的产物不一定能在当前机器上执行（arm64 机器没有 Rosetta 时
# 跑不了 x86_64 二进制）。这种情况只校验格式，跳过运行时自检。
CAN_RUN=1
if [ "$MACHO_ARCH" != "$(uname -m)" ]; then
  if ! ./src/lua -v >/dev/null 2>&1; then
    CAN_RUN=0
    echo "本机无法执行 $MACHO_ARCH 产物（缺 Rosetta），跳过运行时自检"
    echo "CI 上使用原生 $ARCH runner，自检会正常执行"
  fi
fi

if [ "$CAN_RUN" = "1" ]; then
./src/lua -v
./src/lua -e '
  assert(_VERSION == "Lua 5.5", "unexpected version: " .. tostring(_VERSION))
  assert(math.maxinteger > 2^62, "no 64-bit integers")
  assert(utf8.len("汉字") == 2, "utf8 lib missing")
  assert(load("return 1+1")() == 2, "load broken")
  local co = coroutine.wrap(function() for i = 1, 3 do coroutine.yield(i * i) end end)
  assert(co() == 1 and co() == 4 and co() == 9, "coroutine broken")
  print("self-check ok:", _VERSION, math.maxinteger)
'
fi

# 架构断言：防止 arch 参数与实际产物错位
ACTUAL_ARCH=$(file -b src/lua)
say "artifact arch"
echo "$ACTUAL_ARCH"
case "$ACTUAL_ARCH" in
  *"$MACHO_ARCH"*) ;;
  *) echo "arch mismatch: expected $MACHO_ARCH, got $ACTUAL_ARCH" >&2 ; exit 1 ;;
esac

# 部署目标断言：确保没有绑定构建机的 macOS 版本
MINOS=$(otool -l src/lua | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')
echo "minos: $MINOS"
if [ -n "$MINOS" ]; then
  MIN_MAJOR=${MINOS%%.*}
  TARGET_MAJOR=${MACOSX_DEPLOYMENT_TARGET%%.*}
  if [ "$MIN_MAJOR" -gt "$TARGET_MAJOR" ]; then
    echo "minos $MINOS exceeds target $MACOSX_DEPLOYMENT_TARGET" >&2
    exit 1
  fi
fi

# ------------------------------------------------ 4. 官方测试套件
say "test suite"
if [ "$CAN_RUN" = "0" ]; then
  echo "无法在本机执行 $MACHO_ARCH 产物，跳过测试套件"
  echo "CI 上使用原生 $ARCH runner 时会完整执行"
else
TESTS_DIR="$WORKDIR/tests-${PKG}"
rm -rf "$TESTS_DIR"
mkdir -p "$TESTS_DIR"
curl -fsSL -o "$TESTS_DIR/tests.tar.gz" "https://www.lua.org/tests/${PKG}-tests.tar.gz"
tar -C "$TESTS_DIR" -xzf "$TESTS_DIR/tests.tar.gz"

LUA_BIN="$(pwd)/src/lua"
(
  cd "$TESTS_DIR/${PKG}-tests"
  # all.lua 默认按 Linux 设计。/dev/full 是 Linux 专有设备节点，macOS 不存在，
  # files.lua 里 "testing flush" 段会抛 cannot open file '/dev/full'。
  # 该段没有 _port 守卫，只能整块删掉，其余全部照跑。
  perl -0pi -e 's/do print\("testing flush"\).*?\nend\n/\n/s' files.lua
  echo "(已从 files.lua 移除依赖 /dev/full 的 flush 段)"
  "$LUA_BIN" -e '_port=true; _nomsg=true; _soft=true' all.lua
)
fi

# ------------------------------------------------ 5. 打包 tar.gz
say "package tar.gz"
cd "$WORKDIR"

VTAG="$LUA_LANG"
TAG="lua-${VERSION}-macos-${ARCH}"
STAGE="$WORKDIR/stage-macos-${ARCH}"
rm -rf "$STAGE"
mkdir -p "$STAGE/bin" "$STAGE/include" "$STAGE/lib" "$STAGE/share/lua/${VTAG}"

cp "$PKG/src/lua"  "$STAGE/bin/lua"
cp "$PKG/src/luac" "$STAGE/bin/luac"
chmod 0755 "$STAGE/bin/lua" "$STAGE/bin/luac"
cp "$PKG/src/lua.h" "$PKG/src/luaconf.h" "$PKG/src/lualib.h" \
   "$PKG/src/lauxlib.h" "$PKG/src/lua.hpp" "$STAGE/include/"
cp "$PKG/src/liblua.a" "$STAGE/lib/"
cp "$PKG/doc/readme.html" "$STAGE/README-lua.html"
# MIT 许可要求随分发附带版权声明
cp "${SCRIPT_DIR}/../packaging/LICENSE.lua" "$STAGE/LICENSE"

cat > "$STAGE/BUILD-INFO" <<EOF
lua ${VERSION}
plat macos
arch ${ARCH}
minos ${MACOSX_DEPLOYMENT_TARGET}
built-at $(date -u +%Y-%m-%dT%H:%M:%SZ)
cc $(cc --version 2>/dev/null | head -1 || echo unknown)
os $(uname -s) $(uname -r)
EOF

tar -C "$STAGE" -czf "$OUTDIR/${TAG}.tar.gz" .
shasum -a 256 "$OUTDIR/${TAG}.tar.gz" | sed "s|$OUTDIR/||" > "$OUTDIR/${TAG}.tar.gz.sha256"

say "done: ${TAG}.tar.gz"
ls -l "$OUTDIR/${TAG}.tar.gz"

# ------------------------------------------------ 6. 打包 .pkg
# 只有本机原生架构才打包 pkg（交叉编译出的产物不该做安装包）
if [ "$MACHO_ARCH" = "$(uname -m)" ] && [ "${MAKE_UNIVERSAL:-0}" != "1" ]; then
  say "package pkg"
  sh "${SCRIPT_DIR}/make-pkg.sh" "$VERSION" "$ARCH" "$OUTDIR" "$STAGE"
else
  say "skip pkg (cross-compiled or universal mode)"
fi
