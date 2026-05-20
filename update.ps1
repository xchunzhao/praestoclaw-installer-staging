<#
.SYNOPSIS
    PraestoClaw STAGING one-click updater for Windows.

.DESCRIPTION
    Updates the staging build of PraestoClaw from the cogao/praestoclaw-installer
    ``staging`` branch. Targets the ``praestoclaw-staging`` / ``pc-staging``
    entry points; leaves any prod ``praestoclaw`` install alone.

    Run from PowerShell:
        irm https://raw.githubusercontent.com/cogao/praestoclaw-installer/staging/update.ps1 | iex
#>

$ErrorActionPreference = "Continue"

try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    [Console]::InputEncoding  = [System.Text.Encoding]::UTF8
    $OutputEncoding           = [System.Text.Encoding]::UTF8
    $env:PYTHONIOENCODING     = "utf-8"
    $env:PYTHONUTF8           = "1"
} catch {}

$MirrorBase = "https://raw.githubusercontent.com/cogao/praestoclaw-installer/staging"
$Package    = $env:PRAESTOCLAW_PACKAGE

function Write-Step { param([string]$m) Write-Host "" ; Write-Host ">> $m" -ForegroundColor Cyan }
function Write-Ok   { param([string]$m) Write-Host "   OK: $m" -ForegroundColor Green }
function Write-Warn { param([string]$m) Write-Host "   WARNING: $m" -ForegroundColor Yellow }
function Write-Fail { param([string]$m) Write-Host "   FAILED: $m" -ForegroundColor Red }

function Refresh-Path {
    $m = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
    $u = [System.Environment]::GetEnvironmentVariable("Path", "User")
    if (-not $m) { $m = "" }
    if (-not $u) { $u = "" }
    $env:Path = (@($m, $u) | Where-Object { $_ }) -join ";"
}

function Compare-Version {
    param([string]$Left, [string]$Right)
    try {
        $pyResult = & $pyCmd @pyPrefix -c "
from packaging.version import Version
import sys
l, r = Version(sys.argv[1]), Version(sys.argv[2])
print(-1 if l < r else (1 if l > r else 0))
" $Left $Right 2>$null
        if ($LASTEXITCODE -eq 0 -and $pyResult -match '^-?\d+$') {
            return [int]$pyResult
        }
    } catch {}
    $Left  = $Left  -replace '\.post\d{10,}', ''
    $Right = $Right -replace '\.post\d{10,}', ''
    $lParts = [regex]::Matches($Left,  '\d+') | ForEach-Object { [int]$_.Value }
    $rParts = [regex]::Matches($Right, '\d+') | ForEach-Object { [int]$_.Value }
    $max = [Math]::Max($lParts.Count, $rParts.Count)
    for ($i = 0; $i -lt $max; $i++) {
        $l = if ($i -lt $lParts.Count) { $lParts[$i] } else { 0 }
        $r = if ($i -lt $rParts.Count) { $rParts[$i] } else { 0 }
        if ($l -lt $r) { return -1 }
        if ($l -gt $r) { return  1 }
    }
    return 0
}

function Get-OurStagingExePaths {
    $paths = @()
    try {
        $scriptsDirs = @()
        $d1 = & $pyCmd @pyPrefix -c "import sysconfig; print(sysconfig.get_path('scripts'))" 2>$null
        $d2 = & $pyCmd @pyPrefix -c "import sysconfig; print(sysconfig.get_path('scripts','nt_user'))" 2>$null
        if ($d1) { $scriptsDirs += $d1 }
        if ($d2) { $scriptsDirs += $d2 }
        foreach ($d in $scriptsDirs | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique) {
            foreach ($name in @("praestoclaw-staging.exe", "pc-staging.exe")) {
                $p = Join-Path $d $name
                if (Test-Path $p) {
                    $paths += (Resolve-Path $p).Path.ToLower()
                }
            }
        }
    } catch {}
    return $paths
}

function Is-PraestoClawStagingProcess {
    param($Proc, [string[]]$OurPaths)

    if ($Proc.ExecutablePath) {
        $normExe = $Proc.ExecutablePath.ToLower()
        if ($OurPaths -contains $normExe) { return $true }
    }

    if ($Proc.Name -eq "praestoclaw-staging.exe") { return $true }
    if ($Proc.Name -eq "pc-staging.exe") { return $true }

    return $false
}

function Get-AncestorPids {
    $pids = @($PID)
    $current = $PID
    for ($i = 0; $i -lt 20; $i++) {
        try {
            $proc = Get-CimInstance Win32_Process -Filter "ProcessId = $current" -ErrorAction SilentlyContinue
            if (-not $proc -or -not $proc.ParentProcessId -or $proc.ParentProcessId -eq 0) { break }
            $parent = $proc.ParentProcessId
            if ($pids -contains $parent) { break }
            $pids += $parent
            $current = $parent
        } catch { break }
    }
    return $pids
}

function Stop-PraestoClawStagingProcesses {
    $excludePids = Get-AncestorPids
    $ourPaths = Get-OurStagingExePaths
    $allProcs = Get-CimInstance Win32_Process 2>$null

    $targets = @()
    foreach ($proc in $allProcs) {
        if ($excludePids -contains $proc.ProcessId) { continue }
        if (Is-PraestoClawStagingProcess $proc $ourPaths) {
            $targets += $proc
        }
    }

    if ($targets.Count -eq 0) {
        Write-Ok "No running PraestoClaw (staging) processes found."
        return
    }

    Write-Host "   Stopping $($targets.Count) PraestoClaw staging process(es) ..." -ForegroundColor Yellow
    foreach ($t in $targets) {
        try {
            Stop-Process -Id $t.ProcessId -Force -ErrorAction Stop
            Write-Ok "Stopped PID $($t.ProcessId) ($($t.Name))"
        } catch {
            Write-Warn "Could not stop PID $($t.ProcessId) ($($t.Name)): $_"
        }
    }
    Start-Sleep -Seconds 2
}

# --- Step 1: Verify praestoclaw-staging is installed ---
Write-Step "Checking current staging installation ..."
Refresh-Path

if (-not (Get-Command praestoclaw-staging -ErrorAction SilentlyContinue)) {
    Write-Fail "PraestoClaw (staging) is not installed."
    Write-Host ""
    Write-Host "  Run the staging installer first:" -ForegroundColor Yellow
    Write-Host "    irm https://raw.githubusercontent.com/cogao/praestoclaw-installer/staging/install.ps1 | iex" -ForegroundColor Yellow
    Write-Host ""
    exit 1
}

$currentVersionRaw = & praestoclaw-staging version 2>&1
Write-Ok "Current: $currentVersionRaw"

$currentVersion = ""
if ($currentVersionRaw -match '(\d+\.\d+[^\s]*)') {
    $currentVersion = $Matches[1]
}

$pyCmd = $null
$pyPrefix = @()
if (Get-Command py -ErrorAction SilentlyContinue) {
    try {
        $ver = & py -3 --version 2>&1
        if ($LASTEXITCODE -eq 0 -and [string]$ver -match "Python") {
            $pyCmd = "py"
            $pyPrefix = @("-3")
        }
    } catch {}
}
if (-not $pyCmd) {
    foreach ($c in @("python3", "python")) {
        if (Get-Command $c -ErrorAction SilentlyContinue) {
            try {
                $ver = & $c --version 2>&1
                if ($LASTEXITCODE -eq 0 -and [string]$ver -match "Python \d+\.\d+") {
                    $pyCmd = $c
                    break
                }
            } catch {}
        }
    }
}
if (-not $pyCmd) {
    Write-Fail "Python not found on PATH."
    exit 1
}
Write-Ok "Python: $( & $pyCmd @pyPrefix --version 2>&1 )"

# --- Step 2: Resolve latest staging version and compare ---
$latest = $null
if (-not $Package) {
    Write-Step "Checking for staging updates ..."
    try {
        $bust = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $latest = (Invoke-WebRequest -Uri "$MirrorBase/latest.txt?t=$bust" -UseBasicParsing).Content.Trim()
        if ($latest -notmatch '^\d+\.\d+(\.\d+)?') {
            throw "staging latest.txt did not contain a valid version: '$latest'"
        }
        Write-Ok "Latest staging version: $latest"
    } catch {
        Write-Fail "Could not resolve latest staging version from $MirrorBase/latest.txt"
        Write-Host "   $_" -ForegroundColor Red
        exit 1
    }

    if ($currentVersion -and $latest) {
        $cmp = Compare-Version $currentVersion $latest
        if ($cmp -ge 0) {
            Write-Host ""
            Write-Host "   Already up to date! (current: v$currentVersion, latest: v$latest)" -ForegroundColor Green
            Write-Host ""
            exit 0
        }
        Write-Host "   Update available: v$currentVersion -> v$latest" -ForegroundColor Cyan
    }

    $Package = "$MirrorBase/dist/praestoclaw-$latest-py3-none-any.whl"
}

$DepsPackage = $env:PRAESTOCLAW_GATEWAY_PROTOCOL_PACKAGE
if (-not $DepsPackage) {
    if (-not $latest) {
        try {
            $bust = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            $latest = (Invoke-WebRequest -Uri "$MirrorBase/latest.txt?t=$bust" -UseBasicParsing).Content.Trim()
        } catch {}
    }
    if ($latest -match '^\d+\.\d+(\.\d+)?') {
        $DepsPackage = "$MirrorBase/dist/agent_gateway_protocol-$latest-py3-none-any.whl"
    } else {
        Write-Warn "Could not resolve agent_gateway_protocol wheel URL."
    }
}
$InstallTargets = @()
if ($DepsPackage) { $InstallTargets += $DepsPackage }
$InstallTargets += $Package

# --- Step 3: Stop running staging processes ---
Write-Step "Stopping running PraestoClaw (staging) processes ..."
Stop-PraestoClawStagingProcesses

# --- Step 4: Upgrade via pip ---
Write-Step "Upgrading to v$latest ..."

$spin = '|','/','—','\'
function Run-PipSilent([string[]]$PipArgs) {
    $errFile = "$env:TEMP\_pcs_pip_err.txt"
    $outFile = "$env:TEMP\_pcs_pip_out.txt"
    $allArgs = @($pyPrefix) + $PipArgs
    $argStr = ($allArgs | ForEach-Object { if ($_ -match '\s') { "`"$_`"" } else { $_ } }) -join ' '
    $p = Start-Process -FilePath $pyCmd -ArgumentList $argStr -NoNewWindow -PassThru `
        -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    $i = 0
    while (!$p.HasExited) { Write-Host "`r   $($spin[$i++%4]) Installing..." -NoNewline -ForegroundColor Cyan; Start-Sleep -Milliseconds 120 }
    Write-Host "`r                        `r" -NoNewline
    $p.WaitForExit()
    $code = $p.ExitCode
    $errText = ""
    if ($code -ne 0) { $errText = Get-Content $errFile -Raw -ErrorAction SilentlyContinue }
    Remove-Item $errFile, $outFile -ErrorAction SilentlyContinue
    return @{ Code = $code; Err = $errText }
}

$r = Run-PipSilent (@("-m","pip","install","--upgrade","--force-reinstall") + $InstallTargets)
if ($r.Code -ne 0) {
    Write-Warn "Standard install failed. Retrying with --user ..."
    $r = Run-PipSilent (@("-m","pip","install","--upgrade","--force-reinstall","--user") + $InstallTargets)
    if ($r.Code -ne 0) {
        Write-Fail "pip install failed:"
        if ($r.Err) { Write-Host $r.Err -ForegroundColor Red }
        exit 1
    }
}
Write-Ok "Upgrade complete."

Refresh-Path
if (Get-Command praestoclaw-staging -ErrorAction SilentlyContinue) {
    Write-Ok "$( & praestoclaw-staging version 2>&1 )"
} else {
    Write-Warn "praestoclaw-staging not found on PATH after upgrade."
}

# --- Step 5: Post-update startup ---
Write-Host ""
Write-Host "============================================" -ForegroundColor Green
Write-Host "  PraestoClaw (staging) updated to v$latest!" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Green
Write-Host ""

if (Get-Command praestoclaw-staging -ErrorAction SilentlyContinue) {
    Write-Step "Running post-update config ..."
    & praestoclaw-staging init --quick 2>&1 | ForEach-Object { Write-Host "   $_" }

    Write-Step "Starting PraestoClaw (staging) ..."
    Write-Host "   Press Ctrl+C in this window to stop the server." -ForegroundColor DarkGray
    Write-Host ""
    & praestoclaw-staging s
} else {
    Write-Host "  Restart your terminal, then run:" -ForegroundColor Cyan
    Write-Host "    praestoclaw-staging s" -ForegroundColor White
    Write-Host ""
}
