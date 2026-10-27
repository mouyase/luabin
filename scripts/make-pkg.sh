#!/usr/bin/env sh
# luabin — 把 stage 目录打成 macOS .pkg 安装包
#
# 用法: make-pkg.sh <version> <arch> <outdir> <stage>
#
# 安装位置：/usr/local
#   bin/lua, bin/luac
#   include/lua*.h
#   lib/liblua.a
#   share/lua/<lang>/
#
# 不做签名和公证：下载后会带 com.apple.quarantine，双击被 Gatekeeper 拦。
# 走 install.sh（curl 下载不带 quarantine）不会有这个问题。

set -eu

VERSION="${1:?usage: make-pkg.sh <version> <arch> <outdir> <stage>}"
ARCH="${2:?}"
OUTDIR="${3:?}"
STAGE="${4:?}"

PKGID="cn.yojigen.luabin"
TAG="lua-${VERSION}-macos-${ARCH}"

# hostArchitectures 要求的是 Mach-O 架构名（arm64 / x86_64），
# 不是我们产物命名里用的 x64。写错会导致安装器判定架构不兼容而拒绝安装。
case "$ARCH" in
  arm64)  PKG_ARCH="arm64"  ;;
  x64|x86_64) PKG_ARCH="x86_64" ;;
  *) echo "unsupported arch for pkg: $ARCH" >&2 ; exit 1 ;;
esac

say() { printf '\n=== %s ===\n' "$*"; }

command -v pkgbuild >/dev/null 2>&1 || { echo "pkgbuild not found" >&2; exit 1; }
command -v productbuild >/dev/null 2>&1 || { echo "productbuild not found" >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# ------------------------------------------------ 1. 构建 root
# pkgbuild --root 要求目录树就是最终的安装树，
# 所以把 stage 内容按 /usr/local 结构铺好。
say "assemble payload root"
ROOT="$WORK/root"
mkdir -p "$ROOT/usr/local"

# 版本号从 VERSION 推导，不执行 stage 里的二进制：
# 交叉编译出的包可能在本机跑不了（arm64 无 Rosetta 时跑不了 x86_64）。
case "$VERSION" in
  *.*.*) VTAG="${VERSION%.*}" ;;
  *.*)   VTAG="$VERSION" ;;
  *)     echo "无法解析版本号: $VERSION" >&2 ; exit 1 ;;
esac
DOCDIR="$ROOT/usr/local/share/doc/lua-${VERSION}"

cp -R "$STAGE/bin"     "$ROOT/usr/local/"
cp -R "$STAGE/include" "$ROOT/usr/local/"
cp -R "$STAGE/lib"     "$ROOT/usr/local/"
cp -R "$STAGE/share"   "$ROOT/usr/local/"

mkdir -p "$DOCDIR" "$ROOT/usr/local/share/lua/${VTAG}"
cp "$STAGE/BUILD-INFO" "$ROOT/usr/local/share/lua/${VTAG}/BUILD-INFO"

# MIT 许可要求随分发附带版权声明，LICENSE 不能漏
for f in LICENSE README-lua.html; do
  [ -f "$STAGE/$f" ] && cp "$STAGE/$f" "$DOCDIR/"
done

find "$ROOT" -type f | sed "s|$ROOT||" | sort

# ------------------------------------------------ 2. 组件包
say "pkgbuild"
COMPONENT="$WORK/${TAG}-component.pkg"
pkgbuild \
  --root "$ROOT" \
  --identifier "${PKGID}.lua" \
  --version "$VERSION" \
  --install-location "/" \
  --ownership recommended \
  "$COMPONENT"

# ------------------------------------------------ 3. 分发配置
# welcome / readme 用纯文本，productbuild 会渲染成安装器里的说明页。
say "distribution"
cat > "$WORK/welcome.html" <<EOF
<!DOCTYPE html>
<html><head><meta charset="utf-8"></head><body>
<h2>Lua ${VERSION}</h2>
<p>Lua 是一门轻量、可嵌入的脚本语言，由 PUC-Rio 开发，MIT 许可。</p>
<p>此安装包会把 Lua ${VERSION} (${ARCH}) 安装到 <code>/usr/local</code>：</p>
<ul>
  <li><code>/usr/local/bin/lua</code> — 解释器</li>
  <li><code>/usr/local/bin/luac</code> — 字节码编译器</li>
  <li><code>/usr/local/include/</code> — C 头文件</li>
  <li><code>/usr/local/lib/liblua.a</code> — 静态库</li>
  <li><code>/usr/local/share/lua/${VTAG}/</code> — 纯 Lua 模块目录</li>
</ul>
<p>安装后如果 <code>lua</code> 命令找不到，请确认 <code>/usr/local/bin</code> 在 PATH 里。</p>
</body></html>
EOF

cat > "$WORK/conclusion.html" <<EOF
<!DOCTYPE html>
<html><head><meta charset="utf-8"></head><body>
<h2>安装完成</h2>
<p>验证安装：</p>
<pre>lua -v
lua -e 'print("hello")'</pre>
<p>此包未做 Apple 代码签名与公证。如果你是经由浏览器下载的 .pkg，
系统可能提示「无法验证开发者」。可以改用项目提供的 install.sh
（curl 下载不携带 quarantine 标记），或手动执行：</p>
<pre>xattr -d com.apple.quarantine ~/Downloads/${TAG}.pkg</pre>
</body></html>
EOF

# ------------------------------------------------ 4. 生成分发包
# distribution XML 必须先落成实体文件：
# productbuild 的 --distribution 需要真实路径，
# 而进程替换 <(...) 是 bash 专有语法，POSIX sh 下不成立。
say "distribution xml"
cat > "$WORK/distribution.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
  <title>Lua ${VERSION}</title>
  <organization>${PKGID}</organization>
  <domains enable_localSystem="true" enable_currentUserHome="false" enable_anywhere="false"/>
  <options customize="never" require-scripts="false" hostArchitectures="${PKG_ARCH}"/>
  <welcome file="welcome.html" mime-type="text/html"/>
  <conclusion file="conclusion.html" mime-type="text/html"/>
  <pkg-ref id="${PKGID}.lua"/>
  <choices-outline>
    <line choice="default">
      <line choice="${PKGID}.lua"/>
    </line>
  </choices-outline>
  <choice id="default"/>
  <choice id="${PKGID}.lua" visible="false">
    <pkg-ref id="${PKGID}.lua"/>
  </choice>
  <pkg-ref id="${PKGID}.lua" version="${VERSION}" onConclusion="none">${TAG}-component.pkg</pkg-ref>
</installer-gui-script>
EOF

say "productbuild"
productbuild \
  --distribution "$WORK/distribution.xml" \
  --package-path "$WORK" \
  --resources "$WORK" \
  "$OUTDIR/${TAG}.pkg"

# ------------------------------------------------ 5. 校验与摘要
say "verify"
pkgutil --check-signature "$OUTDIR/${TAG}.pkg" 2>&1 | head -4 || true
echo "--- payload 文件数: $(pkgutil --payload-files "$OUTDIR/${TAG}.pkg" | wc -l | tr -d ' ')"

shasum -a 256 "$OUTDIR/${TAG}.pkg" | sed "s|$OUTDIR/||" > "$OUTDIR/${TAG}.pkg.sha256"

say "done: ${TAG}.pkg"
ls -lh "$OUTDIR/${TAG}.pkg"
