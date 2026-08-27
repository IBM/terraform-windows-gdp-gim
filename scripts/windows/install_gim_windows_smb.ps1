#!/usr/bin/env bash
#
# Copyright (c) IBM Corp. 2026
# SPDX-License-Identifier: Apache-2.0
#

param(
  [Parameter(Mandatory=$true)][string]$HostName,
  [Parameter(Mandatory=$true)][string]$Username,
  [Parameter(Mandatory=$true)][string]$Password,
  [Parameter(Mandatory=$true)][string]$GimServerHost,
  [int]$GimServerPort = 8446,
  [int]$ListenerPort = 0,       # 0 = listener not enabled (option not passed to installer); use 8445 when enabled
  [string]$LocalIP = "",
  [string]$AutoAssignIP = "0",   # "1" = use GIM_AUTO_SET_CLIENT_IP (omit LOCALIP per IBM); "0" = use LOCALIP. Do not use both.
  [string]$InstallDir = "C:\Program Files\IBM\Guardium Installation Manager",
  [string]$SharedSecret = "",
  [string]$FailoverGimServerHost = "",
  [string]$GimCaFile = "",   # Optional: path on the Terraform runner to CA PEM; copied to the target automatically (for custom/listener TLS; optional for self-signed)
  [string]$GimKeyFile = "",  # Optional: path on the Terraform runner to private key PEM; copied to the target automatically (both key and cert required for custom TLS)
  [string]$GimCertFile = "", # Optional: path on the Terraform runner to certificate PEM; copied to the target automatically (both key and cert required for custom TLS)
  [string]$InstallerDir = "",    # Required for -Action install; not used for -Action uninstall
  [string]$SharePath = "",       # Optional: UNC path like \\hostname\C$\Windows\Temp
  [Parameter(Mandatory=$true)][string]$LogFile,
  [string]$CentralSummaryCsv = "",  # Optional: Path to central summary CSV file
  [ValidateSet("install", "uninstall")][string]$Action = "install",
  [string]$GimKitVersion = "",              # Desired kit version label (from servers.csv / default_gim_kit_version), for logging/comparison
  [string]$SkipIfAlreadyInstalled = "true", # "true"/"false": skip re-install if target already matches the resolved kit version
  [string]$CollectRemoteLogs = "true",      # "true"/"false": copy GIM client logs from target back to the runner
  [string]$RemoteLogDir = ""                # Local directory to place collected logs in (default: same directory as -LogFile)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Enhanced logging system with levels, colors, and progress tracking
$script:LogStep = 0
$script:TotalSteps = 8
$script:IsTerminal = $Host.UI.RawUI -ne $null

function Write-Log {
  param(
    [string]$Message,
    [ValidateSet("INFO", "WARN", "ERROR", "SUCCESS", "DEBUG")]
    [string]$Level = "INFO",
    [string]$Progress = ""
  )

  $ts = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

  # Build log line (no colors in file)
  $logLine = "[$ts] [$Level]"
  if ($Progress) {
    $logLine += " $Progress"
  }
  $logLine += " $Message"

  # Write to file (no colors)
  $logLine | Out-File -FilePath $LogFile -Append -Encoding UTF8

  # Build console line (with colors if terminal)
  $consoleLine = ""
  if ($script:IsTerminal) {
    switch ($Level) {
      "INFO"    { $color = "White" }
      "WARN"    { $color = "Yellow" }
      "ERROR"   { $color = "Red" }
      "SUCCESS" { $color = "Green" }
      "DEBUG"   { $color = "Gray" }
      default   { $color = "White" }
    }
    $consoleLine = "[$ts] "
    if ($Progress) {
      $consoleLine += "$Progress "
    }
    Write-Host -NoNewline $consoleLine
    Write-Host -ForegroundColor $color "[$Level] $Message"
  } else {
    # Non-terminal output (no colors)
    Write-Host $logLine
  }
}

function Log-Info($msg, $progress = "") { Write-Log -Message $msg -Level "INFO" -Progress $progress }
function Log-Warn($msg, $progress = "") { Write-Log -Message $msg -Level "WARN" -Progress $progress }
function Log-Error($msg, $progress = "") { Write-Log -Message $msg -Level "ERROR" -Progress $progress }
function Log-Success($msg, $progress = "") { Write-Log -Message $msg -Level "SUCCESS" -Progress $progress }
function Log-Debug($msg, $progress = "") { Write-Log -Message $msg -Level "DEBUG" -Progress $progress }

function Log-Section($title) {
  $script:LogStep++
  $progress = "[$script:LogStep/$script:TotalSteps]"
  Write-Host ""
  Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
  Write-Host "  $progress $title" -ForegroundColor Cyan
  Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
  Write-Host ""
  $logLine = "[$(Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')] [SECTION] $progress $title"
  $logLine | Out-File -FilePath $LogFile -Append -Encoding UTF8
}

# Backward compatibility
function Log($msg) { Log-Info $msg }

# Installation summary tracking (listener port 0 means not enabled)
$script:InstallSummary = @{
  HostName = $HostName
  GimServer = "$GimServerHost`:$GimServerPort"
  InstallDir = $InstallDir
  ListenerPort = if ($ListenerPort -gt 0) { $ListenerPort } else { $null }
  StartTime = Get-Date
  EndTime = $null
  Duration = $null
  Steps = @()
  Status = "SUCCESS"
  ErrorMessage = ""
}

# Function to write to central summary CSV
function Write-CentralSummary {
  param(
    [string]$Status,
    [string]$ErrorMessage = ""
  )

  if ($CentralSummaryCsv -eq "") {
    return
  }

  try {
    $timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    $duration = if ($script:InstallSummary.EndTime) {
      [math]::Round(($script:InstallSummary.EndTime - $script:InstallSummary.StartTime).TotalSeconds, 2)
    } else {
      [math]::Round(((Get-Date) - $script:InstallSummary.StartTime).TotalSeconds, 2)
    }

    # Ensure directory exists
    $csvDir = Split-Path -Path $CentralSummaryCsv -Parent
    if ($csvDir -and -not (Test-Path $csvDir)) {
      New-Item -ItemType Directory -Force -Path $csvDir | Out-Null
    }

    # Escape commas and quotes in error message for CSV
    $escapedError = $ErrorMessage -replace '"', '""' -replace "`n", " " -replace "`r", ""
    if ($escapedError -match ',') {
      $escapedError = "`"$escapedError`""
    }

    # Escape commas in other fields
    $escapedGimServer = $script:InstallSummary.GimServer -replace '"', '""'
    if ($escapedGimServer -match ',') {
      $escapedGimServer = "`"$escapedGimServer`""
    }

    $escapedInstallDir = $script:InstallSummary.InstallDir -replace '"', '""'
    if ($escapedInstallDir -match ',') {
      $escapedInstallDir = "`"$escapedInstallDir`""
    }

    $csvLine = "$timestamp,$($script:InstallSummary.HostName),$Status,$escapedGimServer,$escapedInstallDir,$($script:InstallSummary.ListenerPort),$duration,$escapedError"

    # Multiple servers write to the same CentralSummaryCsv from separate, parallel PowerShell
    # processes (one per Terraform resource) - a machine-wide mutex prevents one host's write
    # from failing with "file in use by another process" when they collide.
    $mutex = New-Object System.Threading.Mutex($false, "Global\GuardiumCentralSummaryCsv")
    $acquired = $false
    try {
      $acquired = $mutex.WaitOne(10000)

      # Check if file exists and has headers (re-checked under the lock, since another process
      # may have just created it)
      $hasHeaders = $false
      if (Test-Path $CentralSummaryCsv) {
        $firstLine = Get-Content $CentralSummaryCsv -First 1 -ErrorAction SilentlyContinue
        if ($firstLine -match "Timestamp,ServerName,Status") {
          $hasHeaders = $true
        }
      }
      if (-not $hasHeaders) {
        $headers = "Timestamp,ServerName,Status,GIMServer,InstallDirectory,ListenerPort,DurationSeconds,ErrorMessage"
        $headers | Out-File -FilePath $CentralSummaryCsv -Encoding UTF8 -Force
      }

      $csvLine | Out-File -FilePath $CentralSummaryCsv -Append -Encoding UTF8
      Log-Info "Summary written to central CSV: $CentralSummaryCsv"
    } finally {
      if ($acquired) { $mutex.ReleaseMutex() }
      $mutex.Dispose()
    }
  } catch {
    Log-Warn "Failed to write to central summary CSV: $_"
  }
}

# Runs a PowerShell script on the remote host via a one-shot scheduled task (no WinRM/SSH required).
# Pushes $ScriptContent to the target's temp dir over the already-established SMB connection, creates
# and runs a scheduled task under SYSTEM, polls for completion, then returns exit code + log content.
# Used for both installation and uninstallation.
function Invoke-RemoteScheduledScript {
  param(
    [string]$ScriptContent,
    [string]$RemoteScriptName,
    [string]$RemoteLogName,
    [string]$TaskLabel
  )

  $remoteScriptPathNative = "C:\Windows\Temp\$RemoteScriptName"
  $remoteScriptPathShare = "${driveLetter}:\Windows\Temp\$RemoteScriptName"
  $ScriptContent | Out-File -FilePath $remoteScriptPathShare -Encoding UTF8 -Force

  $taskName = "GuardiumGIM_${TaskLabel}_$(Get-Random)"
  $taskArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$remoteScriptPathNative`""

  $taskXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <Triggers>
    <TimeTrigger>
      <StartBoundary>$(Get-Date -Format "yyyy-MM-ddTHH:mm:ss")</StartBoundary>
      <Enabled>true</Enabled>
    </TimeTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>SYSTEM</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>false</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT2H</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions>
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>$taskArgs</Arguments>
    </Exec>
  </Actions>
</Task>
"@

  $taskXmlPath = Join-Path $env:TEMP "guardium_task_$(Get-Random).xml"
  $taskXml | Out-File -FilePath $taskXmlPath -Encoding Unicode -Force

  $resultExitCode = $null
  $resultLog = ""
  try {
    Log-Info "Creating scheduled task: $taskName"
    $schtasksArgs = "/Create /S $HostName /U $Username /P `"$Password`" /TN `"$taskName`" /XML `"$taskXmlPath`" /F"
    $process = Start-Process -FilePath "schtasks.exe" -ArgumentList $schtasksArgs -Wait -PassThru -NoNewWindow
    if ($process.ExitCode -ne 0) {
      throw "Failed to create scheduled task. Exit code: $($process.ExitCode)"
    }
    Log-Success "Scheduled task created successfully"

    Log-Info "Running scheduled task: $taskName"
    $runArgs = "/Run /S $HostName /U $Username /P `"$Password`" /TN `"$taskName`""
    $runProcess = Start-Process -FilePath "schtasks.exe" -ArgumentList $runArgs -Wait -PassThru -NoNewWindow
    if ($runProcess.ExitCode -ne 0) {
      throw "Failed to run scheduled task. Exit code: $($runProcess.ExitCode)"
    }

    Log-Info "Task started. Waiting for completion..."
    Start-Sleep -Seconds 5

    $maxWait = 1800  # 30 minutes
    $waited = 0
    $checkInterval = 10
    while ($waited -lt $maxWait) {
      $queryArgs = "/Query /S $HostName /U $Username /P `"$Password`" /TN `"$taskName`" /FO LIST /V"
      $taskInfo = & schtasks.exe $queryArgs.Split(' ') 2>&1 | Out-String
      if ($taskInfo -match "Status:\s+Ready") {
        Log-Success "Task completed."
        break
      } elseif ($taskInfo -match "Status:\s+Running") {
        Log-Info "Task still running... (waited $waited seconds)"
        Start-Sleep -Seconds $checkInterval
        $waited += $checkInterval
      } else {
        Start-Sleep -Seconds $checkInterval
        $waited += $checkInterval
      }
    }

    $remoteLogShare = "${driveLetter}:\Windows\Temp\$RemoteLogName"
    if (Test-Path $remoteLogShare) {
      $resultLog = (Get-Content $remoteLogShare -ErrorAction SilentlyContinue) -join "`n"
      # Every remote script logs exactly one "SCRIPT_RESULT_CODE:<n>" marker right before its
      # final exit. Take the LAST match (not a generic "exit code:" text search) - a naive first
      # match would latch onto an earlier, unrelated log line (e.g. "Installer exit code: 0"
      # logged before later checks run) and silently misreport the true final result.
      $codeMatches = [regex]::Matches($resultLog, "SCRIPT_RESULT_CODE:(-?\d+)")
      if ($codeMatches.Count -gt 0) {
        $resultExitCode = [int]$codeMatches[$codeMatches.Count - 1].Groups[1].Value
      }
    }

    # Clean up task
    $deleteArgs = "/Delete /S $HostName /U $Username /P `"$Password`" /TN `"$taskName`" /F"
    Start-Process -FilePath "schtasks.exe" -ArgumentList $deleteArgs -Wait -NoNewWindow | Out-Null
  } finally {
    if (Test-Path $taskXmlPath) {
      Remove-Item -Path $taskXmlPath -Force -ErrorAction SilentlyContinue
    }
  }

  return [pscustomobject]@{ ExitCode = $resultExitCode; Log = $resultLog }
}

# Wrap entire script execution in try-catch for error handling
try {
Log-Section "Windows GIM $Action (SMB/Scheduled Task Method)"
Log-Info "Target Host: $HostName" "[1/$script:TotalSteps]"
Log-Info "Install Directory: $InstallDir"
if ($Action -eq "install") {
  Log-Info "GIM Server: ${GimServerHost}:${GimServerPort}"
  if ($ListenerPort -gt 0) { Log-Info "Listener Port: $ListenerPort" } else { Log-Info "Listener port: not enabled" }
  if ([string]::IsNullOrWhiteSpace($FailoverGimServerHost) -eq $false) { Log-Info "Failover GIM Server: $FailoverGimServerHost" }
  if ([string]::IsNullOrWhiteSpace($SharedSecret) -eq $false) { Log-Info "Shared secret: (set)" }
  if ([string]::IsNullOrWhiteSpace($GimKitVersion) -eq $false) { Log-Info "Requested kit version: $GimKitVersion" }
  Log-Info "Installer Directory (runner): $InstallerDir"

  if (-not (Test-Path $InstallerDir)) {
    Log-Error "InstallerDir not found on runner: $InstallerDir"
    throw "InstallerDir not found on runner: $InstallerDir (check windows_gim_packages_base_dir / gim_kit_version / windows_gim_installer_dir)"
  }
}

Log-Section "Locating Installer Files"

# Find installer exe (only needed for Action=install; uninstall runs the copy already on the target)
$setup = $null
$setupPath = $null

if ($Action -eq "install") {
  # Prefer Setup.exe in GIM-Installer-* subdirectory
  $gimInstallerDirs = Get-ChildItem -Path $InstallerDir -Filter "GIM-Installer-*" -Directory -ErrorAction SilentlyContinue
  foreach ($dir in $gimInstallerDirs) {
    $setupFile = Join-Path $dir.FullName "Setup.exe"
    if (Test-Path $setupFile) {
      $setup = $setupFile
      $setupPath = $dir.FullName
      Log-Success "Found installer: $setup" "[2/$script:TotalSteps]"
      break
    }
  }

  # Fallback: Setup.exe or setup.exe in root
  if (-not $setup) {
    $setup = Join-Path $InstallerDir "Setup.exe"
    if (-not (Test-Path $setup)) {
      $setup = Join-Path $InstallerDir "setup.exe"
    }
    if (Test-Path $setup) {
      $setupPath = $InstallerDir
      Log-Success "Found installer: $setup" "[2/$script:TotalSteps]"
    }
  }

  # Fallback: .exe.signed files
  if (-not $setup) {
    $signed = Get-ChildItem -Path $InstallerDir -Filter "*.exe.signed" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($signed) {
      $setup = $signed.FullName
      $setupPath = $InstallerDir
      Log-Success "Found installer: $($signed.Name)" "[2/$script:TotalSteps]"
    }
  }

  # Last fallback: guard-GIM*.exe
  if (-not $setup) {
    $gimExe = Get-ChildItem -Path $InstallerDir -Filter "guard-GIM*.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($gimExe) {
      $setup = $gimExe.FullName
      $setupPath = $InstallerDir
      Log-Success "Found installer: $($gimExe.Name)" "[2/$script:TotalSteps]"
    }
  }

  if (-not (Test-Path $setup)) {
    Log-Error "Setup.exe, setup.exe, or guard-GIM*.exe(.signed) not found in InstallerDir: $InstallerDir"
    throw "Setup.exe, setup.exe, or guard-GIM*.exe(.signed) not found in InstallerDir: $InstallerDir"
  }
} else {
  Log-Info "Action=uninstall: skipping local installer lookup (uninstaller already resides on the target)."
}

Log-Section "Configuring SMB Connection"

# Determine remote share path
if ([string]::IsNullOrWhiteSpace($SharePath)) {
  # Default: Use admin share C$
  $SharePath = "\\$HostName\C$\Windows\Temp\guardium_gim"
}
Log-Info "Using share path: $SharePath" "[3/$script:TotalSteps]"

# Extract share name and local path
if ($SharePath -match "^\\\\([^\\]+)\\(.+)$") {
  $shareHost = $matches[1]
  $shareLocalPath = $matches[2] -replace '^([A-Z])\$', '$1:\'  # Convert C$ to C:\
  $shareLocalPath = $shareLocalPath -replace '\\', '\'  # Normalize backslashes
} else {
  throw "Invalid share path format. Expected: \\hostname\C$\path"
}

# Create credential object
$sec = ConvertTo-SecureString $Password -AsPlainText -Force
$cred = New-Object System.Management.Automation.PSCredential($Username, $sec)

# Map network drive or use UNC path directly
$driveLetter = $null
$usePSDrive = $false
try {
  # Try to map a temporary drive for easier access
  $driveLetter = "Z:"
  # Check if drive is already in use
  if (Test-Path "${driveLetter}:") {
    $driveLetter = "Y:"
    if (Test-Path "${driveLetter}:") {
      $driveLetter = "X:"
    }
  }

  Log-Info "Mapping network drive ${driveLetter}: to \\$shareHost\C$" "[3/$script:TotalSteps]"
  $netUse = New-Object System.Diagnostics.Process
  $netUse.StartInfo.FileName = "net.exe"
  $netUse.StartInfo.Arguments = "use ${driveLetter}: \\$shareHost\C$ /user:$Username `"$Password`""
  $netUse.StartInfo.UseShellExecute = $false
  $netUse.StartInfo.CreateNoWindow = $true
  $netUse.Start() | Out-Null
  $netUse.WaitForExit(30000)  # 30 second timeout

  if ($netUse.ExitCode -ne 0) {
    Log-Warn "Could not map network drive, will use UNC path directly"
    $driveLetter = $null
  } else {
    Log-Success "Successfully mapped network drive"
  }
} catch {
  Log-Warn "Could not map network drive: $_. Will use UNC path directly"
  $driveLetter = $null
}

try {
  # Create remote directory via SMB
  # If drive mapping failed, use New-PSDrive for UNC access
  if (-not $driveLetter) {
    Log-Info "Creating temporary PSDrive for directory creation..." "[3/$script:TotalSteps]"

    # Test SMB connectivity first
    $uncPath = "\\$shareHost\C$"
    Log-Info "Testing SMB connectivity to $uncPath..."

    try {
      # Test SMB connectivity with credentials
      Log-Info "Testing SMB connectivity with credentials..."
      $testConnection = New-PSDrive -Name "TestShare" -PSProvider FileSystem -Root $uncPath -Credential $cred -ErrorAction Stop
      if ($testConnection) {
        # Verify we can actually access it
        $testPath = Test-Path "TestShare:\Windows" -ErrorAction SilentlyContinue
        Remove-PSDrive -Name "TestShare" -ErrorAction SilentlyContinue
        if ($testPath) {
          Log-Success "SMB connectivity test successful"
        } else {
          throw "Cannot access SMB share path. Verify permissions for user: $Username"
        }
      } else {
        throw "Cannot create SMB connection. Verify: 1) Network connectivity, 2) Firewall allows SMB (port 445), 3) File and Printer Sharing is enabled on target host"
      }
    } catch {
      Log-Error "SMB connectivity test failed: $_"
      Log-Info "Troubleshooting steps:"
      Log-Info "  1. Verify network connectivity: Test-NetConnection -ComputerName $shareHost -Port 445"
      Log-Info "  2. Check firewall: Ensure Windows Firewall allows File and Printer Sharing (SMB-In) on $shareHost"
      Log-Info "  3. Verify File and Printer Sharing is enabled on $shareHost"
      Log-Info "  4. Test manually: net use \\$shareHost\C$ /user:$Username"
      Log-Info "  5. Verify user $Username has permissions to access C$ share"
      throw "SMB connectivity failed: $_"
    }

    $psDrive = New-PSDrive -Name "TempShare" -PSProvider FileSystem -Root $uncPath -Credential $cred -ErrorAction Stop
    $driveLetter = "TempShare"
    $usePSDrive = $true
    Log-Success "PSDrive created successfully"
  }

  $remoteDir = "${driveLetter}:\Windows\Temp\guardium_gim"
  Log-Info "Creating remote directory: $remoteDir" "[3/$script:TotalSteps]"
  New-Item -ItemType Directory -Force -Path $remoteDir -ErrorAction SilentlyContinue | Out-Null

} catch {
  Log-Error "Failed to establish SMB connection to $shareHost"
  Log-Error "Error details: $_"
  Log-Info ""
  Log-Info "Troubleshooting steps:"
  Log-Info "  1. Verify network connectivity: Test-NetConnection -ComputerName $shareHost -Port 445"
  Log-Info "  2. Check firewall: Ensure Windows Firewall allows File and Printer Sharing (SMB-In) on $shareHost"
  Log-Info "  3. Verify File and Printer Sharing is enabled on $shareHost"
  Log-Info "  4. Test manually: net use \\$shareHost\C$ /user:$Username"
  Log-Info "  5. Verify credentials are correct for user: $Username"
  throw "SMB connection failed: $_"
}

# Translates an absolute remote Windows path (assumed to be on the target's C: drive, matching the
# C$ admin share used above) into the equivalent path reachable from the runner via $driveLetter.
function Convert-ToSharePath {
  param([string]$RemotePath)
  if ($RemotePath -match '^[Cc]:[\\/](.*)$') {
    $rel = $matches[1] -replace '/', '\'
    return "${driveLetter}:\$rel"
  }
  return $null
}

try {

if ($Action -eq "uninstall") {
  Log-Section "Uninstalling GIM"

  # GIM registers as a standard InstallShield product in the Windows Uninstall registry
  # (confirmed via Uninstall_GIM.reg shipped in the kit, which targets
  # HKLM\...\Uninstall\InstallShield_{...}). That registry entry is authoritative - it's exactly
  # what Windows itself uses for "Programs and Features" - so it's used as the primary source for
  # the uninstaller path. Matched broadly on "*Guardium*" in DisplayName (confirmed real-world
  # value: "IBM(R) Guardium(R) GIM" - note it does NOT contain the words "Installation Manager",
  # despite IBM's docs calling the product that). Falls back to a known fixed location the
  # installer actually uses (C:\Windows\$IBM Windows GIM$\Setup.exe, confirmed via a live
  # UninstallString - NOT under InstallDir), then to searching InstallDir for a kept installer
  # copy as a last resort (folder naming varies - IBM's docs call it "GIM_Installer*", the kit
  # itself uses "GIM-Installer-*"). All done on the target itself (via the scheduled task below),
  # since that's where the registry/files actually live.
  $uninstallScript = @"
`$ErrorActionPreference = "Stop"
`$LogFile = "C:\Windows\Temp\guardium_gim_uninstall.log"
function Log(`$msg) {
  `$ts = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
  "[" + `$ts + "] " + `$msg | Tee-Object -FilePath `$LogFile -Append | Out-Host
}
Log "Starting GIM uninstall"

`$exePath = `$null
`$roots = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')
`$entry = Get-ItemProperty -Path `$roots -ErrorAction SilentlyContinue | Where-Object { `$_.DisplayName -like "*Guardium*" -or `$_.Publisher -eq "IBM" } | Select-Object -First 1
if (`$entry) {
  Log "Found registry uninstall entry: `$(`$entry.DisplayName)"
  `$us = if (`$entry.QuietUninstallString) { `$entry.QuietUninstallString } else { `$entry.UninstallString }
  if (`$us.StartsWith('"')) {
    `$endQuote = `$us.IndexOf('"', 1)
    if (`$endQuote -gt 0) { `$exePath = `$us.Substring(1, `$endQuote - 1) }
  } else {
    `$exePath = (`$us -split ' ')[0]
  }
}

if (-not `$exePath -or -not (Test-Path `$exePath)) {
  `$knownPath = 'C:\Windows\`$IBM Windows GIM`$\Setup.exe'
  if (Test-Path `$knownPath) {
    `$exePath = `$knownPath
    Log "Using known fallback installer path: `$exePath"
  }
}

if ((-not `$exePath -or -not (Test-Path `$exePath)) -and (Test-Path "$InstallDir")) {
  Log "No usable registry or known-path entry; searching InstallDir for a kept installer copy"
  `$dir = Get-ChildItem -Path "$InstallDir" -Filter "GIM*Installer*" -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
  if (`$dir) {
    `$candidate = Join-Path `$dir.FullName "setup.exe"
    if (-not (Test-Path `$candidate)) { `$candidate = Join-Path `$dir.FullName "Setup.exe" }
    if (Test-Path `$candidate) { `$exePath = `$candidate }
  }
  if (-not `$exePath) {
    `$found = Get-ChildItem -Path "$InstallDir" -Filter "*etup.exe" -Recurse -ErrorAction SilentlyContinue | Where-Object { `$_.FullName -notmatch '\\modules\\' } | Select-Object -First 1
    if (`$found) { `$exePath = `$found.FullName }
  }
}

if (-not `$exePath -or -not (Test-Path `$exePath)) {
  Log "ERROR: No uninstaller found via registry or InstallDir"
  Log "SCRIPT_RESULT_CODE:3"
  exit 3
}
Log "Running uninstaller: `$exePath"
`$proc = Start-Process -FilePath `$exePath -ArgumentList "-UNINSTALL -UNATTENDED" -Wait -PassThru -NoNewWindow
Log "Uninstaller exit code: `$(`$proc.ExitCode)"
Log "SCRIPT_RESULT_CODE:`$(`$proc.ExitCode)"
exit `$proc.ExitCode
"@

  $taskResult = Invoke-RemoteScheduledScript -ScriptContent $uninstallScript -RemoteScriptName "guardium_gim_uninstall.ps1" -RemoteLogName "guardium_gim_uninstall.log" -TaskLabel "Uninstall"
  Log-Info "Uninstaller log:"
  if ($taskResult.Log) { $taskResult.Log -split "`n" | ForEach-Object { Log-Info $_ } }

  if ($taskResult.ExitCode -eq 3) {
    Log-Warn "No uninstaller found via registry or InstallDir on $HostName; nothing to uninstall (may already be removed)."
    $script:InstallSummary.Status = "UNINSTALL_SKIPPED"
    Write-CentralSummary -Status "UNINSTALL_SKIPPED" -ErrorMessage "No uninstaller found"
  } elseif ($null -eq $taskResult.ExitCode -or $taskResult.ExitCode -ne 0) {
    $script:InstallSummary.Status = "UNINSTALL_FAILED"
    Write-CentralSummary -Status "UNINSTALL_FAILED" -ErrorMessage "Uninstaller exit code $($taskResult.ExitCode)"
    throw "Uninstall failed with exit code: $($taskResult.ExitCode)"
  } else {
    Log-Success "GIM uninstalled successfully from $HostName"
    $script:InstallSummary.Status = "SUCCESS"
    Write-CentralSummary -Status "UNINSTALLED" -ErrorMessage ""
  }
} else {

Log-Section "Checking Existing Installation"

# Version check: compare the kit's own version marker (gimver, shipped alongside Setup.exe) against
# the marker already on the target (InstallDir\gimver). This reflects the real state of the target
# host, not just Terraform state, so it still works after state loss/drift (e.g. DR, migration).
$desiredVersion = ""
$localVerFile = Join-Path $setupPath "Program Files\gimver"
if (Test-Path $localVerFile) {
  $desiredVersion = (Get-Content $localVerFile -TotalCount 1 -ErrorAction SilentlyContinue)
}
if ([string]::IsNullOrWhiteSpace($desiredVersion)) { $desiredVersion = $GimKitVersion }
Log-Info "Desired GIM kit version: $(if ([string]::IsNullOrWhiteSpace($desiredVersion)) { '(unknown)' } else { $desiredVersion })"

$skipInstall = $false
if (($SkipIfAlreadyInstalled -eq "true") -and (-not [string]::IsNullOrWhiteSpace($desiredVersion))) {
  $installDirShare = Convert-ToSharePath -RemotePath $InstallDir
  if ($installDirShare) {
    $remoteVerFile = Join-Path $installDirShare "gimver"
    $installedVersion = ""
    if (Test-Path $remoteVerFile) {
      $installedVersion = (Get-Content $remoteVerFile -TotalCount 1 -ErrorAction SilentlyContinue)
    }
    Log-Info "Installed GIM kit version on $HostName`: $(if ([string]::IsNullOrWhiteSpace($installedVersion)) { '(not installed)' } else { $installedVersion })"
    if ($installedVersion -and ($installedVersion -eq $desiredVersion)) {
      $skipInstall = $true
    }
  } else {
    Log-Warn "InstallDir is not on the target's C: drive; cannot check existing version via SMB. Proceeding with installation."
  }
}

if ($skipInstall) {
  Log-Info "GIM already at desired version ($desiredVersion) on $HostName - verifying its service is running before skipping installer execution."

  # Installer isn't run in this branch, so the service state must be checked separately (still
  # via a remote-scheduled script, since SMB alone can't execute anything on the target).
  $svcCheckScript = @"
`$ErrorActionPreference = "Stop"
`$LogFile = "C:\Windows\Temp\guardium_gim_svc_check.log"
function Log(`$msg) {
  `$ts = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
  "[" + `$ts + "] " + `$msg | Tee-Object -FilePath `$LogFile -Append | Out-Host
}
`$ok = `$false
for (`$i = 1; `$i -le 5; `$i++) {
  `$svc = Get-Service -Name "GIM" -ErrorAction SilentlyContinue
  if (`$svc -and `$svc.Status.ToString() -eq "Running") { `$ok = `$true; break }
  if (`$svc -and `$i -eq 1) {
    Log "GIM service found but not running (status: `$(`$svc.Status)) - attempting Start-Service"
    Start-Service -Name "GIM" -ErrorAction SilentlyContinue
  }
  Start-Sleep -Seconds 3
}
`$svc = Get-Service -Name "GIM" -ErrorAction SilentlyContinue
Log "GIM service status: `$(if (`$svc) { `$svc.Status } else { 'NotFound' })"
if (-not `$ok) { Log "SCRIPT_RESULT_CODE:20"; exit 20 }

# Service is running - the GIM service can be Running yet still unable to register with
# Guardium (wrong/unreachable gim_server_host, firewall, appliance down), which the service
# state alone would never reveal. Confirm the target can actually reach the appliance over TCP.
`$reachable = `$false
try {
  `$client = New-Object System.Net.Sockets.TcpClient
  `$iar = `$client.BeginConnect("$GimServerHost", $GimServerPort, `$null, `$null)
  `$reachable = `$iar.AsyncWaitHandle.WaitOne(5000) -and `$client.Connected
  `$client.Close()
} catch { `$reachable = `$false }
Log "Guardium appliance ${GimServerHost}:${GimServerPort} reachable: `$reachable"
if (`$reachable) { Log "SCRIPT_RESULT_CODE:0"; exit 0 } else { Log "SCRIPT_RESULT_CODE:21"; exit 21 }
"@

  $svcResult = Invoke-RemoteScheduledScript -ScriptContent $svcCheckScript -RemoteScriptName "guardium_gim_svc_check.ps1" -RemoteLogName "guardium_gim_svc_check.log" -TaskLabel "SvcCheck"
  if ($svcResult.Log) { $svcResult.Log -split "`n" | ForEach-Object { Log-Info $_ } }

  if ($svcResult.ExitCode -eq 20) {
    $script:InstallSummary.Status = "FAILED"
    Write-CentralSummary -Status "FAILED" -ErrorMessage "GIM already at desired version but service not running on $HostName"
    throw "GIM is already at the desired version ($desiredVersion) on $HostName, but its service is not running. Not reporting success."
  } elseif ($svcResult.ExitCode -ne 0) {
    $script:InstallSummary.Status = "FAILED"
    Write-CentralSummary -Status "FAILED" -ErrorMessage "GIM service running but $HostName cannot reach Guardium appliance ${GimServerHost}:${GimServerPort}"
    throw "GIM service is running on $HostName, but it cannot reach the Guardium appliance at ${GimServerHost}:${GimServerPort} (TCP connect failed). Not reporting success - check gim_server_host, firewall, and network routing."
  }

  Log-Success "GIM service verified running on $HostName"
  Log-Success "Confirmed $HostName can reach Guardium appliance ${GimServerHost}:${GimServerPort}"
  Log-Success "GIM already installed at the desired version ($desiredVersion) on $HostName - skipping installer execution."
  $script:InstallSummary.Status = "SKIPPED_ALREADY_INSTALLED"
  Write-CentralSummary -Status "SKIPPED_ALREADY_INSTALLED" -ErrorMessage ""
} else {

Log-Section "Copying Files to Remote Host"

  # Copy installer files
  Log-Info "Copying installer to remote host via SMB..." "[4/$script:TotalSteps]"

  if ($setupPath -ne $InstallerDir) {
    # Copy the GIM-Installer-* subdirectory
    $setupDirName = Split-Path $setupPath -Leaf
    $destPath = "${driveLetter}:\Windows\Temp\guardium_gim\$setupDirName"

    Copy-Item -Path $setupPath -Destination $destPath -Recurse -Force
    $remoteSetupDir = "C:\Windows\Temp\guardium_gim\$setupDirName"
  } else {
    # Copy entire installer directory contents
    $destPath = "${driveLetter}:\Windows\Temp\guardium_gim"
    Copy-Item -Path "$InstallerDir\*" -Destination $destPath -Recurse -Force
    $remoteSetupDir = "C:\Windows\Temp\guardium_gim"
  }

  Log-Success "Files copied successfully"

  # Get Windows host IP address (needed when AutoAssignIP=0; IBM: do not specify both LOCALIP and AUTO_ASSIGN_IP)
  $useAutoAssign = ($AutoAssignIP -eq "1")
  if ($useAutoAssign) {
    Log-Info "Using GIM_AUTO_SET_CLIENT_IP (auto_assign_ip=1); LOCALIP will be omitted per IBM requirement"
  } elseif ([string]::IsNullOrWhiteSpace($LocalIP)) {
    Log-Info "Getting Windows host IP address..." "[4/$script:TotalSteps]"
    try {
      # Use WMI over DCOM (doesn't require WinRM)
      $wmi = Get-WmiObject -ComputerName $HostName -Credential $cred -Class Win32_NetworkAdapterConfiguration -Filter "IPEnabled=True" -ErrorAction SilentlyContinue
      if ($wmi) {
        $LocalIP = ($wmi | Where-Object { $_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "169.254.*" } | Select-Object -First 1).IPAddress[0]
      }
      if ([string]::IsNullOrWhiteSpace($LocalIP)) {
        $LocalIP = $HostName
      }
    } catch {
      Log-Warn "Could not determine LOCALIP automatically, using hostname"
      $LocalIP = $HostName
    }
  }
  if (-not $useAutoAssign) { Log-Info "Using LOCALIP: $LocalIP" }

Log-Section "Creating Installation Script"

  # Build installer args as single string (like WinRM) so paths with spaces are properly quoted for IBM installer
  $installDirQ = $InstallDir -replace '"', '`"'
  $gimHostQ = $GimServerHost -replace '"', '`"'
  $localQ = $LocalIP -replace '"', '`"'
  $failoverQ = if ([string]::IsNullOrWhiteSpace($FailoverGimServerHost)) { "" } else { " -FAILOVER_APPLIANCE `"$($FailoverGimServerHost -replace '"', '`"')`"" }
  $sharedQ = if ([string]::IsNullOrWhiteSpace($SharedSecret)) { "" } else { " -SHARED_SECRET `"$($SharedSecret -replace '"', '`"')`"" }
  $listenerQ = if ($ListenerPort -gt 0) { " -LISTENER_PORT $ListenerPort" } else { "" }
  # Custom TLS certs: only pass to installer when both key and cert are set. GimKeyFile/GimCertFile/
  # GimCaFile are paths on the Terraform runner - copy them to the target's C: drive (via the same
  # SMB mapping used for the installer payload) before referencing them in the installer args (the
  # installer runs on the target and cannot read the runner's filesystem).
  $certQ = ""
  $hasKey = [string]::IsNullOrWhiteSpace($GimKeyFile) -eq $false
  $hasCert = [string]::IsNullOrWhiteSpace($GimCertFile) -eq $false
  $hasCa = [string]::IsNullOrWhiteSpace($GimCaFile) -eq $false
  if ($hasKey -and $hasCert) {
    if (-not (Test-Path $GimKeyFile)) { throw "GimKeyFile not found on runner: $GimKeyFile" }
    if (-not (Test-Path $GimCertFile)) { throw "GimCertFile not found on runner: $GimCertFile" }
    if ($hasCa -and -not (Test-Path $GimCaFile)) { throw "GimCaFile not found on runner: $GimCaFile" }

    $certShareDir = "${driveLetter}:\Windows\Temp\guardium_gim\certs"
    Log-Info "Copying custom TLS certificate(s) to $HostName`:C:\Windows\Temp\guardium_gim\certs"
    New-Item -ItemType Directory -Force -Path $certShareDir -ErrorAction SilentlyContinue | Out-Null

    Copy-Item -Path $GimKeyFile -Destination $certShareDir -Force
    Copy-Item -Path $GimCertFile -Destination $certShareDir -Force
    $remoteKeyFile = "C:\Windows\Temp\guardium_gim\certs\$([System.IO.Path]::GetFileName($GimKeyFile))"
    $remoteCertFile = "C:\Windows\Temp\guardium_gim\certs\$([System.IO.Path]::GetFileName($GimCertFile))"

    $certQ = " -KEY_FILE `"$($remoteKeyFile -replace '"', '`"')`" -CERT_FILE `"$($remoteCertFile -replace '"', '`"')`""
    if ($hasCa) {
      Copy-Item -Path $GimCaFile -Destination $certShareDir -Force
      $remoteCaFile = "C:\Windows\Temp\guardium_gim\certs\$([System.IO.Path]::GetFileName($GimCaFile))"
      $certQ += " -CA_FILE `"$($remoteCaFile -replace '"', '`"')`""
    }
  } elseif ($hasKey -or $hasCert -or $hasCa) {
    Log-Warn "Custom TLS: both GimKeyFile and GimCertFile are required; omitting cert args (only one or CA set)"
  }

  $argLine = if ($useAutoAssign) {
    "-UNATTENDED -APPLIANCE `"$gimHostQ`" -INSTALLPATH `"$installDirQ`" -GIM_AUTO_SET_CLIENT_IP 1$listenerQ$failoverQ$sharedQ$certQ"
  } else {
    "-UNATTENDED -LOCALIP `"$localQ`" -APPLIANCE `"$gimHostQ`" -INSTALLPATH `"$installDirQ`"$listenerQ$failoverQ$sharedQ$certQ"
  }

  $argLineEsc = $argLine -replace "'", "''" -replace '"', '`"'
  $argLineForRemote = "  `$argLine = `"$argLineEsc`""

  # Create PowerShell script to run installer locally
  $setupExeName = Split-Path $setup -Leaf
  $remoteSetupExe = Join-Path $remoteSetupDir $setupExeName

  $installScript = @"
`$ErrorActionPreference = "Stop"
`$LogFile = "C:\Windows\Temp\guardium_gim_install.log"

function Log(`$msg) {
  `$ts = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
  "[" + `$ts + "] " + `$msg | Tee-Object -FilePath `$LogFile -Append | Out-Host
}

Log "Starting GIM installer execution"
Log "Installer: $remoteSetupExe"
Log "GIM Server: ${GimServerHost}:${GimServerPort}"
Log "Install Dir: $InstallDir"

`$exe = Get-Item "$remoteSetupExe" -ErrorAction SilentlyContinue
if (-not `$exe) {
  `$exe = Get-ChildItem -Path "$remoteSetupDir" -Filter "Setup.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
}
if (-not `$exe) {
  `$exe = Get-ChildItem -Path "$remoteSetupDir" -Filter "setup.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
}
if (-not `$exe) {
  `$exe = Get-ChildItem -Path "C:\Windows\Temp\guardium_gim" -Filter "*.exe.signed" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
}

if (`$exe) {
  Log "Running installer: `$(`$exe.FullName)"
$argLineForRemote
  Log "Installer command: `$(`$exe.FullName) with args (secret not logged)"
  `$proc = Start-Process -FilePath `$exe.FullName -ArgumentList `$argLine -Wait -PassThru -NoNewWindow
  Log "Installer exit code: `$(`$proc.ExitCode)"
  if (`$proc.ExitCode -ne 0) { Log "SCRIPT_RESULT_CODE:`$(`$proc.ExitCode)"; exit `$proc.ExitCode }

  # Installer exit code 0 is not sufficient evidence of success on its own - confirm the GIM
  # service (name "GIM") actually reached the Running state before this is treated as success.
  `$svcOk = `$false
  for (`$i = 1; `$i -le 5; `$i++) {
    `$svc = Get-Service -Name "GIM" -ErrorAction SilentlyContinue
    if (`$svc -and `$svc.Status.ToString() -eq "Running") { `$svcOk = `$true; break }
    if (`$svc -and `$i -eq 1) {
      Log "GIM service found but not running (status: `$(`$svc.Status)) - attempting Start-Service"
      Start-Service -Name "GIM" -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 3
  }
  `$svc = Get-Service -Name "GIM" -ErrorAction SilentlyContinue
  Log "GIM service status: `$(if (`$svc) { `$svc.Status } else { 'NotFound' })"
  if (-not `$svcOk) { Log "SCRIPT_RESULT_CODE:20"; exit 20 }

  # Service is running - the GIM service can be Running yet still unable to register with
  # Guardium (wrong/unreachable gim_server_host, firewall, appliance down), which the service
  # state alone would never reveal. Confirm the target can actually reach the appliance over TCP.
  `$reachable = `$false
  try {
    `$client = New-Object System.Net.Sockets.TcpClient
    `$iar = `$client.BeginConnect("$GimServerHost", $GimServerPort, `$null, `$null)
    `$reachable = `$iar.AsyncWaitHandle.WaitOne(5000) -and `$client.Connected
    `$client.Close()
  } catch { `$reachable = `$false }
  Log "Guardium appliance ${GimServerHost}:${GimServerPort} reachable: `$reachable"
  if (`$reachable) { Log "SCRIPT_RESULT_CODE:0"; exit 0 } else { Log "SCRIPT_RESULT_CODE:21"; exit 21 }
} else {
  Log "ERROR: Installer not found at $remoteSetupExe"
  Log "SCRIPT_RESULT_CODE:1"
  exit 1
}
"@

Log-Section "Creating Scheduled Task"

  $taskResult = Invoke-RemoteScheduledScript -ScriptContent $installScript -RemoteScriptName "guardium_gim_install.ps1" -RemoteLogName "guardium_gim_install.log" -TaskLabel "Install"

Log-Section "Executing Installation"

  Log-Info "Installer log:"
  if ($taskResult.Log) { $taskResult.Log -split "`n" | ForEach-Object { Log-Info $_ } }

  if ($taskResult.ExitCode -eq 20) {
    Log-Error "Installer exited 0 but the GIM service is not running on $HostName"
    throw "Installer reported success (exit code 0) but the GIM service is not running on $HostName. Not reporting success."
  } elseif ($taskResult.ExitCode -eq 21) {
    Log-Error "GIM service is running on $HostName but it cannot reach the Guardium appliance ${GimServerHost}:${GimServerPort}"
    throw "GIM service is running on $HostName, but it cannot reach the Guardium appliance at ${GimServerHost}:${GimServerPort} (TCP connect failed). Not reporting success - check gim_server_host, firewall, and network routing."
  } elseif ($null -eq $taskResult.ExitCode -or $taskResult.ExitCode -ne 0) {
    Log-Error "Installer failed with exit code: $($taskResult.ExitCode)"
    throw "Installer failed with exit code: $($taskResult.ExitCode)"
  }

  Log-Success "GIM service verified running on $HostName"
  Log-Success "Confirmed $HostName can reach Guardium appliance ${GimServerHost}:${GimServerPort}"
  Log-Success "Installation completed successfully" "[7/$script:TotalSteps]"
  $script:InstallSummary.Steps += "Installation completed successfully"
  Write-CentralSummary -Status "SUCCESS" -ErrorMessage ""
}
}

# -----------------------------------------------------------
# Collect GIM client logs from the target back to the runner,
# best-effort (never fails the overall run). Applies only to
# the install action (uninstall has nothing left to collect).
# -----------------------------------------------------------
if ($Action -eq "install" -and $CollectRemoteLogs -eq "true") {
  Log-Section "Collecting Remote Logs"
  try {
    $targetLogDir = if ([string]::IsNullOrWhiteSpace($RemoteLogDir)) { Split-Path $LogFile -Parent } else { $RemoteLogDir }
    New-Item -ItemType Directory -Force -Path $targetLogDir | Out-Null

    # Each file is copied independently (its own try/catch + bounded retry) - a lock on one file
    # (GIM may still have central_logger.log open right after the service starts) must not abort
    # collection of the others. Retries are capped so a file that's genuinely stuck locked
    # doesn't stall the run.
    function Copy-RemoteLogWithRetry {
      param([string]$ShareSourcePath, [string]$NativeSourcePath, [string]$LocalDest)
      $lastError = $null
      for ($attempt = 1; $attempt -le 4; $attempt++) {
        try {
          Copy-Item -Path $ShareSourcePath -Destination $LocalDest -Force
          Log-Info "Collected remote log: $NativeSourcePath -> $LocalDest"
          return
        } catch {
          $lastError = $_
          if ($attempt -lt 4) { Start-Sleep -Seconds 5 }
        }
      }
      Log-Warn "Failed to collect remote log $NativeSourcePath after 4 attempts (~15s): $lastError"
    }

    $remoteFilesRel = @(
      "modules\GIM\current\GIM.log",
      "central_logger.log"
    )
    foreach ($rel in $remoteFilesRel) {
      $fullRemoteNative = Join-Path $InstallDir $rel
      $shareEquivalent = Convert-ToSharePath -RemotePath $fullRemoteNative
      if ($shareEquivalent -and (Test-Path $shareEquivalent)) {
        $localDest = Join-Path $targetLogDir "$HostName-$(Split-Path $rel -Leaf)"
        Copy-RemoteLogWithRetry -ShareSourcePath $shareEquivalent -NativeSourcePath $fullRemoteNative -LocalDest $localDest
      } else {
        Log-Info "Remote log not present (skipped): $fullRemoteNative"
      }
    }

    $ctlShare = Convert-ToSharePath -RemotePath "C:\IBM Windows GIM.ctl"
    if ($ctlShare -and (Test-Path $ctlShare)) {
      $localDest = Join-Path $targetLogDir "$HostName-IBM_Windows_GIM.ctl"
      Copy-RemoteLogWithRetry -ShareSourcePath $ctlShare -NativeSourcePath "C:\IBM Windows GIM.ctl" -LocalDest $localDest
    } else {
      Log-Info "Remote log not present (skipped): C:\IBM Windows GIM.ctl"
    }
  } catch {
    Log-Warn "Log collection step failed: $_"
  }
}

} finally {
  # Clean up PSDrive if we created it
  if ($usePSDrive -and (Get-PSDrive -Name "TempShare" -ErrorAction SilentlyContinue)) {
    try {
      Log-Info "Removing temporary PSDrive..."
      Remove-PSDrive -Name "TempShare" -Force -ErrorAction SilentlyContinue
    } catch {
      # Ignore cleanup errors
    }
  }

  # Disconnect network drive (if mapped via net use)
  if ($driveLetter -and $driveLetter -ne "TempShare") {
    try {
      Log-Info "Disconnecting network drive..."
      $netUse = New-Object System.Diagnostics.Process
      $netUse.StartInfo.FileName = "net.exe"
      $netUse.StartInfo.Arguments = "use ${driveLetter}: /delete /y"
      $netUse.StartInfo.UseShellExecute = $false
      $netUse.StartInfo.CreateNoWindow = $true
      $netUse.Start() | Out-Null
      $netUse.WaitForExit(5000) | Out-Null
    } catch {
      # Ignore cleanup errors
    }
  }
}

# Installation Summary
$script:InstallSummary.EndTime = Get-Date
$script:InstallSummary.Duration = ($script:InstallSummary.EndTime - $script:InstallSummary.StartTime).TotalSeconds

Log-Section "Summary"
Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Green
Write-Host "  $Action Completed (Status: $($script:InstallSummary.Status))" -ForegroundColor Green
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Green
Write-Host ""
Log-Success "Target Host: $($script:InstallSummary.HostName)"
Log-Success "Install Directory: $($script:InstallSummary.InstallDir)"
Log-Success "Duration: $([math]::Round($script:InstallSummary.Duration, 2)) seconds"
Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Green
Write-Host ""

# Write summary to log file
$summaryLine = "[$(Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')] [SUMMARY] Host=$($script:InstallSummary.HostName), Action=$Action, Status=$($script:InstallSummary.Status), InstallDir=$($script:InstallSummary.InstallDir), Duration=$([math]::Round($script:InstallSummary.Duration, 2))s"
$summaryLine | Out-File -FilePath $LogFile -Append -Encoding UTF8

Log-Success "Completed"
} catch {
  # Error handling - write failure to central summary
  $script:InstallSummary.EndTime = Get-Date
  if ($script:InstallSummary.StartTime) {
    $script:InstallSummary.Duration = ($script:InstallSummary.EndTime - $script:InstallSummary.StartTime).TotalSeconds
  }
  $script:InstallSummary.Status = "FAILED"
  $script:InstallSummary.ErrorMessage = $_.Exception.Message

  Log-Error "$Action failed: $($_.Exception.Message)"
  if ($_.ScriptStackTrace) {
    Log-Error "Stack trace: $($_.ScriptStackTrace)"
  }

  # Write failure to central summary CSV
  Write-CentralSummary -Status "FAILED" -ErrorMessage $_.Exception.Message

  # Write error to log file
  $errorLine = "[$(Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')] [ERROR] $Action failed: $($_.Exception.Message)"
  $errorLine | Out-File -FilePath $LogFile -Append -Encoding UTF8

  # Re-throw to ensure Terraform sees the failure
  throw
}
