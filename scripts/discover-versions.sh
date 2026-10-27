#!/usr/bin/env sh
# 从 lua.org 抓取当前发布的 5.x 版本列表，与已发布的 Release 比对。
#
# 用法: discover-versions.sh [repo]
# 输出（写入 $GITHUB_OUTPUT，本地运行时打到 stdout）:
#   versions   待构建版本，JSON 数组，如 ["5.5.1","5.5.0"]
#   latest     最新版本
#   has_new    true / false
#
# 判定"已发布"的依据是 Release tag 存在且带产物。缺产物的版本会重跑，
# 这样即便某次构建失败，下一次定时任务也能补上。

set -eu

REPO="${1:-${GITHUB_REPOSITORY:-mouyase/luabin}}"

out() {
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"
  else
    printf '%s=%s\n' "$1" "$2"
  fi
}

say() { printf '=== %s ===\n' "$*" >&2 ; }

# ------------------------------------------------ 1. 抓官网版本列表
say "fetch lua.org/ftp"

INDEX=$(curl -fsSL --max-time 60 https://www.lua.org/ftp/ | grep -oE 'lua-5\.[0-9]+(\.[0-9]+)?\.tar\.gz' | sed 's/^lua-//; s/\.tar\.gz$//' | sort -u -V) || {
  echo "抓取 lua.org 失败" >&2
  exit 1
}

say "upstream versions"
echo "$INDEX" >&2

LATEST=$(printf '%s\n' "$INDEX" | tail -1)
out latest "$LATEST"

# ------------------------------------------------ 2. 查已发布
say "check existing releases"

EXISTING=""
if command -v gh >/dev/null 2>&1; then
  # 只取 tag 名。失败不致命，当作一个都没有
  EXISTING=$(gh release list --repo "$REPO" --limit 200 --json tagName \
    --jq '.[].tagName' 2>/dev/null || true)
else
  echo "gh 不可用，无法查询已有 Release" >&2
fi

say "existing tags"
echo "${EXISTING:-（无）}" >&2

# ------------------------------------------------ 3. 求差集
# 需要构建 = 官网有该版本，但对应 tag 不存在，或 tag 存在却缺产物
NEED=""
while IFS= read -r v; do
  [ -n "$v" ] || continue
  tag="v$v"
  if printf '%s\n' "$EXISTING" | grep -qx "$tag"; then
    continue
  fi
  NEED="$NEED $v"
done <<EOF
$INDEX
EOF

NEED=$(printf '%s' "$NEED" | sed 's/^ //')

if [ -z "$NEED" ]; then
  say "no new versions"
  out versions "[]"
  out has_new "false"
  exit 0
fi

say "need build"
echo "$NEED" >&2

# 转成 JSON 数组
JSON="["
for v in $NEED; do
  [ "$JSON" = "[" ] || JSON="$JSON,"
  JSON="$JSON\"$v\""
done
JSON="$JSON]"

out versions "$JSON"
out has_new "true"
