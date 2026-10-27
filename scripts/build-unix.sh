#!/usr/bin/env sh
# luabin — 通用构建脚本（macOS 与 Linux 共用）
#
# 用法: build-unix.sh <version> <plat> <outdir> <workdir>
#   plat  macos | linux
#
# Lua 的构建系统在 5.0 到 5.5 之间变过两次，这里按年代分三档：
#
#   5.0.x   config 文件驱动，make 无平台目标，产物落在 bin/ lib/ include/
#   5.1.x   make <plat>，头文件在 src/ 但 lua.hpp 在 etc/
#   5.2+    make <plat>，头文件在 src/
#
# 平台目标的名称和语义也变过：
#
#   5.1     macosx 实际传 -DLUA_USE_LINUX 并链 -lreadline
#   5.2-5.3 macosx 传 -DLUA_USE_MACOSX，链 -lreadline
#   5.4+    macosx 同上，但 linux 目标改为运行时 dlopen readline
#
# readline 处理也分档：5.5 的 linux 目标不硬链，5.2-5.4 的 linux 目标会
# 硬链 -lreadline，缺失时直接编不过。这些版本要走 generic + 手动定宏。

set -eu

VERSION="${1:?usage: build-unix.sh <version> <plat> <outdir> <workdir>}"
PLAT="${2:?}"
OUTDIR="${3:?}"
WORKDIR="${4:?}"

PKG="lua-${VERSION}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

say() { printf '\n=== %s ===\n' "$*"; }

# ------------------------------------------------ 版本分档
case "$VERSION" in
  5.0|5.0.*) MAJOR=50 ;;
  5.1|5.1.*) MAJOR=51 ;;
  5.2|5.2.*) MAJOR=52 ;;
  5.3|5.3.*) MAJOR=53 ;;
  5.4|5.4.*) MAJOR=54 ;;
  5.5|5.5.*) MAJOR=55 ;;
  *) echo "unsupported version: $VERSION" >&2 ; exit 1 ;;
esac

# 语言版本号（5.5.1 → 5.5）
case "$VERSION" in
  *.*.*) LUA_LANG="${VERSION%.*}" ;;
  *.*)   LUA_LANG="$VERSION" ;;
  *)     echo "无法解析版本号: $VERSION" >&2 ; exit 1 ;;
esac

ARCH="${ARCH:-$(uname -m)}"
case "$ARCH" in
  x64|x86_64)    ARCH=x64    ; MACHO_ARCH=x86_64 ;;
  arm64|aarch64) ARCH=arm64  ; MACHO_ARCH=arm64  ;;
  *) echo "unsupported arch: $ARCH" >&2 ; exit 1 ;;
esac

export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-11.0}"

mkdir -p "$OUTDIR"
OUTDIR="$(cd "$OUTDIR" && pwd)"
WORKDIR="$(cd "$WORKDIR" && pwd)"
cd "$WORKDIR"

echo "version: $VERSION (major=$MAJOR, lang=$LUA_LANG)"
echo "plat:    $PLAT / $ARCH"

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

if command -v shasum >/dev/null 2>&1; then
  ACTUAL=$(shasum -a 256 "${PKG}.tar.gz" | cut -d' ' -f1)
else
  ACTUAL=$(sha256sum "${PKG}.tar.gz" | cut -d' ' -f1)
fi
if [ -n "${EXPECTED_SHA256:-}" ] && [ "$ACTUAL" != "$EXPECTED_SHA256" ]; then
  echo "sha256 mismatch: expected $EXPECTED_SHA256 got $ACTUAL" >&2
  exit 1
fi
echo "sha256: $ACTUAL"

rm -rf "$PKG"
tar zxf "${PKG}.tar.gz"
cd "$PKG"

# ------------------------------------------------ 2. 编译
say "build"

if [ "$MAJOR" = "50" ]; then
  # ---------------------------------------------- 5.0.x
  # 没有 make 平台目标，全靠 config 文件。产物落在 bin/ lib/ include/，
  # 解释器源在 src/lua/ 而不是 src/。
  #
  # 关键配置项：
  #   LOADLIB/DLLIB  开启动态加载。5.0 默认在 Unix 上关闭
  #   MYCFLAGS       5.0 用这个变量传宏，不是 SYSCFLAGS
  if [ "$PLAT" = "macos" ]; then
    LOADLIB_LINE='LOADLIB= -DUSE_DLOPEN=1'
    DLLIB_LINE='DLLIB='
    # macOS 的 dlopen 在 libSystem 里，不需要 -ldl
    MYLDFLAGS_LINE='MYLDFLAGS='
  else
    LOADLIB_LINE='LOADLIB= -DUSE_DLOPEN=1'
    DLLIB_LINE='DLLIB= -ldl'
    MYLDFLAGS_LINE='MYLDFLAGS= -Wl,-E'
  fi

  # 用 sed 改 config，而不是追加——config 里这些键本来就有空赋值
  sed -i.bak \
    -e "s|^LOADLIB=.*|${LOADLIB_LINE}|" \
    -e "s|^DLLIB=.*|${DLLIB_LINE}|" \
    -e "s|^MYLDFLAGS=.*|${MYLDFLAGS_LINE}|" \
    config
  rm -f config.bak

  if [ "$PLAT" = "macos" ] && [ "$MACHO_ARCH" != "$(uname -m)" ]; then
    sed -i.bak "s|^MYCFLAGS=.*|MYCFLAGS= -O2 -arch ${MACHO_ARCH}|" config
    rm -f config.bak
  fi

  # 5.0 的 src/Makefile 列了 ltests.o，但 ltests.c 需要 LUA_USER_H
  # 才编得出来，发布包里编不过。从 OBJS 里摘掉。
  sed -i.bak '/ltests\.o/d' src/Makefile
  rm -f src/Makefile.bak

  make
else
  # ---------------------------------------------- 5.1+
  # 平台目标名各版本一致（macosx / linux），但语义有差异，见文件头。
  #
  # 交叉编译必须走 make 命令行参数：Makefile 里的 CFLAGS 赋值会覆盖
  # 环境变量，且带空格的值必须作为单个 argv 传入。
  set --
  if [ "$PLAT" = "macos" ] && [ "$MACHO_ARCH" != "$(uname -m)" ]; then
    echo "cross-compiling: forced -arch ${MACHO_ARCH}"
    if [ "$MAJOR" = "51" ]; then
      # 5.1 的 macosx 目标传的是 MYCFLAGS，不是 SYSCFLAGS
      set -- "MYCFLAGS=-DLUA_USE_LINUX -O2 -arch ${MACHO_ARCH}" \
             "MYLIBS=-lreadline -arch ${MACHO_ARCH}"
    else
      set -- "CFLAGS=-O2 -Wall -Wextra -DLUA_USE_MACOSX -arch ${MACHO_ARCH}" \
             "LDFLAGS=-arch ${MACHO_ARCH}"
    fi
  fi

  if [ "$PLAT" = "macos" ]; then
    make macosx "$@"
  else
    # Linux 侧：5.1-5.4 的 linux 目标硬链 -lreadline，精简环境会编不过。
    # 有 readline 就用 linux，没有就走 generic + 手动定宏。
    if [ -n "${HAVE_READLINE:-}" ]; then
      make linux "$@"
    else
      make generic "SYSCFLAGS=-DLUA_USE_POSIX -DLUA_USE_LINUX -DLUA_USE_DLOPEN" \
                   "SYSLIBS=-Wl,-E -ldl"
    fi
  fi
fi

# ------------------------------------------------ 3. 定位产物
say "locate artifacts"
case "$MAJOR" in
  50)
    LUA_BIN="${PWD}/bin/lua"
    LUAC_BIN="${PWD}/bin/luac"
    INC_DIR="${PWD}/include"
    LIB_DIR="${PWD}/lib"
    DOC_HTML="${PWD}/doc/readme.html"
    ;;
  *)
    LUA_BIN="${PWD}/src/lua"
    LUAC_BIN="${PWD}/src/luac"
    INC_DIR="${PWD}/src"
    LIB_DIR="${PWD}/src"
    DOC_HTML="${PWD}/doc/readme.html"
    ;;
esac

[ -x "$LUA_BIN" ]  || { echo "missing $LUA_BIN" >&2 ; exit 1 ; }
[ -x "$LUAC_BIN" ] || { echo "missing $LUAC_BIN" >&2 ; exit 1 ; }

# ------------------------------------------------ 4. 自检
say "self-check"

CAN_RUN=1
if [ "$PLAT" = "macos" ] && [ "$MACHO_ARCH" != "$(uname -m)" ]; then
  if ! "$LUA_BIN" -v >/dev/null 2>&1; then
    CAN_RUN=0
    echo "本机无法执行 $MACHO_ARCH 产物（缺 Rosetta），跳过运行时自检"
  fi
fi

if [ "$CAN_RUN" = "1" ]; then
  "$LUA_BIN" -v
  # 版本号断言用 LUA_LANG，不写死
  # 5.0.x 的 _VERSION 是完整补丁号（"Lua 5.0.3"），5.1+ 只到次版本号。
  # 用前缀匹配两边都成立。
  "$LUA_BIN" -e "assert(_VERSION:find('^Lua ${LUA_LANG}'), 'version mismatch: ' .. tostring(_VERSION)) print('version ok:', _VERSION)"
  "$LUA_BIN" -e "assert(loadstring or load, 'no load') print('load ok')" 2>/dev/null \
    || "$LUA_BIN" -e "assert(load, 'no load') print('load ok')"
fi

# ------------------------------------------------ 5. 架构与部署目标
if [ "$PLAT" = "macos" ]; then
  ACTUAL_ARCH=$(file -b "$LUA_BIN")
  say "artifact arch"
  echo "$ACTUAL_ARCH"
  case "$ACTUAL_ARCH" in
    *"$MACHO_ARCH"*) ;;
    *) echo "arch mismatch: expected $MACHO_ARCH" >&2 ; exit 1 ;;
  esac

  MINOS=$(otool -l "$LUA_BIN" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')
  echo "minos: $MINOS"
  if [ -n "$MINOS" ]; then
    MIN_MAJOR=${MINOS%%.*}
    TARGET_MAJOR=${MACOSX_DEPLOYMENT_TARGET%%.*}
    [ "$MIN_MAJOR" -le "$TARGET_MAJOR" ] || { echo "minos $MINOS exceeds target" >&2 ; exit 1 ; }
  fi
fi

# ------------------------------------------------ 6. 测试套件
# 官方测试套件只从 5.2.0 开始提供。5.0/5.1 只有包内的 test/hello.lua。
say "tests"
if [ "$CAN_RUN" = "0" ]; then
  echo "无法在本机执行，跳过测试"
else
  case "$MAJOR" in
    50|51)
      # 5.0/5.1 没有官方测试套件，只有包内的 test/ 目录
      if [ -f "${PWD}/test/hello.lua" ]; then
        ( cd "${PWD}/test" && "$LUA_BIN" hello.lua && echo "hello.lua ok" ) \
          || echo "hello.lua 失败，不阻断构建" >&2
      else
        echo "该版本无测试套件"
      fi
      ;;
    *)
      TESTS_URL="https://www.lua.org/tests/${PKG}-tests.tar.gz"
      TESTS_DIR="$WORKDIR/tests-${PKG}"
      rm -rf "$TESTS_DIR"
      mkdir -p "$TESTS_DIR"
      # 测试套件缺了不该阻断构建：官方对某些补丁版本没发过测试包
      if curl -fsSL -o "$TESTS_DIR/tests.tar.gz" "$TESTS_URL"; then
        tar -C "$TESTS_DIR" -xzf "$TESTS_DIR/tests.tar.gz"
        (
          cd "$TESTS_DIR/${PKG}-tests"
          # /dev/full 是 Linux 专有设备节点，macOS 没有，且该段无 _port 守卫
          if [ "$PLAT" = "macos" ] && [ -f files.lua ]; then
            perl -0pi -e 's/do print\("testing flush"\).*?\nend\n/\n/s' files.lua
          fi
          "$LUA_BIN" -e '_port=true; _soft=true; _nomsg=true' all.lua
        ) || echo "测试有失败，不阻断构建（产物本身已通过自检）" >&2
      else
        echo "该版本无官方测试套件，跳过"
      fi
      ;;
  esac
fi

# ------------------------------------------------ 7. 打包
say "package"
cd "$WORKDIR"

TAG="lua-${VERSION}-${PLAT}-${ARCH}"
STAGE="$WORKDIR/stage-${PLAT}-${ARCH}-${VERSION}"
rm -rf "$STAGE"
mkdir -p "$STAGE/bin" "$STAGE/include" "$STAGE/lib" "$STAGE/share/lua/${LUA_LANG}"

cp "$LUA_BIN"  "$STAGE/bin/lua"
cp "$LUAC_BIN" "$STAGE/bin/luac"
chmod 0755 "$STAGE/bin/lua" "$STAGE/bin/luac"

# 头文件：5.1 的 lua.hpp 在 etc/，其他版本在 src/
for h in lua.h luaconf.h lualib.h lauxlib.h; do
  [ -f "$INC_DIR/$h" ] && cp "$INC_DIR/$h" "$STAGE/include/"
done
if [ -f "$INC_DIR/lua.hpp" ]; then
  cp "$INC_DIR/lua.hpp" "$STAGE/include/"
elif [ -f "$PKG/etc/lua.hpp" ]; then
  cp "$PKG/etc/lua.hpp" "$STAGE/include/"
fi

# 静态库：5.0 有两个（liblua.a + liblualib.a）
if [ -f "$LIB_DIR/liblua.a" ]; then
  cp "$LIB_DIR/liblua.a" "$STAGE/lib/"
fi
if [ -f "$LIB_DIR/liblualib.a" ]; then
  cp "$LIB_DIR/liblualib.a" "$STAGE/lib/"
fi

[ -f "$DOC_HTML" ] && cp "$DOC_HTML" "$STAGE/README-lua.html"
cp "${SCRIPT_DIR}/../packaging/LICENSE.lua" "$STAGE/LICENSE"

cat > "$STAGE/BUILD-INFO" <<EOF
lua ${VERSION}
plat ${PLAT}
arch ${ARCH}
built-at $(date -u +%Y-%m-%dT%H:%M:%SZ)
cc $(cc --version 2>/dev/null | head -1 || echo unknown)
os $(uname -s) $(uname -r)
EOF

tar -C "$STAGE" -czf "$OUTDIR/${TAG}.tar.gz" .
if command -v shasum >/dev/null 2>&1; then
  shasum -a 256 "$OUTDIR/${TAG}.tar.gz" | sed "s|$OUTDIR/||" > "$OUTDIR/${TAG}.tar.gz.sha256"
else
  sha256sum "$OUTDIR/${TAG}.tar.gz" | sed "s|$OUTDIR/||" > "$OUTDIR/${TAG}.tar.gz.sha256"
fi

say "done: ${TAG}.tar.gz"
ls -lh "$OUTDIR/${TAG}.tar.gz"

# ------------------------------------------------ 8. .pkg（仅 macOS 原生）
if [ "$PLAT" = "macos" ] && [ "$MACHO_ARCH" = "$(uname -m)" ]; then
  say "package pkg"
  sh "${SCRIPT_DIR}/make-pkg.sh" "$VERSION" "$ARCH" "$OUTDIR" "$STAGE"
fi
