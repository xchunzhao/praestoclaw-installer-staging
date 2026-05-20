<#
.SYNOPSIS
    PraestoClaw STAGING one-click installer for Windows.

.DESCRIPTION
    Installs the staging build of PraestoClaw from the cogao/praestoclaw-installer
    ``staging`` branch. Exposes the ``praestoclaw-staging`` / ``pc-staging``
    entry points, which write to ``~/.praestoclaw-staging/`` and point at
    the staging gateway. Coexists with a prod install on the same machine.

    Run from PowerShell:
        irm https://raw.githubusercontent.com/cogao/praestoclaw-installer/staging/install.ps1 | iex
#>

$ErrorActionPreference = "Continue"

try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    [Console]::InputEncoding  = [System.Text.Encoding]::UTF8
    $OutputEncoding           = [System.Text.Encoding]::UTF8
    $env:PYTHONIOENCODING     = "utf-8"
    $env:PYTHONUTF8           = "1"
} catch {}

$MinMajor  = 3
$MinMinor  = 11
$PyVersion = "3.13"
$PyArch    = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" } else { "amd64" }
$PyUrl     = "https://www.python.org/ftp/python/$PyVersion.0/python-$PyVersion.0-$PyArch.exe"
$MirrorBase = "https://raw.githubusercontent.com/cogao/praestoclaw-installer/staging"
$Package    = $env:PRAESTOCLAW_PACKAGE

function Write-Step { param([string]$m) Write-Host "" ; Write-Host ">> $m" -ForegroundColor Cyan }
function Write-Ok   { param([string]$m) Write-Host "   OK: $m" -ForegroundColor Green }
function Write-Warn { param([string]$m) Write-Host "   WARNING: $m" -ForegroundColor Yellow }
function Write-Fail { param([string]$m) Write-Host "   FAILED: $m" -ForegroundColor Red }

function Get-EnvPath {
    $m = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
    $u = [System.Environment]::GetEnvironmentVariable("Path", "User")
    if (-not $m) { $m = "" }
    if (-not $u) { $u = "" }
    return (@($m, $u) | Where-Object { $_ }) -join ";"
}

function Refresh-Path {
    $env:Path = Get-EnvPath
}

function Add-ToUserPath {
    param([string]$Dir)
    if (-not $Dir -or -not (Test-Path $Dir)) { return }
    $current = [System.Environment]::GetEnvironmentVariable("Path", "User")
    if (-not $current) { $current = "" }
    $parts = $current -split ";"
    if ($parts -contains $Dir) { return }
    $newPath = ($parts + $Dir | Where-Object { $_ }) -join ";"
    [System.Environment]::SetEnvironmentVariable("Path", $newPath, "User")
    if ($env:Path -notlike "*$Dir*") { $env:Path = "$env:Path;$Dir" }
    Write-Ok "Added to PATH: $Dir"
}

function Test-IsStoreStub {
    param([string]$Cmd)
    try {
        $out = & $Cmd --version 2>&1
        return ($LASTEXITCODE -eq 9009 -or [string]$out -notmatch "Python")
    } catch { return $true }
}

function Find-Python {
    $candidates = @("python3", "python", "py")
    foreach ($c in $candidates) {
        if (-not (Get-Command $c -ErrorAction SilentlyContinue)) { continue }
        if (Test-IsStoreStub $c) { continue }
        try {
            $ver = & $c --version 2>&1
            if ([string]$ver -match "Python (\d+)\.(\d+)") {
                $maj = [int]$Matches[1]
                $min = [int]$Matches[2]
                if ($maj -gt $MinMajor -or ($maj -eq $MinMajor -and $min -ge $MinMinor)) {
                    return @{ Cmd = $c; Prefix = @() }
                }
            }
        } catch {}
    }
    if (Get-Command py -ErrorAction SilentlyContinue) {
        $flag = "-$($MinMajor).$($MinMinor)"
        try {
            $ver = & py $flag --version 2>&1
            if ($LASTEXITCODE -eq 0 -and [string]$ver -match "Python") {
                return @{ Cmd = "py"; Prefix = @($flag) }
            }
        } catch {}
    }
    return $null
}

# --- Step 1: Locate or install Python ---
Write-Step "Checking for Python $($MinMajor).$($MinMinor)+ ..."

$pyInfo = Find-Python

if (-not $pyInfo) {
    Write-Warn "Python $($MinMajor).$($MinMinor)+ not found. Attempting automatic install..."

    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Step "Installing Python $PyVersion via winget ..."
        winget install --id "Python.Python.$PyVersion" `
            --accept-source-agreements `
            --accept-package-agreements `
            --scope user `
            --silent 2>&1 | ForEach-Object { Write-Host "   $_" -ForegroundColor DarkGray }
        Refresh-Path
        $pyInfo = Find-Python
        if ($pyInfo) { Write-Ok "Python installed via winget." }
    }

    if (-not $pyInfo) {
        Write-Step "Downloading Python $PyVersion from python.org ..."
        $installer = Join-Path $env:TEMP "python-installer.exe"
        try {
            [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri $PyUrl -OutFile $installer -UseBasicParsing -ErrorAction Stop
            Write-Step "Running Python installer silently (user scope) ..."
            $startArgs = @{
                FilePath     = $installer
                ArgumentList = "/quiet", "InstallAllUsers=0", "PrependPath=1", "Include_launcher=1"
                Wait         = $true
                PassThru     = $true
            }
            $null = Start-Process @startArgs
            Remove-Item $installer -ErrorAction SilentlyContinue
            Refresh-Path
            $pyInfo = Find-Python
            if ($pyInfo) { Write-Ok "Python installed from python.org." }
        } catch {
            Write-Warn "Direct download failed: $($_.Exception.Message)"
        }
    }

    if (-not $pyInfo) {
        Write-Fail "Could not automatically install Python."
        Write-Host ""
        Write-Host "  Please install Python $($MinMajor).$($MinMinor)+ manually:" -ForegroundColor Yellow
        Write-Host "    https://www.python.org/downloads/" -ForegroundColor Yellow
        Write-Host ""
        exit 1
    }
}

$pyCmd    = $pyInfo.Cmd
$pyPrefix = $pyInfo.Prefix
$verOut   = & $pyCmd @pyPrefix --version 2>&1
Write-Ok "Found $verOut"

# --- Step 2: Ensure pip ---
Write-Step "Ensuring pip is available ..."

$pipCheck = & $pyCmd @pyPrefix -m pip --version 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Warn "pip not found. Bootstrapping via ensurepip ..."
    & $pyCmd @pyPrefix -m ensurepip --upgrade 2>&1 | Out-Null

    $pipCheck = & $pyCmd @pyPrefix -m pip --version 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Warn "ensurepip failed. Downloading get-pip.py ..."
        $getPip = Join-Path $env:TEMP "get-pip.py"
        Invoke-WebRequest -Uri "https://bootstrap.pypa.io/get-pip.py" -OutFile $getPip -UseBasicParsing
        & $pyCmd @pyPrefix $getPip 2>&1 | Out-Null
        Remove-Item $getPip -ErrorAction SilentlyContinue
    }
}

& $pyCmd @pyPrefix -m pip install --upgrade pip --quiet 2>&1 | Out-Null
Write-Ok "$( & $pyCmd @pyPrefix -m pip --version 2>&1 )"

# --- Step 3: Install PraestoClaw staging wheel ---
if (-not $Package) {
    Write-Step "Resolving latest PraestoClaw staging version ..."
    try {
        $bust = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $ver  = (Invoke-WebRequest -Uri "$MirrorBase/latest.txt?t=$bust" -UseBasicParsing).Content.Trim()
        if ($ver -notmatch '^\d+\.\d+(\.\d+)?') {
            throw "staging latest.txt did not contain a valid version: '$ver'"
        }
        $Package = "$MirrorBase/dist/praestoclaw-$ver-py3-none-any.whl"
        Write-Ok "Latest staging version: $ver"
    } catch {
        Write-Fail "Could not resolve latest staging version from $MirrorBase/latest.txt"
        Write-Host "   $_" -ForegroundColor Red
        exit 1
    }
}

$DepsPackage = $env:PRAESTOCLAW_GATEWAY_PROTOCOL_PACKAGE
if (-not $DepsPackage) {
    try {
        $bust = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $ver  = (Invoke-WebRequest -Uri "$MirrorBase/latest.txt?t=$bust" -UseBasicParsing).Content.Trim()
        if ($ver -match '^\d+\.\d+(\.\d+)?') {
            $DepsPackage = "$MirrorBase/dist/agent_gateway_protocol-$ver-py3-none-any.whl"
        }
    } catch {
        Write-Warn "Could not resolve agent_gateway_protocol wheel URL."
    }
}
$InstallTargets = @()
if ($DepsPackage) { $InstallTargets += $DepsPackage }
$InstallTargets += $Package

Write-Step "Installing / upgrading from $Package ..."

$out = & $pyCmd @pyPrefix -m pip install --upgrade --force-reinstall @InstallTargets 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Warn "Standard install failed. Retrying with --user ..."
    $out = & $pyCmd @pyPrefix -m pip install --upgrade --force-reinstall --user @InstallTargets 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "pip install failed:"
        Write-Host ($out | Out-String) -ForegroundColor Red
        exit 1
    }
}
Write-Ok "$Package installed."

# --- Step 3b: uv ---
if (Get-Command uvx -ErrorAction SilentlyContinue) {
    Write-Ok "uv already installed: $( & uv --version 2>&1 )"
} else {
    Write-Step "Installing uv (Python package runner) ..."
    $uvOut = & $pyCmd @pyPrefix -m pip install uv --quiet 2>&1
    if ($LASTEXITCODE -ne 0) {
        $uvOut = & $pyCmd @pyPrefix -m pip install uv --quiet --user 2>&1
    }
    Refresh-Path
    if (Get-Command uvx -ErrorAction SilentlyContinue) {
        Write-Ok "uv installed: $( & uv --version 2>&1 )"
    } else {
        Write-Warn "uv installed but uvx not on PATH (non-critical)."
    }
}

# --- Step 3c: Agency CLI ---
if (Get-Command agency -ErrorAction SilentlyContinue) {
    try { Write-Ok "agency already installed: $( & agency --version 2>&1 )" } catch { Write-Ok "agency already installed." }
} else {
    Write-Step "Installing Agency CLI ..."
    try {
        Invoke-Expression 'iex "& { $(irm https://aka.ms/InstallTool.ps1) } agency"'
        Refresh-Path
        if (Get-Command agency -ErrorAction SilentlyContinue) {
            try { Write-Ok "agency installed: $( & agency --version 2>&1 )" } catch { Write-Ok "agency installed." }
        } else {
            Write-Warn "Agency installer ran but 'agency' not found on PATH yet (restart terminal)."
        }
    } catch {
        Write-Warn "Failed to install Agency CLI: $($_.Exception.Message)"
    }
}

# --- Step 4: Ensure praestoclaw-staging on PATH ---
Write-Step "Verifying praestoclaw-staging CLI ..."

Refresh-Path

if (-not (Get-Command praestoclaw-staging -ErrorAction SilentlyContinue)) {
    $scriptsDir  = & $pyCmd @pyPrefix -c "import sysconfig; print(sysconfig.get_path('scripts'))" 2>&1
    $userScripts = & $pyCmd @pyPrefix -c "import sysconfig; print(sysconfig.get_path('scripts', 'nt_user'))" 2>&1

    foreach ($d in @($scriptsDir, $userScripts) | Select-Object -Unique) {
        if ($d) { Add-ToUserPath $d }
    }
    Refresh-Path
}

if (Get-Command praestoclaw-staging -ErrorAction SilentlyContinue) {
    Write-Ok "$( & praestoclaw-staging version 2>&1 )"
} else {
    Write-Warn "praestoclaw-staging not found on PATH yet."
    Write-Host ""
    Write-Host "  Restart your terminal, then run: praestoclaw-staging version" -ForegroundColor Yellow
    Write-Host ""
}

# --- Step 4b: Hibernation delay agent on Dev Boxes ---
if ((Get-Command praestoclaw-staging -ErrorAction SilentlyContinue) -and ($env:COMPUTERNAME -like "CPC-*")) {
    Write-Step "Initializing Dev Box Hibernation Delay Agent ..."
    & praestoclaw-staging hibernation-delay-agent
    if ($LASTEXITCODE -ne 0) {
        Write-Warn "Hibernation Delay Agent setup did not complete."
    }
}

# --- Done ---
Write-Host ""
Write-Host "============================================" -ForegroundColor Green
Write-Host "  PraestoClaw STAGING installed successfully!" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Green
Write-Host ""

$skipPost = $env:PRAESTOCLAW_SKIP_POST_INSTALL -eq '1'

if ((Get-Command praestoclaw-staging -ErrorAction SilentlyContinue) -and (-not $skipPost)) {

    Write-Step "Creating default staging config ..."
    & praestoclaw-staging init --quick 2>&1 | ForEach-Object { Write-Host "   $_" }

    Write-Step "Installing PraestoClaw (staging) into Microsoft Teams ..."
    Write-Host "   You'll be asked to sign in with your Microsoft 365 work account." -ForegroundColor DarkGray
    if ($env:PRAESTOCLAW_TEAMS_PACKAGE -and -not (Test-Path -LiteralPath $env:PRAESTOCLAW_TEAMS_PACKAGE)) {
        Write-Host "   Ignoring stale `$env:PRAESTOCLAW_TEAMS_PACKAGE=$($env:PRAESTOCLAW_TEAMS_PACKAGE) (file missing)" -ForegroundColor DarkGray
        Remove-Item Env:PRAESTOCLAW_TEAMS_PACKAGE -ErrorAction SilentlyContinue
    }
    & praestoclaw-staging teams install --force
    if ($LASTEXITCODE -ne 0) {
        Write-Warn "Teams sideload did not complete. Retry: praestoclaw-staging teams install"
    }

    Write-Step "Starting PraestoClaw (staging) ..."
    Write-Host "   Press Ctrl+C in this window to stop the server." -ForegroundColor DarkGray
    Write-Host ""
    & praestoclaw-staging s

} elseif (Get-Command praestoclaw-staging -ErrorAction SilentlyContinue) {
    Write-Host "  Skipped post-install (PRAESTOCLAW_SKIP_POST_INSTALL=1)." -ForegroundColor DarkGray
    Write-Host "  To finish setup manually:" -ForegroundColor Cyan
    Write-Host "    praestoclaw-staging init --quick" -ForegroundColor White
    Write-Host "    praestoclaw-staging teams install" -ForegroundColor White
    Write-Host "    praestoclaw-staging s" -ForegroundColor White
    Write-Host ""
} else {
    Write-Host "  Restart your terminal, then run:" -ForegroundColor Cyan
    Write-Host "    praestoclaw-staging s" -ForegroundColor White
    Write-Host ""
}
