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
  x86_64|amd64|x64) ARCH=x64   ; CROSS=x86_64-w64-mingw32  ;;
  aarch64|arm64)    ARCH=arm64 ; CROSS=aarch64-w64-mingw32 ;;
  *) echo "unsupported arch: ${ARCH:-$(uname -m)}" >&2 ; exit 1 ;;
esac

# 选编译器：优先当前 MSYSTEM 的原生名字（UCRT64/CLANG64 里就叫 gcc），
# 没有再退回带 target 前缀的形式（MINGW64 传统做法）。
#
# MINGW64(MSVCRT) 已被 MSYS2 标记为 deprecated，官方推荐 UCRT64。
# 用"当前环境的 gcc"而不是硬编码前缀，能同时适配这几套环境。
CC_BIN=""
for cand in gcc "${CROSS}-gcc"; do
  if command -v "$cand" >/dev/null 2>&1; then CC_BIN=$cand ; break ; fi
done
[ -n "$CC_BIN" ] || { echo "找不到 gcc（尝试过 gcc 与 ${CROSS}-gcc）" >&2 ; exit 1 ; }


# 语言版本号（5.5.1 -> 5.5）。不执行产物取版本：
# 交叉编译时本机跑不了目标架构的 exe（如 arm64 runner 上编 x64）。
case "$VERSION" in
  *.*.*) LUA_LANG="${VERSION%.*}" ;;
  *.*)   LUA_LANG="$VERSION" ;;
  *)     echo "无法解析版本号: $VERSION" >&2 ; exit 1 ;;
esac

# 版本分档。5.0 的构建系统与后来完全不同（config 驱动，无 mingw 目标，
# 源码分布在 src/lua、src/lib，产物落在 bin/lib），要单独处理。
case "$VERSION" in
  5.0|5.0.*) MAJOR=50 ;;
  5.1|5.1.*) MAJOR=51 ;;
  5.2|5.2.*) MAJOR=52 ;;
  5.3|5.3.*) MAJOR=53 ;;
  5.4|5.4.*) MAJOR=54 ;;
  5.5|5.5.*) MAJOR=55 ;;
  *) echo "unsupported version: $VERSION" >&2 ; exit 1 ;;
esac
echo "major:    $MAJOR"

# DLL 名带版本号：lua51.dll / lua52.dll / ... / lua55.dll
DLL_NAME="lua${MAJOR}.dll"
say "target: windows-${ARCH}"
echo "compiler: $CC_BIN ($("$CC_BIN" --version | head -1))"
echo "msystem:  ${MSYSTEM:-unknown}"

# ------------------------------------------------ 3. 编译
rm -rf "$PKG"
# 5.0.x 的包里有 test/lua -> ../bin/lua 这类符号链接，解包时目标还不存在，
# tar 会报 "Cannot create symlink" 并以非零码退出。容忍它。
tar zxf "${PKG}.tar.gz" || echo "tar 有警告（符号链接），继续" >&2
cd "$PKG"

say "build"

if [ "$MAJOR" = "50" ]; then
  # 5.0 没有 mingw 目标，得自己按 INSTALL 的说明手工组织。
  # 源码在 src/（核心）、src/lib/（标准库）、src/lua/（解释器）、src/luac/（编译器）。
  #
  # config 里关键项：
  #   LOADLIB/DLLIB  动态加载，Windows 默认开但显式写上更稳
  #   MYCFLAGS       5.0 用这个传宏，不是 SYSCFLAGS
  sed -i.bak \
    -e "s|^LOADLIB=.*|LOADLIB= -DUSE_DLL=1|" \
    -e "s|^DLLIB=.*|DLLIB=|" \
    -e "s|^MYCFLAGS=.*|MYCFLAGS= -O2|" \
    -e "s|^CC=.*|CC= ${CC_BIN}|" \
    config
  rm -f config.bak

  # src/Makefile 列了 ltests.o，但发布包里 ltests.c 需要 LUA_USER_H
  # 才编得出来，直接编会失败。从 OBJS 里摘掉。
  sed -i.bak '/ltests\.o/d' src/Makefile
  rm -f src/Makefile.bak
  if [ -f src/lib/Makefile ]; then
    sed -i.bak '/ltests\.o/d' src/lib/Makefile 2>/dev/null || true
    rm -f src/lib/Makefile.bak
  fi

  make

  # 5.0 产物在 bin/ 下，名字就是 lua.exe / luac.exe
  LUA_EXE="${PWD}/bin/lua.exe"
  LUAC_EXE="${PWD}/bin/luac.exe"
  INC_DIR="${PWD}/include"
  LIB_DIR="${PWD}/lib"
  SRC_DIR=""
else
  # 5.1+ 有 mingw 目标，只覆盖 CC。
  #
  # mingw recipe 内部这么写：
  #   "AR=$(CC) -shared -o" "RANLIB=strip --strip-unneeded"
  # 这俩是命令行赋值，会盖掉外层传入的同名变量。
  # 外层再传 AR/RANLIB 会和它打架，产出错架构或空 DLL。
  make mingw CC="$CC_BIN"

  LUA_EXE="${PWD}/src/lua.exe"
  LUAC_EXE="${PWD}/src/luac.exe"
  INC_DIR="${PWD}/src"
  LIB_DIR="${PWD}/src"
  SRC_DIR="${PWD}/src"
fi

[ -x "$LUA_EXE" ]  || { echo "missing $LUA_EXE" >&2 ; exit 1 ; }
[ -x "$LUAC_EXE" ] || { echo "missing $LUAC_EXE" >&2 ; exit 1 ; }

# ------------------------------------------------ 4. 自检
say "self-check"
"$LUA_EXE" -v
# 版本断言两处差异都要绕：
#   1. 5.0.x 的 _VERSION 是完整补丁号，5.1+ 只到次版本号 → 前缀匹配
#   2. 5.0 没有 obj:method() 语法 → 用 string.find(s, pat) 函数式写法
"$LUA_EXE" -e "assert(string.find(_VERSION, '^Lua ${LUA_LANG}'), 'version mismatch: ' .. tostring(_VERSION)) print('version ok:', _VERSION)"

# 只有 5.3+ 才有整数子类型和 utf8 库，按版本分支
case "$MAJOR" in
  53|54|55)
    "$LUA_EXE" -e '
      assert(math.maxinteger > 2^62, "no 64-bit integers")
      assert(utf8.len("汉字") == 2, "utf8 lib missing")
      print("modern features ok:", math.maxinteger)
    '
    ;;
  *)
    "$LUA_EXE" -e '
      local f = assert(io.open("selftest.tmp", "w")); f:write("x"); f:close()
      assert(io.open("selftest.tmp", "r"), "cannot reopen"); os.remove("selftest.tmp")
      assert(type(os.time()) == "number", "os.time broken")
      print("io/os ok")
    '
    ;;
esac

# DLL 必须存在（5.0 没有独立 DLL，静态链进 exe）
if [ "$MAJOR" != "50" ]; then
  [ -f "src/${DLL_NAME}" ] || { echo "missing src/${DLL_NAME}" >&2 ; exit 1 ; }
  if grep -qa 'luaL_newstate' "src/${DLL_NAME}"; then
    echo "DLL 导出检查通过（${DLL_NAME} 含 luaL_newstate）"
  else
    echo "${DLL_NAME} 缺少 luaL_newstate" >&2
    exit 1
  fi
fi

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
ACTUAL_MACHINE=$(pe_machine "$LUA_EXE")
echo "PE machine: $ACTUAL_MACHINE (expect $EXPECT_MACHINE)"
if [ "$ACTUAL_MACHINE" != "$EXPECT_MACHINE" ]; then
  echo "arch mismatch: expected $EXPECT_MACHINE, got $ACTUAL_MACHINE" >&2
  exit 1
fi

# ------------------------------------------------ 5. 核心测试
# 官方测试套件只从 5.2.0 开始提供。5.0/5.1 没有，跳过而不是报错。
#
# Windows 上 all.lua 依赖大量 POSIX 行为（/dev/full、fork、符号链接），
# 跑全套会挂一堆与编译质量无关的用例，所以挑核心用例逐个跑。
say "core tests"

case "$MAJOR" in
  50|51)
    echo "该版本无官方测试套件（5.2.0 起才有），跳过"
    ;;
  *)
    TESTS_URL="https://www.lua.org/tests/${PKG}-tests.tar.gz"
    TESTS_DIR="$WORKDIR/tests-${PKG}"
    rm -rf "$TESTS_DIR"
    mkdir -p "$TESTS_DIR"
    if curl -fsSL -o "$TESTS_DIR/tests.tar.gz" "$TESTS_URL"; then
      tar -C "$TESTS_DIR" -xzf "$TESTS_DIR/tests.tar.gz"
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
      [ -z "$FAILED" ] || echo "注意：这些用例失败 $FAILED（不阻断构建）" >&2
    else
      echo "该版本无官方测试套件，跳过"
    fi
    ;;
esac

# ------------------------------------------------ 6. 打包 ZIP
say "package zip"
cd "$WORKDIR"

VTAG="$LUA_LANG"
TAG="lua-${VERSION}-windows-${ARCH}"
STAGE="$WORKDIR/stage-windows-${ARCH}-${VERSION}"
rm -rf "$STAGE"
mkdir -p "$STAGE/bin" "$STAGE/include" "$STAGE/lib" "$STAGE/share/lua/${VTAG}"

cp "$LUA_EXE"  "$STAGE/bin/lua.exe"
cp "$LUAC_EXE" "$STAGE/bin/luac.exe"

# DLL 只在 5.1+ 存在。
# 注意用绝对路径：这里已经 cd 到 $WORKDIR，相对路径 src/ 指向的是
# $WORKDIR/src，不存在，[ -f ] 判断会静默失败，DLL 就漏掉了。
if [ "$MAJOR" != "50" ]; then
  if [ -f "${SRC_DIR}/${DLL_NAME}" ]; then
    cp "${SRC_DIR}/${DLL_NAME}" "$STAGE/bin/"
    echo "packaged ${DLL_NAME}"
  else
    echo "missing ${SRC_DIR}/${DLL_NAME}" >&2
    exit 1
  fi
  [ -f "${SRC_DIR}/${DLL_NAME}.a" ] && cp "${SRC_DIR}/${DLL_NAME}.a" "$STAGE/lib/"
fi

# 头文件：5.0 在 include/，5.1 的 lua.hpp 在 etc/，5.2+ 都在 src/
for h in lua.h luaconf.h lualib.h lauxlib.h; do
  [ -f "$INC_DIR/$h" ] && cp "$INC_DIR/$h" "$STAGE/include/"
done
if [ -f "$INC_DIR/lua.hpp" ]; then
  cp "$INC_DIR/lua.hpp" "$STAGE/include/"
elif [ -f "$PKG/etc/lua.hpp" ]; then
  cp "$PKG/etc/lua.hpp" "$STAGE/include/"
fi

# 静态库：5.0 有两个
[ -f "$LIB_DIR/liblua.a" ]    && cp "$LIB_DIR/liblua.a"    "$STAGE/lib/"
[ -f "$LIB_DIR/liblualib.a" ] && cp "$LIB_DIR/liblualib.a" "$STAGE/lib/"

[ -f "$PKG/doc/readme.html" ] && cp "$PKG/doc/readme.html" "$STAGE/README-lua.html"
cp "${SCRIPT_DIR}/../packaging/LICENSE.lua" "$STAGE/LICENSE"

cat > "$STAGE/BUILD-INFO" <<EOF
lua ${VERSION}
plat windows
arch ${ARCH}
major ${MAJOR}
compiler ${CC_BIN}
built-at $(date -u +%Y-%m-%dT%H:%M:%SZ)
msystem ${MSYSTEM:-unknown}
cc $($CC_BIN --version 2>/dev/null | head -1 || echo unknown)
EOF

rm -f "$OUTDIR/${TAG}.zip"
(cd "$STAGE" && zip -qr "$OUTDIR/${TAG}.zip" .)

# 自检 stage 内容：DLL 漏了的话 lua.exe 在用户机器上直接起不来，
# 这类错误编译阶段发现不了，必须在打包后查一次。
#
# 不用 unzip 查 zip 内容：MSYS2 只装了 zip 没装 unzip（CI 上实测
# `unzip: command not found`）。直接查 stage 目录更简单可靠。
if [ "$MAJOR" != "50" ]; then
  if [ -f "$STAGE/bin/${DLL_NAME}" ]; then
    echo "stage 含 ${DLL_NAME}"
  else
    echo "stage 里缺少 bin/${DLL_NAME}" >&2
    ls -la "$STAGE/bin"
    exit 1
  fi
fi

# 目录结构总览，出问题时便于对照
echo "stage 内容:"
(cd "$STAGE" && find . -type f | sort)
(cd "$OUTDIR" && sha256sum "${TAG}.zip" > "${TAG}.zip.sha256")

say "done: ${TAG}.zip"
ls -lh "$OUTDIR/${TAG}.zip"

# ------------------------------------------------ 7. 安装包交接
# Inno Setup 在原生 Windows 上跑（ISCC.exe），这里只做交接：
# 把 stage 路径写出来，workflow 的 PowerShell 步骤读它去编译 .iss。
#
# 关键：必须写成 Windows 路径。MSYS2 的 $PWD 是 /c/a/luabin/... 这种形式，
# PowerShell 的 Test-Path 认不出来（实测报 "stage 目录不存在"）。
# cygpath -w 在 MSYS2 里一定存在，转换后再写。
win_path() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -w "$1"
  else
    # 退路：手写前缀替换。cut -c3- 会吃掉盘符后的第一个 "/"，
    # 必须自己补回来，否则 c:\luabin 会变成 c:luabin。
    p=$1
    case "$p" in
      /[a-zA-Z]/*)
        drive=$(printf '%s' "$p" | cut -c2 | tr 'a-z' 'A-Z')
        rest=$(printf '%s' "$p" | cut -c3- | tr '/' '\\')
        printf '%s:%s\n' "$drive" "$rest"
        ;;
      *) echo "$p" ;;
    esac
  fi
}

STAGE_WIN=$(win_path "$STAGE")
OUTDIR_WIN=$(win_path "$OUTDIR")

cat > "$OUTDIR/pkg-input.env" <<EOF
LUABIN_STAGE=${STAGE_WIN}
LUABIN_OUTDIR=${OUTDIR_WIN}
LUABIN_TAG=${TAG}
LUABIN_VERSION=${VERSION}
LUABIN_ARCH=${ARCH}
LUABIN_LANG=${LUA_LANG}
LUABIN_DLL=${DLL_NAME}
EOF
echo "stage 交接文件（Windows 路径）:"
cat "$OUTDIR/pkg-input.env"
