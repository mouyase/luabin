#!/usr/bin/env pwsh
<#
.SYNOPSIS
  luabin — Windows 一键安装

.DESCRIPTION
  下载预编译的 Lua ZIP，解压到指定目录，可选写入用户 PATH。
  不需要管理员权限，装到用户目录下。

.EXAMPLE
  irm https://raw.githubusercontent.com/mouyase/luabin/main/install.ps1 | iex

.EXAMPLE
  # 装到指定目录
  $env:LUABIN_PREFIX = "$env:LOCALAPPDATA\Programs\Lua"; .\install.ps1
#>

$ErrorActionPreference = 'Stop'

$LuabinVersion = if ($env:LUABIN_VERSION) { $env:LUABIN_VERSION } else { '5.5.1' }
$LuabinRepo    = if ($env:LUABIN_REPO)    { $env:LUABIN_REPO }    else { 'mouyase/luabin' }
$Prefix        = if ($env:LUABIN_PREFIX)  { $env:LUABIN_PREFIX }  else { "$env:LOCALAPPDATA\Programs\Lua\$LuabinVersion" }
$Force         = $env:LUABIN_FORCE -eq '1'

function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Info($msg) { Write-Host "    $msg" }
function Write-Warn($msg) { Write-Host "警告: $msg" -ForegroundColor Yellow }
function Fail($msg) { Write-Host "`n错误: $msg" -ForegroundColor Red; exit 1 }

# ------------------------------------------------ 平台判定
Write-Step '检测平台'

$archRaw = $env:PROCESSOR_ARCHITECTURE
# 32 位 PowerShell 跑在 64 位系统上时 PROCESSOR_ARCHITECTURE 是 x86，
# 真正要看的是 PROCESSOR_ARCHITEW6432
if ($env:PROCESSOR_ARCHITEW6432) { $archRaw = $env:PROCESSOR_ARCHITEW6432 }

switch ($archRaw) {
    'AMD64' { $arch = 'x64' }
    'ARM64' { $arch = 'arm64' }
    default { Fail "不支持的架构: $archRaw" }
}

Write-Info "系统: Windows ($archRaw) -> windows-$arch"
Write-Info "版本: $LuabinVersion"

# ------------------------------------------------ 已安装检查
if ((Test-Path "$Prefix\bin\lua.exe") -and -not $Force) {
    $existing = & "$Prefix\bin\lua.exe" -v 2>&1
    Write-Warn "已存在安装: $existing"
    Write-Warn "路径: $Prefix\bin\lua.exe"
    $ans = Read-Host '继续会覆盖，是否继续? [y/N]'
    if ($ans -notmatch '^[yY]') { Write-Info '已取消'; exit 0 }
}

# ------------------------------------------------ 下载
Write-Step "下载 lua-$LuabinVersion-windows-$arch.zip"

$tag      = "lua-$LuabinVersion-windows-$arch"
$fileName = "$tag.zip"
$baseUrl  = "https://github.com/$LuabinRepo/releases/download/v$LuabinVersion"
$tmp      = Join-Path ([System.IO.Path]::GetTempPath()) ("luabin-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

try {
    $zipPath = Join-Path $tmp $fileName
    try {
        Invoke-WebRequest -Uri "$baseUrl/$fileName" -OutFile $zipPath -UseBasicParsing
    } catch {
        Fail "下载失败。确认版本 $LuabinVersion 已发布: https://github.com/$LuabinRepo/releases"
    }
    Write-Info "已下载 $([math]::Round((Get-Item $zipPath).Length / 1KB, 1)) KB"

    # sha256 校验
    # 注意：不能把"校验失败就退出"塞进 try/catch 里，
    # 外层 catch 会把失败原因吞掉，最后只剩一句"跳过校验"。
    # 分成两步：先尝试取 .sha256 文件（失败可容忍），
    # 取到了就必须校验通过。
    $shaUrl = "$baseUrl/$fileName.sha256"
    $shaText = $null
    try {
        $shaText = (Invoke-WebRequest -Uri $shaUrl -UseBasicParsing).Content
    } catch {
        $shaText = $null
    }

    if ($shaText) {
        $expected = ($shaText -split '\s+')[0].Trim().ToLower()
        $actual = (Get-FileHash -Path $zipPath -Algorithm SHA256).Hash.ToLower()
        if ($expected -ne $actual) {
            Fail "sha256 校验失败`n  期望: $expected`n  实际: $actual"
        }
        Write-Info 'sha256 校验通过'
    } else {
        Write-Warn '未找到 .sha256 文件，跳过校验'
    }

    # ------------------------------------------------ 解压
    Write-Step "安装到 $Prefix"

    # 先解到临时目录再覆盖过去，避免解压中途失败留下半个安装
    $extract = Join-Path $tmp 'extract'
    Expand-Archive -Path $zipPath -DestinationPath $extract -Force

    if (Test-Path $Prefix) { Remove-Item $Prefix -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Path $Prefix -Force | Out-Null
    Copy-Item -Path "$extract\*" -Destination $Prefix -Recurse -Force

    Write-Info '已安装:'
    Write-Info "  $Prefix\bin\lua.exe"
    Write-Info "  $Prefix\bin\luac.exe"
    Write-Info "  $Prefix\bin\lua55.dll"
    Write-Info "  $Prefix\include\lua*.h"
    Write-Info "  $Prefix\lib\liblua.a"

    # ------------------------------------------------ 验证
    Write-Step '验证'
    & "$Prefix\bin\lua.exe" -v
    & "$Prefix\bin\lua.exe" -e 'print("hello from lua", _VERSION)'

    # ------------------------------------------------ PATH
    Write-Step 'PATH'

    $binPath = "$Prefix\bin"
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (-not $userPath) { $userPath = '' }

    $segments = $userPath -split ';' | Where-Object { $_ -ne '' }
    if ($segments -contains $binPath) {
        Write-Info "用户 PATH 已包含 $binPath"
    } else {
        $newPath = if ($userPath.Trim() -eq '') { $binPath } else { "$userPath;$binPath" }
        [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
        # 同时更新当前会话，装完立刻能验证
        $env:Path = "$env:Path;$binPath"
        Write-Info "已把 $binPath 加入用户 PATH（仅当前用户，不需要管理员）"
        Write-Info '新开的终端会生效；当前终端已临时生效'
    }

    Write-Step '完成'
    Write-Info '验证是否可用:'
    Write-Info '  lua -v'
    Write-Info "如需卸载: 删除 $Prefix，并从用户 PATH 里移除 $binPath"
}
finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
