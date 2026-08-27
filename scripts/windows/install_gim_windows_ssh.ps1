#!/usr/bin/env bash
#
# Copyright (c) IBM Corp. 2026
# SPDX-License-Identifier: Apache-2.0
#

param(
  [Parameter(Mandatory=$true)][string]$HostName,
  [int]$Port = 22,
  [Parameter(Mandatory=$true)][string]$Username,
  [Parameter(Mandatory=$true)][string]$Password,
  [Parameter(Mandatory=$true)][string]$GimServerHost,
  [int]$GimServerPort = 8446,
  [int]$ListenerPort = 0,       # 0 = not enabled; 8445 when enabled
  [string]$LocalIP = "",
  [string]$AutoAssignIP = "0",   # "1" = use GIM_AUTO_SET_CLIENT_IP (omit LOCALIP per IBM); "0" = use LOCALIP. Do not use both.
  [string]$InstallDir = "C:\Program Files\IBM\Guardium Installation Manager",
  [string]$FailoverGimServerHost = "",
  [string]$SharedSecret = "",
  [string]$GimCaFile = "",   # Optional: path on the Terraform runner to CA PEM; copied to the target automatically (for custom/listener TLS)
  [string]$GimKeyFile = "",  # Optional: path on the Terraform runner to private key PEM; copied to the target automatically (both key and cert required)
  [string]$GimCertFile = "", # Optional: path on the Terraform runner to certificate PEM; copied to the target automatically (both key and cert required)
  [string]$InstallerDir = "", # Required for -Action install; not used for -Action uninstall
  [string]$SshKeyPath = "",
  [Parameter(Mandatory=$true)][string]$LogFile,
  [string]$CentralSummaryCsv = "",
  [ValidateSet("install", "uninstall")][string]$Action = "install",
  [string]$GimKitVersion = "",              # Desired kit version label (from servers.csv / default_gim_kit_version), for logging/comparison
  [string]$SkipIfAlreadyInstalled = "true", # "true"/"false": skip re-install if target already matches the resolved kit version
  [string]$CollectRemoteLogs = "true",      # "true"/"false": copy GIM client logs from target back to the runner
  [string]$RemoteLogDir = ""                # Local directory to place collected logs in (default: same directory as -LogFile)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Log($msg) {
  $ts = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
  $line = "[$ts] $msg"
  $line | Tee-Object -FilePath $LogFile -Append | Out-Host
}

function Invoke-SSHCommand {
  param(
    [string]$Command,
    [switch]$IgnoreErrors
  )

  $sshArgs = @(
    "-p", $Port.ToString(),
    "-o", "StrictHostKeyChecking=accept-new",
    "-o", "LogLevel=ERROR"
  )

  if ($SshKeyPath -and (Test-Path $SshKeyPath)) {
    # Use SSH key authentication (preferred)
    $sshArgs += "-i", $SshKeyPath
    $sshCmd = "ssh $($sshArgs -join ' ') ${Username}@${HostName} `"$Command`""
    $result = Invoke-Expression $sshCmd 2>&1
    if ($LASTEXITCODE -ne 0 -and -not $IgnoreErrors) {
      throw "SSH command failed: $result"
    }
    return $result
  } else {
    # Password authentication - Windows OpenSSH doesn't support password auth from command line
    # Options: Use Plink/PSCP (PuTTY) or SSH keys

    # Check for Plink (PuTTY) - supports password auth
    if (Get-Command plink -ErrorAction SilentlyContinue) {
      Log "Using Plink for SSH (password authentication)"
      $plinkCmd = "echo y | plink -ssh -P $Port -pw `"$Password`" $Username@$HostName `"$Command`""
      $result = cmd /c $plinkCmd 2>&1
      $exitCode = $LASTEXITCODE
      if ($exitCode -ne 0 -and -not $IgnoreErrors) {
        throw "SSH command failed (exit code $exitCode): $result"
      }
      return $result
    } else {
      # No Plink and no SSH key - provide helpful error
      $errorMsg = @"
Password authentication requires one of the following:
1. SSH Key: Provide -SshKeyPath parameter (recommended)
2. PuTTY Tools: Install PuTTY (includes plink.exe and pscp.exe)
   Download: https://www.putty.org/
   Or install via: choco install putty

For SSH key setup:
- Generate key: ssh-keygen -t rsa -b 4096
- Copy to Windows host: ssh-copy-id ${Username}@${HostName}
- Use: -SshKeyPath "C:\Users\$env:USERNAME\.ssh\id_rsa"
"@
      throw $errorMsg
    }
  }
}

function Copy-FileViaSSH {
  param(
    [string]$Source,
    [string]$Destination
  )

  $scpArgs = @(
    "-P", $Port.ToString(),
    "-o", "StrictHostKeyChecking=accept-new",
    "-o", "LogLevel=ERROR",
    "-r"
  )

  if ($SshKeyPath -and (Test-Path $SshKeyPath)) {
    # Use SSH key authentication (preferred)
    $scpArgs += "-i", $SshKeyPath
    $scpCmd = "scp $($scpArgs -join ' ') `"$Source`" ${Username}@${HostName}:`"$Destination`""
    $result = Invoke-Expression $scpCmd 2>&1
    if ($LASTEXITCODE -ne 0) {
      throw "SCP copy failed: $result"
    }
    return
  } else {
    # Password authentication for SCP
    if (Get-Command pscp -ErrorAction SilentlyContinue) {
      # Use PSCP (PuTTY) with password
      Log "Using PSCP for file copy (password authentication)"
      $pscpCmd = "pscp -P $Port -pw `"$Password`" -r `"$Source`" ${Username}@${HostName}:`"$Destination`""
      $result = cmd /c $pscpCmd 2>&1
      if ($LASTEXITCODE -ne 0) {
        throw "SCP copy failed: $result"
      }
      return
    } else {
      $errorMsg = @"
Password authentication for file copy requires one of the following:
1. SSH Key: Provide -SshKeyPath parameter (recommended)
2. PuTTY Tools: Install PuTTY (includes pscp.exe)
   Download: https://www.putty.org/
   Or install via: choco install putty
"@
      throw $errorMsg
    }
  }
}

# Copies a single remote file back to the runner via SCP, best-effort (returns $false on any failure).
function Copy-FileFromSSH {
  param(
    [string]$Source,
    [string]$Destination
  )
  $scpArgs = @(
    "-P", $Port.ToString(),
    "-o", "StrictHostKeyChecking=accept-new",
    "-o", "LogLevel=ERROR"
  )
  try {
    if ($SshKeyPath -and (Test-Path $SshKeyPath)) {
      $scpArgs += "-i", $SshKeyPath
      $scpCmd = "scp $($scpArgs -join ' ') ${Username}@${HostName}:`"$Source`" `"$Destination`""
      Invoke-Expression $scpCmd 2>&1 | Out-Null
      return ($LASTEXITCODE -eq 0)
    } elseif (Get-Command pscp -ErrorAction SilentlyContinue) {
      $pscpCmd = "pscp -P $Port -pw `"$Password`" ${Username}@${HostName}:`"$Source`" `"$Destination`""
      cmd /c $pscpCmd 2>&1 | Out-Null
      return ($LASTEXITCODE -eq 0)
    }
    return $false
  } catch {
    return $false
  }
}

# Verifies the GIM Windows service (service name "GIM") is actually Running on the target -
# success is only reported once this is confirmed, not merely because the installer returned
# exit code 0. Attempts one Start-Service if the service exists but is stopped, then polls
# briefly for the SCM to bring it up.
function Confirm-GimServiceRunning {
  $maxAttempts = 5
  $statusCmd = "powershell -NoProfile -Command `"(Get-Service -Name 'GIM' -ErrorAction SilentlyContinue).Status`""
  for ($i = 1; $i -le $maxAttempts; $i++) {
    $status = ""
    try { $status = (Invoke-SSHCommand -Command $statusCmd -IgnoreErrors).ToString().Trim() } catch { $status = "" }
    if ($status -eq "Running") {
      return @{ Ok = $true; Status = "Running" }
    }
    if ($status -and $i -eq 1) {
      Log "GIM service found but not running (status: $status) - attempting Start-Service"
      try { Invoke-SSHCommand -Command "powershell -NoProfile -Command `"Start-Service -Name 'GIM' -ErrorAction SilentlyContinue`"" -IgnoreErrors | Out-Null } catch {}
    }
    Start-Sleep -Seconds 3
  }
  $status = ""
  try { $status = (Invoke-SSHCommand -Command $statusCmd -IgnoreErrors).ToString().Trim() } catch { $status = "" }
  return @{ Ok = $false; Status = if ([string]::IsNullOrWhiteSpace($status)) { "NotFound" } else { $status } }
}

# The GIM service can be Running yet still unable to register with Guardium (wrong/unreachable
# gim_server_host, firewall, appliance down) - that's a soft failure the installer itself doesn't
# surface as a bad exit code. Confirm the target can actually reach the appliance over TCP before
# treating the run as a real success.
function Confirm-GimApplianceReachable {
  param([string]$ApplianceHost, [int]$AppliancePort)
  $cmd = "powershell -NoProfile -Command `"try { `$c = New-Object System.Net.Sockets.TcpClient; `$iar = `$c.BeginConnect('$ApplianceHost', $AppliancePort, `$null, `$null); `$ok = `$iar.AsyncWaitHandle.WaitOne(5000) -and `$c.Connected; `$c.Close(); Write-Output `$ok } catch { Write-Output 'False' }`""
  try {
    $out = (Invoke-SSHCommand -Command $cmd -IgnoreErrors).ToString().Trim()
    return ($out -match "True")
  } catch {
    return $false
  }
}

Log "Starting Windows GIM $Action (SSH)"
Log "Target: $HostName (port $Port)"
Log "InstallDir: $InstallDir"

if ($Action -eq "uninstall") {
  # -----------------------------------------------------------
  # Uninstall: GIM registers as a standard InstallShield product
  # in the Windows Uninstall registry (confirmed via the
  # Uninstall_GIM.reg shipped in the kit, which targets
  # HKLM\...\Uninstall\InstallShield_{...}). That registry entry
  # is authoritative - it's exactly what Windows itself uses for
  # "Programs and Features" - so it's used as the primary source
  # for the uninstaller path. Matched broadly on "*Guardium*" in
  # DisplayName (confirmed real-world value: "IBM(R) Guardium(R)
  # GIM" - note it does NOT contain the words "Installation
  # Manager", despite IBM's docs calling the product that). Falls
  # back to a known fixed location the installer actually uses
  # (C:\Windows\$IBM Windows GIM$\Setup.exe, confirmed via a live
  # UninstallString - NOT under InstallDir), then to searching
  # InstallDir for a kept installer copy as a last resort (folder
  # naming varies - IBM's docs call it "GIM_Installer*", the kit
  # itself uses "GIM-Installer-*").
  #
  # Sent via -EncodedCommand (not -Command "...") so the script
  # content (which needs literal double quotes to parse
  # UninstallString) never has to survive nested shell/SSH quoting.
  # -----------------------------------------------------------
  Log "Locating GIM uninstaller on $HostName (registry, then known paths, then InstallDir)"
  $uninstallScriptContent = @"
`$exePath = `$null
`$roots = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')
`$entry = Get-ItemProperty -Path `$roots -ErrorAction SilentlyContinue | Where-Object { `$_.DisplayName -like "*Guardium*" -or `$_.Publisher -eq "IBM" } | Select-Object -First 1
if (`$entry) {
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
  if (Test-Path `$knownPath) { `$exePath = `$knownPath }
}
if ((-not `$exePath -or -not (Test-Path `$exePath)) -and (Test-Path "$InstallDir")) {
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
  Write-Output "NOTFOUND"
} else {
  `$p = Start-Process -FilePath `$exePath -ArgumentList "-UNINSTALL -UNATTENDED" -Wait -PassThru
  Write-Output "EXITCODE:`$(`$p.ExitCode)"
  Write-Output "PATH:`$exePath"
}
"@

  $encodedCommand = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($uninstallScriptContent))
  $uninstallCmd = "powershell -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encodedCommand"
  $output = Invoke-SSHCommand -Command $uninstallCmd
  Log $output

  if ($output -match "NOTFOUND") {
    Log "WARN: No uninstaller found via registry or InstallDir on $HostName; nothing to uninstall (may already be removed)."
  } else {
    $exitCode = 1
    if ($output -match "EXITCODE:(-?\d+)") {
      $exitCode = [int]$matches[1]
    }
    if ($exitCode -ne 0) {
      throw "Uninstall failed with exit code: $exitCode"
    }
    Log "GIM uninstalled successfully from $HostName"
  }
  Log "Completed"
  exit 0
}

if (-not (Test-Path $InstallerDir)) {
  throw "InstallerDir not found on runner: $InstallerDir (check windows_gim_packages_base_dir / gim_kit_version / windows_gim_installer_dir)"
}

# Find installer exe
$setup = $null
$setupPath = $null

# Prefer Setup.exe in GIM-Installer-* subdirectory
$gimInstallerDirs = Get-ChildItem -Path $InstallerDir -Filter "GIM-Installer-*" -Directory -ErrorAction SilentlyContinue
foreach ($dir in $gimInstallerDirs) {
  $setupFile = Join-Path $dir.FullName "Setup.exe"
  if (Test-Path $setupFile) {
    $setup = $setupFile
    $setupPath = $dir.FullName
    Log "Using installer: $setup"
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
    Log "Using installer: $setup"
  }
}

# Fallback: .exe.signed files
if (-not $setup) {
  $signed = Get-ChildItem -Path $InstallerDir -Filter "*.exe.signed" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($signed) {
    $setup = $signed.FullName
    $setupPath = $InstallerDir
    Log "Using installer: $($signed.Name)"
  }
}

# Last fallback: guard-GIM*.exe
if (-not $setup) {
  $gimExe = Get-ChildItem -Path $InstallerDir -Filter "guard-GIM*.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($gimExe) {
    $setup = $gimExe.FullName
    $setupPath = $InstallerDir
    Log "Using installer: $($gimExe.Name)"
  }
}

if (-not (Test-Path $setup)) {
  throw "Setup.exe, setup.exe, or guard-GIM*.exe(.signed) not found in InstallerDir: $InstallerDir"
}

# -----------------------------------------------------------
# Version check: compare the kit's own version marker (gimver,
# shipped alongside Setup.exe) against the marker already on
# the target (InstallDir\gimver). This reflects the real state
# of the target host, not just Terraform state, so it still
# works after state loss/drift (e.g. DR, migration).
# -----------------------------------------------------------
$desiredVersion = ""
$localVerFile = Join-Path $setupPath "Program Files\gimver"
if (Test-Path $localVerFile) {
  $desiredVersion = (Get-Content $localVerFile -TotalCount 1 -ErrorAction SilentlyContinue)
}
if ([string]::IsNullOrWhiteSpace($desiredVersion)) { $desiredVersion = $GimKitVersion }
Log "Desired GIM kit version: $(if ([string]::IsNullOrWhiteSpace($desiredVersion)) { '(unknown)' } else { $desiredVersion })"

$skipInstall = $false
if (($SkipIfAlreadyInstalled -eq "true") -and (-not [string]::IsNullOrWhiteSpace($desiredVersion))) {
  try {
    $checkCmd = "powershell -NoProfile -Command `"`$f = Join-Path '$InstallDir' 'gimver'; if (Test-Path `$f) { Get-Content `$f -TotalCount 1 }`""
    $installedVersion = (Invoke-SSHCommand -Command $checkCmd -IgnoreErrors).ToString().Trim()
    Log "Installed GIM kit version on $HostName`: $(if ([string]::IsNullOrWhiteSpace($installedVersion)) { '(not installed)' } else { $installedVersion })"
    if ($installedVersion -and ($installedVersion -eq $desiredVersion)) {
      $skipInstall = $true
    }
  } catch {
    Log "WARN: Could not determine installed version on $HostName ($_); proceeding with installation to be safe."
  }
}

if ($skipInstall) {
  Log "GIM already installed at the desired version ($desiredVersion) on $HostName - skipping installer execution."
  Log "Verifying GIM service is running on $HostName..."
  $svcCheck = Confirm-GimServiceRunning
  if (-not $svcCheck.Ok) {
    throw "GIM is already at the desired version ($desiredVersion) on $HostName, but its service is not running (status: $($svcCheck.Status)). Not reporting success."
  }
  Log "GIM service verified running on $HostName"
  Log "Verifying $HostName can reach Guardium appliance $GimServerHost`:$GimServerPort..."
  if (-not (Confirm-GimApplianceReachable -ApplianceHost $GimServerHost -AppliancePort $GimServerPort)) {
    throw "GIM service is running on $HostName, but it cannot reach the Guardium appliance at $GimServerHost`:$GimServerPort (TCP connect failed). Not reporting success - check gim_server_host, firewall, and network routing."
  }
  Log "Confirmed $HostName can reach Guardium appliance $GimServerHost`:$GimServerPort"
} else {

# Create remote directory
$remoteDir = "guardium_gim"
Log "Creating remote directory: $remoteDir"
try {
  Invoke-SSHCommand -Command "if (!(Test-Path `"$remoteDir`")) { New-Item -ItemType Directory -Force -Path `"$remoteDir`" | Out-Null }" -IgnoreErrors
} catch {
  Log "WARN: Could not create remote directory (may already exist): $_"
}

# Copy installer
Log "Copying installer to remote host..."
if ($setupPath -ne $InstallerDir) {
  # Copy the GIM-Installer-* subdirectory
  $setupDirName = Split-Path $setupPath -Leaf
  Copy-FileViaSSH -Source $setupPath -Destination "$remoteDir/"
  $remoteSetupDir = "$remoteDir/$setupDirName"
} else {
  # Copy entire installer directory contents
  $tempDir = Join-Path $env:TEMP "guardium_gim_copy_$(Get-Random)"
  New-Item -ItemType Directory -Force -Path $tempDir | Out-Null
  try {
    Copy-Item -Path "$InstallerDir\*" -Destination $tempDir -Recurse -Force
    Copy-FileViaSSH -Source "$tempDir\*" -Destination "$remoteDir/"
  } finally {
    Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
  }
  $remoteSetupDir = $remoteDir
}

# Get Windows host IP address (only when AutoAssignIP=0; IBM: do not specify both LOCALIP and AUTO_ASSIGN_IP)
$useAutoAssign = ($AutoAssignIP -eq "1")
if ($useAutoAssign) {
  Log "Using GIM_AUTO_SET_CLIENT_IP (auto_assign_ip=1); LOCALIP will be omitted per IBM requirement"
} elseif ([string]::IsNullOrWhiteSpace($LocalIP)) {
  Log "Getting Windows host IP address..."
  try {
    $ipCmd = "powershell -NoProfile -Command `"try { (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { `$_.IPAddress -notlike '127.*' -and `$_.IPAddress -notlike '169.254.*' }).IPAddress | Select-Object -First 1 } catch { [System.Net.Dns]::GetHostAddresses([System.Net.Dns]::GetHostName()) | Where-Object { `$_.AddressFamily -eq 'InterNetwork' -and `$_.ToString() -notlike '127.*'} | Select-Object -First 1 -ExpandProperty ToString }`""
    $LocalIP = (Invoke-SSHCommand -Command $ipCmd).ToString().Trim()
    if ([string]::IsNullOrWhiteSpace($LocalIP) -or $LocalIP -eq $HostName) {
      $LocalIP = $HostName
    }
  } catch {
    Log "WARN: Could not determine LOCALIP automatically, using hostname"
    $LocalIP = $HostName
  }
}
if (-not $useAutoAssign) { Log "Using LOCALIP: $LocalIP" }
if ($ListenerPort -gt 0) { Log "Listener port: $ListenerPort" } else { Log "Listener port: not enabled" }
if ([string]::IsNullOrWhiteSpace($FailoverGimServerHost) -eq $false) { Log "Failover GIM Server: $FailoverGimServerHost" }
if ([string]::IsNullOrWhiteSpace($SharedSecret) -eq $false) { Log "Shared secret: (set)" }

# Build base and optional argument blocks for remote script (runner-side). IBM: do not specify both LOCALIP and AUTO_ASSIGN_IP.
$gimHostEsc = $GimServerHost -replace "'", "''"
$installDirEsc = $InstallDir -replace "'", "''"
$baseArgsBlock = if ($useAutoAssign) {
  "  ``$args = @('-UNATTENDED', '-APPLIANCE', '$gimHostEsc', '-INSTALLPATH', '$installDirEsc');`n  ``$args += '-GIM_AUTO_SET_CLIENT_IP'; ``$args += '1';`n"
} else {
  $localIPEsc = $LocalIP -replace "'", "''"
  "  ``$args = @('-UNATTENDED', '-LOCALIP', '$localIPEsc', '-APPLIANCE', '$gimHostEsc', '-INSTALLPATH', '$installDirEsc');`n"
}
$listenerBlock = if ($ListenerPort -gt 0) { "  ``$args += '-LISTENER_PORT'; ``$args += '$ListenerPort';`n" } else { "" }
$failoverBlock = if ([string]::IsNullOrWhiteSpace($FailoverGimServerHost) -eq $false) {
  $f = $FailoverGimServerHost -replace "'", "''"
  "  ``$args += '-FAILOVER_APPLIANCE'; ``$args += '$f';`n"
} else { "" }
$sharedBlock = if ([string]::IsNullOrWhiteSpace($SharedSecret) -eq $false) {
  $s = $SharedSecret -replace "'", "''"
  "  ``$args += '-SHARED_SECRET'; ``$args += '$s';`n"
} else { "" }
$hasKey = [string]::IsNullOrWhiteSpace($GimKeyFile) -eq $false
$hasCert = [string]::IsNullOrWhiteSpace($GimCertFile) -eq $false
$hasCa = [string]::IsNullOrWhiteSpace($GimCaFile) -eq $false
$certBlock = ""
if ($hasKey -and $hasCert) {
  if (-not (Test-Path $GimKeyFile)) { throw "GimKeyFile not found on runner: $GimKeyFile" }
  if (-not (Test-Path $GimCertFile)) { throw "GimCertFile not found on runner: $GimCertFile" }
  if ($hasCa -and -not (Test-Path $GimCaFile)) { throw "GimCaFile not found on runner: $GimCaFile" }

  # GimKeyFile/GimCertFile/GimCaFile are paths on the Terraform runner - copy them to the target
  # before referencing them in the installer args (the installer runs on the target and cannot
  # read the runner's filesystem).
  $remoteCertsDir = "$remoteDir/certs"
  Log "Copying custom TLS certificate(s) to $HostName`:$remoteCertsDir"
  try {
    Invoke-SSHCommand -Command "New-Item -ItemType Directory -Force -Path `"$remoteCertsDir`" | Out-Null" -IgnoreErrors | Out-Null
  } catch {
    Log "WARN: Could not create remote certs directory (may already exist): $_"
  }

  $remoteKeyFile = "$remoteCertsDir/$([System.IO.Path]::GetFileName($GimKeyFile))"
  Copy-FileViaSSH -Source $GimKeyFile -Destination "$remoteCertsDir/"
  $remoteCertFile = "$remoteCertsDir/$([System.IO.Path]::GetFileName($GimCertFile))"
  Copy-FileViaSSH -Source $GimCertFile -Destination "$remoteCertsDir/"

  $k = $remoteKeyFile -replace "'", "''"
  $c = $remoteCertFile -replace "'", "''"
  $certBlock = "  ``$args += '-KEY_FILE'; ``$args += (Resolve-Path '$k').Path;`n  ``$args += '-CERT_FILE'; ``$args += (Resolve-Path '$c').Path;`n"
  if ($hasCa) {
    $remoteCaFile = "$remoteCertsDir/$([System.IO.Path]::GetFileName($GimCaFile))"
    Copy-FileViaSSH -Source $GimCaFile -Destination "$remoteCertsDir/"
    $ca = $remoteCaFile -replace "'", "''"
    $certBlock += "  ``$args += '-CA_FILE'; ``$args += (Resolve-Path '$ca').Path;`n"
  }
} elseif ($hasKey -or $hasCert -or $hasCa) {
  Log "WARN: Custom TLS requires both GimKeyFile and GimCertFile; omitting cert args"
}

# Run installer
$setupExeName = Split-Path $setup -Leaf
$remoteSetupExe = Join-Path $remoteSetupDir $setupExeName
Log "Running installer on remote host..."
Log "Installer path: $remoteSetupExe"
Log "Command: Setup.exe with args (secret not logged)"

$installCmd = @"
powershell -NoProfile -ExecutionPolicy Bypass -Command "
`$exe = Get-Item '$remoteSetupExe' -ErrorAction SilentlyContinue;
if (-not `$exe) {
  `$exe = Get-ChildItem -Path '$remoteSetupDir' -Filter 'Setup.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
};
if (-not `$exe) {
  `$exe = Get-ChildItem -Path '$remoteSetupDir' -Filter 'setup.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
};
if (-not `$exe) {
  `$exe = Get-ChildItem -Path '$remoteDir' -Filter '*.exe.signed' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
};
if (`$exe) {
  Write-Host 'Running installer: ' `$exe.FullName;
  $baseArgsBlock$listenerBlock$failoverBlock$sharedBlock$certBlock
  `$proc = Start-Process -FilePath (`$exe.FullName) -ArgumentList `$args -Wait -PassThru -NoNewWindow;
  Write-Host 'ExitCode:' `$proc.ExitCode;
  exit `$proc.ExitCode
} else {
  Write-Error 'Installer not found';
  exit 1
}
"
"@

try {
  $output = Invoke-SSHCommand -Command $installCmd
  Log $output

  # Extract exit code
  $exitCode = 1
  if ($output -match "ExitCode:\s*(\d+)") {
    $exitCode = [int]$matches[1]
  } elseif ($LASTEXITCODE -ne $null) {
    $exitCode = $LASTEXITCODE
  }

  if ($exitCode -ne 0) {
    throw "Installer failed with exit code: $exitCode"
  }

  Log "Installer completed successfully (exit code: $exitCode)"

  # Installer exit code 0 is not sufficient evidence of success on its own - confirm the GIM
  # service actually reached the Running state before reporting success.
  Log "Verifying GIM service is running on $HostName..."
  $svcCheck = Confirm-GimServiceRunning
  if (-not $svcCheck.Ok) {
    throw "Installer reported success (exit code 0) but the GIM service is not running on $HostName (status: $($svcCheck.Status)). Not reporting success."
  }
  Log "GIM service verified running on $HostName"

  Log "Verifying $HostName can reach Guardium appliance $GimServerHost`:$GimServerPort..."
  if (-not (Confirm-GimApplianceReachable -ApplianceHost $GimServerHost -AppliancePort $GimServerPort)) {
    throw "GIM service is running on $HostName, but it cannot reach the Guardium appliance at $GimServerHost`:$GimServerPort (TCP connect failed). Not reporting success - check gim_server_host, firewall, and network routing."
  }
  Log "Confirmed $HostName can reach Guardium appliance $GimServerHost`:$GimServerPort"
  Log "GIM installed and running at: $InstallDir"
} catch {
  Log "ERROR: Installation failed: $_"
  Log "Check installer logs on Windows host: C:\IBM Windows GIM.ctl"
  Log "Verify installer exists at: $remoteSetupExe"
  throw
}
}

# -----------------------------------------------------------
# Collect GIM client logs from the target back to the runner,
# best-effort (never fails the overall run).
# -----------------------------------------------------------
if ($CollectRemoteLogs -eq "true") {
  try {
    $targetLogDir = if ([string]::IsNullOrWhiteSpace($RemoteLogDir)) { Split-Path $LogFile -Parent } else { $RemoteLogDir }
    New-Item -ItemType Directory -Force -Path $targetLogDir | Out-Null
    $remoteFiles = @(
      "$InstallDir\modules\GIM\current\GIM.log",
      "$InstallDir\central_logger.log",
      "C:\IBM Windows GIM.ctl"
    )
    foreach ($rf in $remoteFiles) {
      $leaf = Split-Path $rf -Leaf
      $localDest = Join-Path $targetLogDir "$HostName-$leaf"
      $existsCmd = "powershell -NoProfile -Command `"if (Test-Path '$rf') { 'True' } else { 'False' }`""
      $existsOut = ""
      try { $existsOut = (Invoke-SSHCommand -Command $existsCmd -IgnoreErrors).ToString().Trim() } catch { $existsOut = "" }

      if ($existsOut -notmatch "True") {
        Log "Remote log not present (skipped): $rf"
        continue
      }

      # GIM may still have the file open (e.g. central_logger.log) right after the service
      # starts, so retry briefly rather than giving up on the first lock - but bounded, so a
      # file that's genuinely stuck locked doesn't stall the run.
      $copied = $false
      for ($attempt = 1; $attempt -le 4; $attempt++) {
        if (Copy-FileFromSSH -Source $rf -Destination $localDest) {
          $copied = $true
          break
        }
        if ($attempt -lt 4) { Start-Sleep -Seconds 5 }
      }
      if ($copied) {
        Log "Collected remote log: $rf -> $localDest"
      } else {
        Log "WARN: Failed to collect remote log $rf after 4 attempts (~15s)"
      }
    }
  } catch {
    Log "WARN: Log collection step failed: $_"
  }
}

Log "Completed"
