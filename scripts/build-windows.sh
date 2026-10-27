#!/usr/bin/env sh
# luabin — Windows 构建（在 MSYS2 里跑）
#
# 用法: build-windows.sh <version> <outdir> <workdir>
#
# 环境变量:
#   EXPECTED_SHA256   源码 tar.gz 的 sha256
#   ARCH              x64 | arm64，默认按 uname -m 推断
#
# 产物结构（ZIP 内）：
#   bin/lua.exe  bin/luac.exe  bin/lua55.dll
#   include/*.h
#   lib/liblua.a  lib/lua55.dll.a

set -eu

VERSION="${1:?usage: build-windows.sh <version> <outdir> <workdir>}"
OUTDIR="${2:?}"
WORKDIR="${3:?}"

PKG="lua-${VERSION}"
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

ACTUAL=$(sha256sum "${PKG}.tar.gz" | cut -d' ' -f1)
if [ -n "${EXPECTED_SHA256:-}" ] && [ "$ACTUAL" != "$EXPECTED_SHA256" ]; then
  echo "sha256 mismatch: expected $EXPECTED_SHA256 got $ACTUAL" >&2
  exit 1
fi
echo "sha256: $ACTUAL"

# ------------------------------------------------ 2. 判定交叉编译前缀
case "${ARCH:-$(uname -m)}" in
  x86_64|amd64|x64) ARCH=x64   ; PREFIX=x86_64-w64-mingw32  ;;
  aarch64|arm64)    ARCH=arm64 ; PREFIX=aarch64-w64-mingw32 ;;
  *) echo "unsupported arch: ${ARCH:-$(uname -m)}" >&2 ; exit 1 ;;
esac

# 语言版本号（5.5.1 -> 5.5）。不执行产物取版本：
# 交叉编译时本机跑不了目标架构的 exe（如 arm64 runner 上编 x64）。
case "$VERSION" in
  *.*.*) LUA_LANG="${VERSION%.*}" ;;
  *.*)   LUA_LANG="$VERSION" ;;
  *)     echo "无法解析版本号: $VERSION" >&2 ; exit 1 ;;
esac
say "target: windows-${ARCH} (${PREFIX}-gcc)"

# ------------------------------------------------ 3. 编译
rm -rf "$PKG"
tar zxf "${PKG}.tar.gz"
cd "$PKG"

# 只覆盖 CC。
# Lua 的 mingw 目标在 recipe 内部自己指定：
#   AR=$(CC) -shared -o        ← 借编译器把 .o 直接链成 lua55.dll
#   RANLIB=strip --strip-unneeded
# 这两个是 make 命令行赋值，会盖掉外层传入的同名变量。
# 外层若也传 AR/RANLIB，会和 recipe 内赋值打架，
# 在不同 make 版本上产出错架构或空 DLL。只传 CC 最稳。
say "build"
make mingw CC="${PREFIX}-gcc"

# ------------------------------------------------ 4. 自检
say "self-check"
./src/lua.exe -v
./src/lua.exe -e '
  assert(_VERSION == "Lua 5.5", "unexpected version: " .. tostring(_VERSION))
  assert(math.maxinteger > 2^62, "no 64-bit integers")
  assert(utf8.len("汉字") == 2, "utf8 lib missing")
  assert(load("return 1+1")() == 2, "load broken")
  local co = coroutine.wrap(function() for i = 1, 3 do coroutine.yield(i * i) end end)
  assert(co() == 1 and co() == 4 and co() == 9, "coroutine broken")
  -- Windows 下 io 与 os 库是否真能用
  local f = assert(io.open("selftest.tmp", "w")); f:write("x"); f:close()
  assert(io.open("selftest.tmp", "r"), "cannot reopen"); os.remove("selftest.tmp")
  assert(type(os.time()) == "number", "os.time broken")
  print("self-check ok:", _VERSION, math.maxinteger)
'

# DLL 必须存在，否则 require 加载 C 扩展会失败
for f in src/lua55.dll src/lua.exe src/luac.exe; do
  [ -f "$f" ] || { echo "missing build output: $f" >&2; exit 1; }
done

# 架构断言：读 PE 文件头。
# 不用 objdump：MSYS2 的 mingw-w64-*-gcc 包不带它（binutils 是独立包），
# CI 上实测 aarch64-w64-mingw32-objdump: command not found。
# 直接读 PE 头：
#   offset 60 (0x3C) 是 4 字节 e_lfanew，指向 "PE\0\0" 签名
#   签名后紧跟 2 字节 Machine 字段：0x8664 = x86-64，0xaa64 = ARM64
say "artifact arch"

pe_machine() {
  # $1 = PE 文件路径
  PE_OFF=$(( $(od -An -tu4 -j 60 -N4 "$1" | tr -d ' \n') + 4 ))
  od -An -tx2 -j "$PE_OFF" -N2 "$1" | tr -d ' \n' | tr 'a-f' 'A-F' | sed 's/^0*//'
}

EXPECT_MACHINE=$([ "$ARCH" = "x64" ] && echo "8664" || echo "AA64")
ACTUAL_MACHINE=$(pe_machine src/lua.exe)
echo "PE machine: $ACTUAL_MACHINE (expect $EXPECT_MACHINE)"
if [ "$ACTUAL_MACHINE" != "$EXPECT_MACHINE" ]; then
  echo "arch mismatch: expected $EXPECT_MACHINE, got $ACTUAL_MACHINE" >&2
  exit 1
fi

# DLL 必须导出 lua_* 符号，否则 require 加载 C 扩展会找不到入口
if command -v "${PREFIX}-nm" >/dev/null 2>&1; then
  if ! "${PREFIX}-nm" -g src/lua55.dll 2>/dev/null | grep -qi 'T luaL_newstate'; then
    echo "lua55.dll 缺少 luaL_newstate 导出" >&2
    exit 1
  fi
else
  echo "warning: ${PREFIX}-nm 不可用，跳过导出符号检查" >&2
fi

# ------------------------------------------------ 5. 核心测试
# Windows 上官方 all.lua 依赖大量 POSIX 行为（/dev/full、/dev/null、
# fork、符号链接、chmod 检查），全套必然挂一堆与编译质量无关的用例。
# 改跑与编译器/ABI/运行时最相关的核心用例。
say "core tests"
TESTS_DIR="$WORKDIR/tests-${PKG}"
rm -rf "$TESTS_DIR"
mkdir -p "$TESTS_DIR"
curl -fsSL -o "$TESTS_DIR/tests.tar.gz" "https://www.lua.org/tests/${PKG}-tests.tar.gz"
tar -C "$TESTS_DIR" -xzf "$TESTS_DIR/tests.tar.gz"

LUA_EXE="$(pwd)/src/lua.exe"
FAILED=""
(
  cd "$TESTS_DIR/${PKG}-tests"
  for t in constructs.lua calls.lua closure.lua strings.lua math.lua \
           sort.lua coroutine.lua vararg.lua nextvar.lua events.lua \
           bitwise.lua goto.lua locals.lua tpack.lua utf8.lua; do
    [ -f "$t" ] || continue
    printf '%-16s ' "$t"
    if "$LUA_EXE" -e "_port=true; _soft=true; _nomsg=true" "$t" >/dev/null 2>&1; then
      echo ok
    else
      echo "FAIL"
      FAILED="$FAILED $t"
    fi
  done
)
[ -z "$FAILED" ] || { echo "failed tests:$FAILED" >&2 ; exit 1 ; }

# ------------------------------------------------ 6. 打包 ZIP
say "package zip"
cd "$WORKDIR"

VTAG="$LUA_LANG"
TAG="lua-${VERSION}-windows-${ARCH}"
STAGE="$WORKDIR/stage-windows-${ARCH}"
rm -rf "$STAGE"
mkdir -p "$STAGE/bin" "$STAGE/include" "$STAGE/lib" "$STAGE/share/lua/${VTAG}"

cp "$PKG/src/lua.exe"  "$STAGE/bin/"
cp "$PKG/src/luac.exe" "$STAGE/bin/"
cp "$PKG/src/lua55.dll" "$STAGE/bin/"

cp "$PKG/src/lua.h" "$PKG/src/luaconf.h" "$PKG/src/lualib.h" \
   "$PKG/src/lauxlib.h" "$PKG/src/lua.hpp" "$STAGE/include/"

cp "$PKG/src/liblua.a"   "$STAGE/lib/" 2>/dev/null || true
cp "$PKG/src/lua55.dll.a" "$STAGE/lib/" 2>/dev/null || true

cp "$PKG/doc/readme.html" "$STAGE/README-lua.html" 2>/dev/null || true
# MIT 许可要求随分发附带版权声明
cp "${SCRIPT_DIR}/../packaging/LICENSE" "$STAGE/LICENSE"

cat > "$STAGE/BUILD-INFO" <<EOF
lua ${VERSION}
plat windows
arch ${ARCH}
compiler ${PREFIX}-gcc
built-at $(date -u +%Y-%m-%dT%H:%M:%SZ)
msystem ${MSYSTEM:-unknown}
cc $(${PREFIX}-gcc --version 2>/dev/null | head -1 || echo unknown)
EOF

rm -f "$OUTDIR/${TAG}.zip"
(cd "$STAGE" && zip -qr "$OUTDIR/${TAG}.zip" .)
(cd "$OUTDIR" && sha256sum "${TAG}.zip" > "${TAG}.zip.sha256")

say "done: ${TAG}.zip"
ls -lh "$OUTDIR/${TAG}.zip"

# ------------------------------------------------ 7. 安装包
# Inno Setup 在原生 Windows 上跑（ISCC.exe），这里只做交接：
# 把 stage 路径写出来，workflow 的 PowerShell 步骤读它去编译 .iss。
cat > "$OUTDIR/pkg-input.env" <<EOF
LUABIN_STAGE=${STAGE}
LUABIN_TAG=${TAG}
LUABIN_VERSION=${VERSION}
LUABIN_ARCH=${ARCH}
EOF
echo "stage 交接文件: $OUTDIR/pkg-input.env"
