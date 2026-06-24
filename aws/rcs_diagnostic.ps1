<#
.SYNOPSIS
    RCS Host Diagnostic — resolves GitLab #112 (SEP state) + #114 (boto3 in Deadline Python)
.DESCRIPTION
    Run this on the RCS host (Windows) in PowerShell.
    It checks Deadline Python version, boto3 availability, and Spot Event Plugin state.
    Results are printed to console and saved to ~/rcs-diagnostic-results.txt
.NOTES
    GitLab issues: #112 (E4.3), #114 (E11.1)
#>

$ErrorActionPreference = "Continue"
$results = @()

function Log($msg) {
    Write-Host $msg
    $results += $msg
}

Log "============================================"
Log "RCS Host Diagnostic - $(Get-Date)"
Log "============================================"
Log ""

# ── 1. Deadline Installation ──────────────────────────
Log "--- 1. Deadline Installation ---"

$deadlineBin = "${env:ProgramFiles}\Thinkbox\Deadline10\bin"
$deadlineBinAlt = "${env:ProgramFiles(x86)}\Thinkbox\Deadline10\bin"

if (Test-Path $deadlineBin) {
    Log "Deadline bin: $deadlineBin"
} elseif (Test-Path $deadlineBinAlt) {
    Log "Deadline bin: $deadlineBinAlt"
    $deadlineBin = $deadlineBinAlt
} else {
    Log "WARNING: Deadline bin not found at standard paths"
    Log "Searching registry..."
    $reg = Get-ItemProperty "HKLM:\SOFTWARE\Thinkbox\Deadline\10" -ErrorAction SilentlyContinue
    if ($reg) {
        $deadlineBin = Join-Path $reg.InstallPath "bin"
        Log "Found via registry: $deadlineBin"
    }
}

$deadlineCmd = Join-Path $deadlineBin "deadlinecommand.exe"
if (Test-Path $deadlineCmd) {
    Log "deadlinecommand.exe: FOUND"
} else {
    Log "ERROR: deadlinecommand.exe not found. Aborting."
    return
}

# Deadline version
$dlVersion = & $deadlineCmd -version 2>&1 | Select-Object -First 1
Log "Deadline version: $dlVersion"
$repoPath = & $deadlineCmd -GetRepositoryDir 2>&1 | Select-Object -First 1
Log "Repository root: $repoPath"
Log ""

# ── 2. Deadline Python ─────────────────────────────────
Log "--- 2. Deadline Python Environment ---"

$dlPython = Join-Path $deadlineBin "python"
$dlPythonExe = Join-Path $dlPython "python.exe"
$dlPython3Exe = Join-Path $dlPython "python3.exe"

if (Test-Path $dlPythonExe) {
    Log "Deadline Python: $dlPythonExe"
} elseif (Test-Path $dlPython3Exe) {
    $dlPythonExe = $dlPython3Exe
    Log "Deadline Python: $dlPythonExe"
} else {
    Log "Deadline bundled Python not found at $dlPython"
    Log "Trying deadlinecommand -python..."
    # Try running Python via deadlinecommand
    $pyTest = & $deadlineCmd -python "import sys; print(sys.version); print(sys.executable)" 2>&1
    Log "Python via deadlinecommand: $pyTest"
}

if (Test-Path $dlPythonExe) {
    # Python version
    $pyVersion = & $dlPythonExe --version 2>&1
    Log "Python version: $pyVersion"

    # Python path / site-packages
    $pyPath = & $dlPythonExe -c "import sys; print('\n'.join(sys.path))" 2>&1
    Log "sys.path:"
    foreach ($p in $pyPath) { Log "  $p" }
}
Log ""

# ── 3. boto3 Availability (CRITICAL — #114) ───────────
Log "--- 3. boto3 Availability (#114) ---"

if (Test-Path $dlPythonExe) {
    $boto3Test = & $dlPythonExe -c @"
import sys
print(f'Python: {sys.version}')
try:
    import boto3
    print(f'boto3: AVAILABLE (v{boto3.__version__})')
except ImportError as e:
    print(f'boto3: NOT AVAILABLE ({e})')

try:
    import botocore
    print(f'botocore: AVAILABLE (v{botocore.__version__})')
except ImportError as e:
    print(f'botocore: NOT AVAILABLE ({e})')

# Check pip
try:
    import pip
    print(f'pip: AVAILABLE (v{pip.__version__})')
except ImportError:
    print('pip: NOT AVAILABLE')
"@ 2>&1

    foreach ($line in $boto3Test) { Log "  $line" }

    # If boto3 missing, check if pip can install it
    if ($boto3Test -match "NOT AVAILABLE") {
        Log ""
        Log "  boto3 is missing. Checking if we can install it..."
        $pipCheck = & $dlPythonExe -m pip --version 2>&1
        if ($LASTEXITCODE -eq 0) {
            Log "  pip is available: $pipCheck"
            Log "  Install with: $dlPythonExe -m pip install boto3"
        } else {
            Log "  pip NOT available via -m pip"
            Log "  Fallback needed: system Python via subprocess, or AWS CLI via subprocess"
        }
    }
}
Log ""

# ── 4. AWS CLI ─────────────────────────────────────────
Log "--- 4. AWS CLI (fallback for boto3) ---"

$awsCli = Get-Command aws -ErrorAction SilentlyContinue
if ($awsCli) {
    $awsVersion = aws --version 2>&1
    Log "AWS CLI: $awsVersion"
    Log "AWS CLI path: $($awsCli.Source)"
} else {
    Log "AWS CLI: NOT on PATH"
    # Check common locations
    $awsPaths = @(
        "${env:ProgramFiles}\Amazon\AWSCLIV2\aws.exe",
        "${env:ProgramFiles(x86)}\Amazon\AWSCLI\aws.exe"
    )
    foreach ($p in $awsPaths) {
        if (Test-Path $p) {
            Log "AWS CLI found at: $p"
        }
    }
}
Log ""

# ── 5. Spot Event Plugin State (#112) ─────────────────
Log "--- 5. Spot Event Plugin State (#112) ---"

# Check plugin directories
$pluginDirs = @(
    Join-Path $repoPath "plugins",
    Join-Path $repoPath "custom\plugins",
    "${env:ProgramFiles}\Thinkbox\Deadline10\plugins"
)

foreach ($dir in $pluginDirs) {
    if (Test-Path $dir) {
        Log "Plugin dir exists: $dir"
        $spotPlugins = Get-ChildItem $dir -Directory -Filter "*Spot*" -ErrorAction SilentlyContinue
        if ($spotPlugins) {
            foreach ($sp in $spotPlugins) {
                Log "  Found: $($sp.Name)"
                # List key files
                $files = Get-ChildItem $sp.FullName -ErrorAction SilentlyContinue
                foreach ($f in $files) {
                    Log "    $($f.Name)"
                }
            }
        } else {
            Log "  No Spot plugins found in this dir"
        }
    } else {
        Log "Plugin dir not found: $dir"
    }
}

# Check Deadline's configured plugins via deadlinecommand
Log ""
Log "Checking Deadline plugin configuration..."
$dlPlugins = & $deadlineCmd -GetPluginList 2>&1
$spotInList = $dlPlugins | Where-Object { $_ -match "Spot|AwsSpot|EventPlugin" }
if ($spotInList) {
    Log "Spot-related plugins in Deadline:"
    foreach ($p in $spotInList) { Log "  $p" }
} else {
    Log "No Spot plugins found in Deadline plugin list"
}

# Check event plugins specifically
$eventDir = Join-Path $repoPath "events"
if (Test-Path $eventDir) {
    Log ""
    Log "Event plugins dir: $eventDir"
    $events = Get-ChildItem $eventDir -Directory -ErrorAction SilentlyContinue
    if ($events) {
        foreach ($e in $events) { Log "  $($e.Name)" }
    } else {
        Log "  (empty)"
    }
} else {
    Log "Event plugins dir not found: $eventDir"
}
Log ""

# ── 6. IAM / AWS Credentials ───────────────────────────
Log "--- 6. AWS Credentials ---"

# Check environment variables
$awsKeys = @("AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN", "AWS_DEFAULT_REGION")
foreach ($key in $awsKeys) {
    $val = [Environment]::GetEnvironmentVariable($key)
    if ($val) {
        Log "$key = $($val.Substring(0, [Math]::Min(8, $val.Length)))... (set)"
    } else {
        Log "$key = (not set)"
    }
}

# Check if deadlinecommand can see AWS config
$awsRegion = & $deadlineCmd -GetSetting AWSRegion 2>&1 | Select-Object -First 1
Log "Deadline AWSRegion setting: $awsRegion"
Log ""

# ── 7. Network Connectivity ────────────────────────────
Log "--- 7. Network Connectivity ---"

$endpoints = @(
    @{Name="AWS Pricing (us-east-1)"; Host="pricing.us-east-1.amazonaws.com"; Port=443},
    @{Name="AWS EC2 (us-west-2)"; Host="ec2.us-west-2.amazonaws.com"; Port=443},
    @{Name="AWS Athena (us-west-2)"; Host="athena.us-west-2.amazonaws.com"; Port=443},
    @{Name="GitLab"; Host="gitlab.someofitlater.com"; Port=443},
    @{Name="ZeroTier"; Host="my.zerotier.com"; Port=443}
)

foreach ($ep in $endpoints) {
    $tcp = Test-NetConnection -ComputerName $ep.Host -Port $ep.Port -WarningAction SilentlyContinue
    if ($tcp.TcpTestSucceeded) {
        Log "  $($ep.Name): REACHABLE"
    } else {
        Log "  $($ep.Name): UNREACHABLE"
    }
}
Log ""

# ── 8. Summary ─────────────────────────────────────────
Log "============================================"
Log "DIAGNOSTIC COMPLETE - $(Get-Date)"
Log "============================================"
Log ""
Log "Results saved to: $HOME\rcs-diagnostic-results.txt"
Log "Paste results into GitLab #112 and #114"

# Save results
$results | Out-File -FilePath "$HOME\rcs-diagnostic-results.txt" -Encoding UTF8
