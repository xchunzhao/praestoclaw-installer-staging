# qa-record 全自动一键安装（Windows）
# 用法（PowerShell）：
#   irm https://raw.githubusercontent.com/xchunzhao/praestoclaw-installer-staging/qa-record/installer.ps1 | iex
#
# 如果提示脚本被禁用，先跑一次：
#   Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force

$ErrorActionPreference = 'Stop'

# ========== 仓库位置（同一分支放 installer 和 tgz） ==========
$RawBase = 'https://raw.githubusercontent.com/xchunzhao/praestoclaw-installer-staging/qa-record'
$TgzName = 'qa-record.tgz'

# ========== 可选环境（tester 装的时候会选一个） ==========
$Environments = @(
    @{ Name = 'staging';     Url = 'https://staging.societas.microsoft.com'; LoginPath = '/login' },
    @{ Name = 'production';  Url = 'https://societas.microsoft.com';         LoginPath = '/login' },
    @{ Name = 'dev';         Url = 'https://dev.societas.microsoft.com';     LoginPath = '/login' }
)
# 支持从环境变量指定，绕过交互（irm | iex 时用）：
#   $env:QA_ENV='production'; irm ... | iex
$PresetEnv = $env:QA_ENV
# ==========================================================

function Info($msg)  { Write-Host "  $msg" -ForegroundColor Gray }
function Ok($msg)    { Write-Host "  ✓ $msg" -ForegroundColor Green }
function Warn($msg)  { Write-Host "  ! $msg" -ForegroundColor Yellow }
function Fail($msg)  { Write-Host "  ✗ $msg" -ForegroundColor Red }
function Step($n, $t){ Write-Host ""; Write-Host "[$n] $t" -ForegroundColor Cyan }

Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "  qa-record 全自动安装" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

# ---------- 1. 确保 Node.js >= 18 ----------
Step 1 "检查 / 安装 Node.js"
$needInstallNode = $true
try {
    $v = node -v 2>$null
    if ($LASTEXITCODE -eq 0) {
        $major = [int]($v -replace 'v(\d+)\..*', '$1')
        if ($major -ge 18) { $needInstallNode = $false; Ok "已装 Node.js $v" }
        else { Warn "Node.js $v 太旧，将升级" }
    }
} catch {}

if ($needInstallNode) {
    Info "尝试用 winget 安装 Node.js LTS..."
    $wingetOk = $false
    try {
        winget --version 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { $wingetOk = $true }
    } catch {}

    if ($wingetOk) {
        winget install -e --id OpenJS.NodeJS.LTS --accept-source-agreements --accept-package-agreements --silent
        if ($LASTEXITCODE -ne 0) { Fail "winget 安装失败"; exit 1 }
        # 刷新本会话 PATH（winget 装完不刷新 PATH）
        $env:Path = [Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [Environment]::GetEnvironmentVariable("Path","User")
        $v = node -v
        Ok "已安装 Node.js $v"
    } else {
        Fail "系统没有 winget（Windows 10 早期版本可能没有）"
        Fail "请手动到 https://nodejs.org 下载 LTS 版本安装后重跑本脚本"
        exit 1
    }
}

# ---------- 2. 下载 tgz ----------
Step 2 "下载安装包"
$tgzUrl = "$RawBase/$TgzName"
$tmpTgz = Join-Path $env:TEMP $TgzName
try {
    Invoke-WebRequest -Uri $tgzUrl -OutFile $tmpTgz -UseBasicParsing
} catch {
    Fail "下载失败: $tgzUrl"
    Fail $_.Exception.Message
    exit 1
}
Ok "已下载 $TgzName"

# ---------- 3. 解压（自带依赖，无需 npm install） ----------
Step 3 "解压安装"
$installDir = Join-Path $env:USERPROFILE ".qa-record"
if (Test-Path $installDir) { Remove-Item -Recurse -Force $installDir }
New-Item -ItemType Directory -Path $installDir | Out-Null

tar -xzf $tmpTgz -C $installDir
if ($LASTEXITCODE -ne 0) { Fail "解压失败"; exit 1 }
Remove-Item $tmpTgz -Force

if (-not (Test-Path (Join-Path $installDir "node_modules\playwright-core"))) {
    Fail "解压后 playwright-core 缺失"
    exit 1
}
Ok "已安装（含依赖，无需 npm install）"

# ---------- 4. 注册命令 ----------
Step 4 "注册 qa-record 命令"
$binDir = Join-Path $env:USERPROFILE ".qa-record-bin"
if (-not (Test-Path $binDir)) { New-Item -ItemType Directory -Path $binDir | Out-Null }
$cmdPath = Join-Path $binDir "qa-record.cmd"
"@echo off`r`nnode `"$installDir\bin\qa-record.js`" %*" | Set-Content -Path $cmdPath -Encoding ASCII

$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($userPath -notlike "*$binDir*") {
    [Environment]::SetEnvironmentVariable("Path", "$userPath;$binDir", "User")
    $env:Path += ";$binDir"
    Ok "已加入 PATH"
} else {
    Ok "已在 PATH"
}

# ---------- 5. 选择环境并写入全局 config ----------
Step 5 "选择要测试的环境"
Write-Host ""
for ($i = 0; $i -lt $Environments.Count; $i++) {
    $e = $Environments[$i]
    Write-Host ("  {0}) {1,-12} {2}" -f ($i + 1), $e.Name, $e.Url) -ForegroundColor White
}
Write-Host ""

$selected = $null
if ($PresetEnv) {
    $selected = $Environments | Where-Object { $_.Name -ieq $PresetEnv } | Select-Object -First 1
    if ($selected) {
        Info "从 `$env:QA_ENV 选中: $($selected.Name)"
    } else {
        Warn "环境变量 QA_ENV=$PresetEnv 无效，可选: $($Environments.Name -join ', ')"
    }
}

if (-not $selected) {
    $canPrompt = $false
    try { $canPrompt = -not [Console]::IsInputRedirected } catch {}

    if ($canPrompt) {
        $choice = Read-Host "请输入序号 [1]"
        if ([string]::IsNullOrWhiteSpace($choice)) { $choice = '1' }
        $idx = 0
        [void][int]::TryParse($choice, [ref]$idx)
        if ($idx -lt 1 -or $idx -gt $Environments.Count) { Warn "输入无效，默认使用 1"; $idx = 1 }
        $selected = $Environments[$idx - 1]
    } else {
        Info "（管道模式无法交互，默认使用 1 - $($Environments[0].Name)）"
        Info "想选其他环境，先设环境变量后再跑：`$env:QA_ENV='production'; irm ... | iex"
        $selected = $Environments[0]
    }
}

$globalDir = Join-Path $env:USERPROFILE ".qa-record"
$configPath = Join-Path $globalDir "qa.config.js"
$configContent = @"
// qa-record 全局配置。install 时选的环境，可随时改。
module.exports = {
  baseURL: '$($selected.Url)',
  loginCheck: { urlIncludes: '$($selected.LoginPath)' },
};
"@
Set-Content -Path $configPath -Value $configContent -Encoding UTF8
Ok "已配置环境: $($selected.Name) ($($selected.Url))"
Info "如需切换：改 $configPath"

Write-Host ""
Write-Host "==========================================" -ForegroundColor Green
Write-Host "  ✅ 安装完成" -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green
Write-Host ""
Write-Host "使用（新开一个 PowerShell 窗口）：" -ForegroundColor Cyan
Write-Host "  qa-record <test-case-id>" -ForegroundColor White
Write-Host ""
