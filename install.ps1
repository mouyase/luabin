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
$Mirror        = $env:LUABIN_MIRROR

# GitHub 在部分地区直连不通（实测 raw.githubusercontent.com 与
# github.com 都会直接断流，报 unexpected EOF）。
# 这里按顺序试：用户指定镜像 → 官方 → 第三方代理。
# 无论走哪条，最终都用官方 .sha256 校验，内容被篡改会立刻暴露。
$MirrorPrefixes = @()
if ($Mirror) { $MirrorPrefixes += $Mirror.TrimEnd('/') + '/' }
$MirrorPrefixes += ''
$MirrorPrefixes += 'https://ghfast.top'
$MirrorPrefixes += 'https://gh-proxy.com'

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
    $shaPath = "$zipPath.sha256"

    # 逐个前缀尝试。镜像前缀直接拼在原 URL 前面，
    # 形如 https://ghfast.top/https://github.com/...（代理的标准用法）。
    #
    # 用 System.Net.Http.HttpClient 而不是 Invoke-WebRequest：
    # 后者在部分网络故障下 TimeoutSec 不生效（实测连 127.0.0.1:9
    # 会无限挂住），而 HttpClient 的 Timeout 是硬超时。
    $downloaded = $false
    $usedPrefix = $null

    Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue

    foreach ($pfx in $MirrorPrefixes) {
        $label = if ($pfx) { $pfx } else { '直连' }
        $url = if ($pfx) { "$pfx/$baseUrl/$fileName" } else { "$baseUrl/$fileName" }
        Write-Info "尝试 [$label]"

        $handler = New-Object System.Net.Http.HttpClientHandler
        $handler.AllowAutoRedirect = $true
        $client = New-Object System.Net.Http.HttpClient($handler)
        # 硬超时：连接与整体下载都受它约束
        $client.Timeout = [TimeSpan]::FromSeconds(90)
        try {
            $resp = $client.GetAsync($url, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
            if (-not $resp.IsSuccessStatusCode) {
                throw "HTTP $([int]$resp.StatusCode)"
            }
            $fs = [System.IO.File]::Create($zipPath)
            try {
                $resp.Content.CopyToAsync($fs).GetAwaiter().GetResult()
            } finally { $fs.Dispose(); $resp.Dispose() }
            if ((Get-Item $zipPath).Length -lt 10240) {
                throw "文件过小（$((Get-Item $zipPath).Length) 字节），可能是错误页"
            }
            $downloaded = $true
            $usedPrefix = $pfx
            Write-Info "下载成功（$label）"
            break
        } catch {
            $reason = $_.Exception.Message
            if ($_.Exception.InnerException) { $reason = $_.Exception.InnerException.Message }
            Write-Info "失败: $reason"
            if (Test-Path $zipPath) { Remove-Item $zipPath -Force -ErrorAction SilentlyContinue }
        } finally {
            $client.Dispose()
            $handler.Dispose()
        }
    }

    if (-not $downloaded) {
        Fail @"
下载失败。所有通道都不可用：
  $($MirrorPrefixes | ForEach-Object { if ($_) { $_ } else { '直连' } } | Join-String -Separator ' / ')

排查办法：
  1. 手动下载后解压到 $Prefix
     https://github.com/$LuabinRepo/releases/download/v$LuabinVersion/$fileName
  2. 或用 gh 命令行：gh release download v$LuabinVersion -R $LuabinRepo
  3. 或指定可用镜像：`$env:LUABIN_MIRROR='https://your-proxy'; irm ... | iex
"@
    }

    Write-Info "已下载 $([math]::Round((Get-Item $zipPath).Length / 1KB, 1)) KB"

    # sha256 校验
    # sha256 文件必须从下载成功的同一通道取，否则代理不可用时
    # 校验环节又会失败一次。
    #
    # 注意：不能把"校验失败就退出"塞进 try/catch 里，
    # 外层 catch 会把失败原因吞掉，最后只剩一句"跳过校验"。
    # 分成两步：先尝试取 .sha256 文件（失败可容忍），
    # 取到了就必须校验通过。
    $shaText = $null
    foreach ($pfx in @($usedPrefix) + $MirrorPrefixes) {
        $url = if ($pfx) { "$pfx/$baseUrl/$fileName.sha256" } else { "$baseUrl/$fileName.sha256" }
        $h2 = New-Object System.Net.Http.HttpClientHandler
        $c2 = New-Object System.Net.Http.HttpClient($h2)
        $c2.Timeout = [TimeSpan]::FromSeconds(20)
        try {
            $t = $c2.GetStringAsync($url).GetAwaiter().GetResult()
            if ($t) { $shaText = $t.Trim(); break }
        } catch { $shaText = $null }
        finally { $c2.Dispose(); $h2.Dispose() }
    }

    if ($shaText) {
        $expected = ($shaText -split '\s+')[0].Trim().ToLower()
        $actual = (Get-FileHash -Path $zipPath -Algorithm SHA256).Hash.ToLower()
        if ($expected -ne $actual) {
            Fail "sha256 校验失败，下载内容可能被篡改`n  期望: $expected`n  实际: $actual"
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
