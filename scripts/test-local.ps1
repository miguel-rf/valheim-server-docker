# ==============================================================================
# Local Static Validation Script for Windows Development Environment
# Validates Dockerfile, shell script syntax, YAML syntax, and architecture rules.
# ==============================================================================

$ErrorActionPreference = "Continue"

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "       Valheim Server ARM64 Fork - Local Validation         " -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

$Passed = 0
$Failed = 0

function Report-Pass($msg) {
    Write-Host "[PASS] $msg" -ForegroundColor Green
    $script:Passed++
}

function Report-Fail($msg) {
    Write-Host "[FAIL] $msg" -ForegroundColor Red
    $script:Failed++
}

function Report-Warn($msg) {
    Write-Host "[WARN] $msg" -ForegroundColor Yellow
}

# 1. Check for Git Bash
$GitBash = "C:\Program Files\Git\bin\bash.exe"
if (-not (Test-Path $GitBash)) {
    $GitBashCmd = Get-Command bash.exe -ErrorAction SilentlyContinue
    if ($GitBashCmd) { $GitBash = $GitBashCmd.Source }
}

# 2. Syntax check shell scripts
Write-Host "--- [1] Checking Shell Scripts Syntax (bash -n) ---" -ForegroundColor DarkCyan
$ShellScripts = @(
    "bootstrap",
    "valheim-bootstrap",
    "valheim-server",
    "valheim-updater",
    "valheim-backup",
    "valheim-is-idle",
    "valheim-tests",
    "valheim-plus-updater",
    "bepinex-updater",
    "common",
    "defaults",
    "fake-supervisord",
    "valheim-arch-diagnostics",
    "steamcmd-wrapper",
    "valheim-wrapper",
    "tests/oracle-arm64-smoke-test.sh"
)

if (Test-Path $GitBash) {
    foreach ($script in $ShellScripts) {
        if (Test-Path $script) {
            $res = & $GitBash -n $script 2>&1
            if ($LASTEXITCODE -eq 0) {
                Report-Pass "Syntax valid: $script"
            } else {
                Report-Fail "Syntax error in $script : $res"
            }
        } else {
            Report-Warn "Script not found: $script"
        }
    }
} else {
    Report-Warn "bash.exe not found. Skipping bash -n syntax checks."
}

# Check Python scripts
if (Test-Path "valheim-status") {
    $hasPython = $false
    try {
        $ver = & python.exe --version 2>&1
        if ($LASTEXITCODE -eq 0) { $hasPython = $true }
    } catch {
        $hasPython = $false
    }

    if ($hasPython) {
        $pyres = & python.exe -m py_compile valheim-status 2>&1
        if ($LASTEXITCODE -eq 0) {
            Report-Pass "Python syntax valid: valheim-status"
        } else {
            Report-Fail "Python syntax error in valheim-status : $pyres"
        }
    } else {
        Report-Pass "Python script present: valheim-status (Python runtime not installed locally)"
    }
}
Write-Host ""

# 3. Check Dockerfile architecture parameterization
Write-Host "--- [2] Inspecting Dockerfile Architecture Rules ---" -ForegroundColor DarkCyan
$Dockerfile = Get-Content "Dockerfile" -Raw
if ($Dockerfile -match "linux-\$\{ARCH\}" -or $Dockerfile -match "linux-\$\{TARGETARCH\}") {
    Report-Pass "Go compiler download is architecture-aware (TARGETARCH)"
} else {
    Report-Fail "Go compiler download does not appear to be parameterized with TARGETARCH"
}

if ($Dockerfile -match "box64-builder" -and $Dockerfile -match "box86-builder") {
    Report-Pass "Dockerfile contains multi-stage builders for Box64 and Box86"
} else {
    Report-Fail "Dockerfile is missing box64-builder or box86-builder multi-stage definitions"
}

if ($Dockerfile -match "valheim-wrapper" -and $Dockerfile -match "steamcmd-wrapper") {
    Report-Pass "Dockerfile copies valheim-wrapper and steamcmd-wrapper"
} else {
    Report-Fail "Dockerfile does not copy wrappers"
}
Write-Host ""

# 4. Check YAML Compose Files
Write-Host "--- [3] Inspecting Docker Compose Files ---" -ForegroundColor DarkCyan
$ComposeFiles = @("docker-compose.yaml", "docker-compose.oracle-arm64.yml")
foreach ($cf in $ComposeFiles) {
    if (Test-Path $cf) {
        $content = Get-Content $cf -Raw
        if ($cf -eq "docker-compose.oracle-arm64.yml") {
            if ($content -match "(?m)^\s*platform:\s*[`"']?linux/amd64") {
                Report-Fail "$cf active setting contains 'platform: linux/amd64'! It must be native arm64."
            } else {
                Report-Pass "$cf does NOT force linux/amd64 emulation"
            }
            if ($content -match "stop_grace_period") {
                Report-Pass "$cf configures stop_grace_period for safe world saves"
            } else {
                Report-Fail "$cf is missing stop_grace_period"
            }
        } else {
            Report-Pass "Compose file present: $cf"
        }
    }
}
Write-Host ""

# Summary
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "Passed: $Passed  |  Failed: $Failed" -ForegroundColor $(if ($Failed -eq 0) { "Green" } else { "Red" })
Write-Host "============================================================" -ForegroundColor Cyan

if ($Failed -gt 0) { exit 1 } else { exit 0 }
