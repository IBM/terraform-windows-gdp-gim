#!/usr/bin/env bash
#
# Copyright (c) IBM Corp. 2026
# SPDX-License-Identifier: Apache-2.0
#

param(
  [Parameter(Mandatory=$true)][string]$HostName,
  [int]$Port = 5986,
  [Parameter(Mandatory=$true)][string]$Username,
  [Parameter(Mandatory=$true)][string]$Password,
  [Parameter(Mandatory=$true)][string]$GimServerHost,
  [int]$GimServerPort = 8446,
  [string]$LocalIP = "",
  [string]$AutoAssignIP = "0",   # "1" = use GIM_AUTO_SET_CLIENT_IP (omit LOCALIP per IBM); "0" = use LOCALIP. Do not use both.
  [string]$InstallDir = "C:\Program Files\IBM\Guardium Installation Manager",
  [int]$ListenerPort = 0,       # 0 = listener not enabled; use 8445 when enabled
  [string]$SharedSecret = "",
  [string]$FailoverGimServerHost = "",
  [string]$GimCaFile = "",   # Optional: path on the Terraform runner to CA PEM; copied to the target automatically (for custom/listener TLS; optional for self-signed)
  [string]$GimKeyFile = "",  # Optional: path on the Terraform runner to private key PEM; copied to the target automatically (both key and cert required for custom TLS)
  [string]$GimCertFile = "", # Optional: path on the Terraform runner to certificate PEM; copied to the target automatically (both key and cert required for custom TLS)
  [string]$InstallerDir = "",  # Required for -Action install; not used for -Action uninstall
  [string]$Ports = "8446,8443",
  [switch]$InstallSTAP,
  [string]$StapInstallerDir = "",
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

function Log($msg) {
  $ts = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
  $line = "[$ts] $msg"
  $line | Tee-Object -FilePath $LogFile -Append | Out-Host
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
    $duration = if ($script:StartTime) {
      [math]::Round(((Get-Date) - $script:StartTime).TotalSeconds, 2)
    } else {
      0
    }

    # Ensure directory exists
    $csvDir = Split-Path -Path $CentralSummaryCsv -Parent
    if ($csvDir -and -not (Test-Path $csvDir)) {
      New-Item -ItemType Directory -Force -Path $csvDir | Out-Null
    }

    # Escape commas and quotes for CSV
    $escapedError = $ErrorMessage -replace '"', '""' -replace "`n", " " -replace "`r", ""
    if ($escapedError -match ',') {
      $escapedError = "`"$escapedError`""
    }

    $gimServer = "$GimServerHost`:$GimServerPort"
    $escapedGimServer = $gimServer -replace '"', '""'
    if ($escapedGimServer -match ',') {
      $escapedGimServer = "`"$escapedGimServer`""
    }

    $escapedInstallDir = $InstallDir -replace '"', '""'
    if ($escapedInstallDir -match ',') {
      $escapedInstallDir = "`"$escapedInstallDir`""
    }

    $csvLine = "$timestamp,$HostName,$Status,$escapedGimServer,$escapedInstallDir,$ListenerPort,$duration,$escapedError"

    # Multiple servers write to the same CentralSummaryCsv from separate, parallel PowerShell
    # processes (one per Terraform resource) - a machine-wide mutex prevents one host's write
    # from failing with "file in use by another process" when they collide.
    $mutex = New-Object System.Threading.Mutex($false, "Global\GuardiumCentralSummaryCsv")
    $acquired = $false
    try {
      $acquired = $mutex.WaitOne(10000)

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
    } finally {
      if ($acquired) { $mutex.ReleaseMutex() }
      $mutex.Dispose()
    }
  } catch {
    # Silently fail - don't break installation if CSV write fails
  }
}

# Reads the first line of a "gimver" marker file (format: "<version>\n<signed-kit-filename>").
# Used both locally (desired version, from the installer package) and remotely (installed version, from InstallDir).
function Read-VersionMarker {
  param([string]$Path)
  if (Test-Path $Path) {
    return (Get-Content $Path -TotalCount 1 -ErrorAction SilentlyContinue)
  }
  return ""
}

# Verifies the GIM Windows service (service name "GIM", display name "Guardium Installation
# Manager") is actually Running on the target - success is only reported once this is confirmed,
# not merely because the installer or a file copy returned exit code 0. Attempts one Start-Service
# if the service exists but is stopped, then polls briefly for the SCM to bring it up.
function Confirm-GimServiceRunning {
  param($Session)
  $maxAttempts = 5
  for ($i = 1; $i -le $maxAttempts; $i++) {
    $svc = Invoke-Command -Session $Session -ScriptBlock { Get-Service -Name "GIM" -ErrorAction SilentlyContinue }
    if ($svc -and $svc.Status.ToString() -eq "Running") {
      return @{ Ok = $true; Status = "Running" }
    }
    if ($svc -and $i -eq 1) {
      Log "GIM service found but not running (status: $($svc.Status)) - attempting Start-Service"
      Invoke-Command -Session $Session -ScriptBlock { Start-Service -Name "GIM" -ErrorAction SilentlyContinue }
    }
    Start-Sleep -Seconds 3
  }
  $svc = Invoke-Command -Session $Session -ScriptBlock { Get-Service -Name "GIM" -ErrorAction SilentlyContinue }
  return @{ Ok = $false; Status = if ($svc) { $svc.Status.ToString() } else { "NotFound" } }
}

# The GIM service can be Running yet still unable to register with Guardium (wrong/unreachable
# gim_server_host, firewall, appliance down) - that's a soft failure the installer itself doesn't
# surface as a bad exit code. Confirm the target can actually reach the appliance over TCP before
# treating the run as a real success.
function Confirm-GimApplianceReachable {
  param($Session, [string]$ApplianceHost, [int]$AppliancePort)
  try {
    return [bool](Invoke-Command -Session $Session -ScriptBlock {
      param($h, $p)
      try {
        $client = New-Object System.Net.Sockets.TcpClient
        $iar = $client.BeginConnect($h, $p, $null, $null)
        $ok = $iar.AsyncWaitHandle.WaitOne(5000) -and $client.Connected
        $client.Close()
        return $ok
      } catch {
        return $false
      }
    } -ArgumentList $ApplianceHost, $AppliancePort)
  } catch {
    return $false
  }
}

# Track start time for duration calculation
$script:StartTime = Get-Date

Log "Starting Windows GIM $Action"
Log "Target: $HostName"
if ($Action -eq "install") {
  Log "GIM server: $GimServerHost (port $GimServerPort)"
  if ($ListenerPort -gt 0) { Log "Listener port: $ListenerPort" } else { Log "Listener port: not enabled" }
  if ([string]::IsNullOrWhiteSpace($FailoverGimServerHost) -eq $false) { Log "Failover GIM Server: $FailoverGimServerHost" }
  if ([string]::IsNullOrWhiteSpace($SharedSecret) -eq $false) { Log "Shared secret: (set)" }
  if ([string]::IsNullOrWhiteSpace($GimKitVersion) -eq $false) { Log "Requested kit version: $GimKitVersion" }
}
Log "InstallDir: $InstallDir"
if ($InstallSTAP) {
  Log "InstallSTAP requested: true"
  Log "NOTE: Windows STAP installation is best-effort and may require environment-specific steps."
  if ([string]::IsNullOrWhiteSpace($StapInstallerDir)) {
    Log "WARN: InstallSTAP=true but StapInstallerDir not provided. STAP step will be skipped."
    $InstallSTAP = $false
  }
}

$session = $null
try {
  # WinRM session (TLS typically 5986). This script assumes the runner can reach WinRM.
  $sec = ConvertTo-SecureString $Password -AsPlainText -Force
  $cred = New-Object System.Management.Automation.PSCredential($Username, $sec)

  # -SkipRevocationCheck exists in PowerShell 6+; use try/catch for older pwsh or Windows PowerShell 5.1
  try {
    $so = New-PSSessionOption -SkipCACheck -SkipCNCheck -SkipRevocationCheck
  } catch {
    $so = New-PSSessionOption -SkipCACheck -SkipCNCheck
  }
  $uri = "https://$HostName`:$Port/wsman"
  Log "Connecting over WinRM: $uri"
  # -UseSSL is only valid with -ComputerName; with -ConnectionUri (https://) omit -UseSSL or parameter set fails
  $session = New-PSSession -ConnectionUri $uri -Credential $cred -Authentication Basic -SessionOption $so

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
    # Manager", despite IBM's docs calling the product that).
    # Falls back to a known fixed location the installer actually
    # uses (C:\Windows\$IBM Windows GIM$\Setup.exe, confirmed via a
    # live UninstallString - NOT under InstallDir), then to
    # searching InstallDir for a kept installer copy as a last
    # resort (folder naming varies - IBM's docs call it
    # "GIM_Installer*", the kit itself uses "GIM-Installer-*").
    # -----------------------------------------------------------
    Log "Locating GIM uninstaller on $HostName (registry, then known paths, then InstallDir)"
    $result = Invoke-Command -Session $session -ScriptBlock {
      param($installDir)

      $exePath = $null
      $uninstallRoots = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
      )
      $entry = Get-ItemProperty -Path $uninstallRoots -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like "*Guardium*" -or $_.Publisher -eq "IBM" } | Select-Object -First 1
      if ($entry) {
        $us = if ($entry.QuietUninstallString) { $entry.QuietUninstallString } else { $entry.UninstallString }
        if ($us -match '"([^"]+\.exe)"') { $exePath = $matches[1] }
        elseif ($us -match '^(\S+\.exe)') { $exePath = $matches[1] }
      }

      if (-not $exePath -or -not (Test-Path $exePath)) {
        $knownPath = 'C:\Windows\$IBM Windows GIM$\Setup.exe'
        if (Test-Path $knownPath) { $exePath = $knownPath }
      }

      if ((-not $exePath -or -not (Test-Path $exePath)) -and (Test-Path $installDir)) {
        $dir = Get-ChildItem -Path $installDir -Filter "GIM*Installer*" -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($dir) {
          $candidate = Join-Path $dir.FullName "setup.exe"
          if (-not (Test-Path $candidate)) { $candidate = Join-Path $dir.FullName "Setup.exe" }
          if (Test-Path $candidate) { $exePath = $candidate }
        }
        if (-not $exePath) {
          # Fallback: recursive search for any setup.exe under InstallDir (excluding modules/
          # which holds runtime files, not the installer)
          $found = Get-ChildItem -Path $installDir -Filter "*etup.exe" -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '\\modules\\' } | Select-Object -First 1
          if ($found) { $exePath = $found.FullName }
        }
      }

      if (-not $exePath -or -not (Test-Path $exePath)) {
        return [pscustomobject]@{ Found = $false; Reason = "No uninstaller found via registry, known paths, or InstallDir" }
      }
      $p = Start-Process -FilePath $exePath -ArgumentList "-UNINSTALL -UNATTENDED" -Wait -PassThru
      return [pscustomobject]@{ Found = $true; ExitCode = $p.ExitCode; Path = $exePath }
    } -ArgumentList $InstallDir

    if (-not $result.Found) {
      Log "WARN: Nothing to uninstall on $HostName ($($result.Reason)); GIM may already be removed."
      Write-CentralSummary -Status "UNINSTALL_SKIPPED" -ErrorMessage $result.Reason
    } else {
      Log "Ran uninstaller: $($result.Path) (exit code $($result.ExitCode))"
      if ($result.ExitCode -ne 0) {
        Write-CentralSummary -Status "UNINSTALL_FAILED" -ErrorMessage "Uninstaller exit code $($result.ExitCode)"
        throw "Uninstall failed with exit code $($result.ExitCode)"
      }
      Log "GIM uninstalled successfully from $HostName"
      Write-CentralSummary -Status "UNINSTALLED" -ErrorMessage ""
    }
    Log "Completed"
    return
  }

  if (-not (Test-Path $InstallerDir)) {
    throw "InstallerDir not found on runner: $InstallerDir (check windows_gim_packages_base_dir / gim_kit_version / windows_gim_installer_dir)"
  }
  # Prefer Setup.exe in GIM-Installer-* subdirectory (IBM standard structure)
  $setup = $null
  $gimInstallerDirs = Get-ChildItem -Path $InstallerDir -Filter "GIM-Installer-*" -Directory -ErrorAction SilentlyContinue
  foreach ($dir in $gimInstallerDirs) {
    $setupPath = Join-Path $dir.FullName "Setup.exe"
    if (Test-Path $setupPath) {
      $setup = $setupPath
      Log "Using installer: $setup"
      break
    }
  }
  # Fallback: setup.exe or Setup.exe in root
  if (-not $setup) {
    $setup = Join-Path $InstallerDir "Setup.exe"
    if (-not (Test-Path $setup)) {
      $setup = Join-Path $InstallerDir "setup.exe"
    }
  }
  # Fallback: guard-GIM-*.exe.signed in Gim-Kits (for consolidated installer approach)
  if (-not (Test-Path $setup)) {
    $signed = Get-ChildItem -Path $InstallerDir -Filter "*.exe.signed" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $signed) {
      $signed = Get-ChildItem -Path $InstallerDir -Filter "guard-GIM*.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    }
    if ($signed) {
      $setup = $signed.FullName
      Log "Using installer: $($signed.Name)"
    }
  }
  if (-not (Test-Path $setup)) {
    throw "Setup.exe, setup.exe, or guard-GIM-*.exe(.signed) not found in InstallerDir: $InstallerDir"
  }

  # -----------------------------------------------------------
  # Version check: compare the kit's own version marker (gimver,
  # shipped alongside Setup.exe) against the marker already on
  # the target (InstallDir\gimver). This reflects the real state
  # of the target host, not just Terraform state, so it still
  # works after state loss/drift (e.g. DR, migration).
  # -----------------------------------------------------------
  $setupDir = Split-Path $setup -Parent
  $desiredVersion = Read-VersionMarker (Join-Path $setupDir "Program Files\gimver")
  if ([string]::IsNullOrWhiteSpace($desiredVersion)) { $desiredVersion = $GimKitVersion }
  Log "Desired GIM kit version: $(if ([string]::IsNullOrWhiteSpace($desiredVersion)) { '(unknown)' } else { $desiredVersion })"

  $skipInstall = $false
  if (($SkipIfAlreadyInstalled -eq "true") -and (-not [string]::IsNullOrWhiteSpace($desiredVersion))) {
    try {
      $installedVersion = Invoke-Command -Session $session -ScriptBlock {
        param($d)
        $f = Join-Path $d "gimver"
        if (Test-Path $f) { Get-Content $f -TotalCount 1 -ErrorAction SilentlyContinue } else { "" }
      } -ArgumentList $InstallDir
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
    $svcCheck = Confirm-GimServiceRunning -Session $session
    if (-not $svcCheck.Ok) {
      Write-CentralSummary -Status "FAILED" -ErrorMessage "GIM already at desired version but service not running (status: $($svcCheck.Status))"
      throw "GIM is already at the desired version ($desiredVersion) on $HostName, but its service is not running (status: $($svcCheck.Status)). Not reporting success."
    }
    Log "GIM service verified running on $HostName"
    Log "Verifying $HostName can reach Guardium appliance $GimServerHost`:$GimServerPort..."
    if (-not (Confirm-GimApplianceReachable -Session $session -ApplianceHost $GimServerHost -AppliancePort $GimServerPort)) {
      Write-CentralSummary -Status "FAILED" -ErrorMessage "GIM service running but $HostName cannot reach Guardium appliance $GimServerHost`:$GimServerPort"
      throw "GIM service is running on $HostName, but it cannot reach the Guardium appliance at $GimServerHost`:$GimServerPort (TCP connect failed). Not reporting success - check gim_server_host, firewall, and network routing."
    }
    Log "Confirmed $HostName can reach Guardium appliance $GimServerHost`:$GimServerPort"
    Write-CentralSummary -Status "SKIPPED_ALREADY_INSTALLED" -ErrorMessage ""
  } else {

  $remoteDir = "C:\Windows\Temp\guardium_gim"
  Log "Creating remote directory: $remoteDir"
  Invoke-Command -Session $session -ScriptBlock { param($d) New-Item -ItemType Directory -Force -Path $d | Out-Null } -ArgumentList $remoteDir

  # Copy installer: if Setup.exe is in GIM-Installer-* subdirectory, copy that folder; otherwise copy all
  if ($setupDir -ne $InstallerDir) {
    $subDirName = Split-Path $setupDir -Leaf
    Log "Copying installer subdirectory: $subDirName"
    Copy-Item -ToSession $session -Path $setupDir -Destination $remoteDir -Recurse -Force
    $remoteSetup = Join-Path (Join-Path $remoteDir $subDirName) ([System.IO.Path]::GetFileName($setup))
  } else {
    Log "Copying installer payload to remote host"
    Copy-Item -ToSession $session -Path $InstallerDir\* -Destination $remoteDir -Recurse -Force
    $remoteSetup = Join-Path $remoteDir ([System.IO.Path]::GetFileName($setup))
  }

  # Get Windows host IP (required when AutoAssignIP=0; IBM: do not specify both LOCALIP and AUTO_ASSIGN_IP)
  $useAutoAssign = ($AutoAssignIP -eq "1")
  if ($useAutoAssign) {
    Log "Using GIM_AUTO_SET_CLIENT_IP (auto_assign_ip=1); LOCALIP will be omitted per IBM requirement"
  } else {
  if ([string]::IsNullOrWhiteSpace($LocalIP)) {
    Log "Getting Windows host IP address..."
    try {
      $LocalIP = Invoke-Command -Session $session -ScriptBlock {
        try {
          (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "169.254.*" }).IPAddress | Select-Object -First 1
        } catch {
          [System.Net.Dns]::GetHostAddresses([System.Net.Dns]::GetHostName()) | Where-Object { $_.AddressFamily -eq "InterNetwork" -and $_.ToString() -notlike "127.*" } | Select-Object -First 1 -ExpandProperty ToString
        }
      }
    } catch {
      Log "WARN: Could not determine LOCALIP automatically, using hostname"
      $LocalIP = $HostName
    }
  }
  Log "Using LOCALIP: $LocalIP"
  }

  # IBM documented format: setup.exe -UNATTENDED -LOCALIP <IP> -APPLIANCE <Appliance IP> -INSTALLPATH <path>
  # Optional: -LISTENER_PORT, -FAILOVER_APPLIANCE, -SHARED_SECRET. IBM: do not specify both LOCALIP and AUTO_ASSIGN_IP.
  $argLine = if ($useAutoAssign) {
    "-UNATTENDED -APPLIANCE `"$GimServerHost`" -INSTALLPATH `"$InstallDir`" -GIM_AUTO_SET_CLIENT_IP 1"
  } else {
    "-UNATTENDED -LOCALIP `"$LocalIP`" -APPLIANCE `"$GimServerHost`" -INSTALLPATH `"$InstallDir`""
  }
  if ($ListenerPort -gt 0) { $argLine += " -LISTENER_PORT $ListenerPort" }
  if ([string]::IsNullOrWhiteSpace($FailoverGimServerHost) -eq $false) { $argLine += " -FAILOVER_APPLIANCE `"$($FailoverGimServerHost -replace '"', '`"')`"" }
  if ([string]::IsNullOrWhiteSpace($SharedSecret) -eq $false) { $argLine += " -SHARED_SECRET `"$($SharedSecret -replace '"', '`"')`""; Log "Shared secret: (set)" }
  # Custom TLS certs: only when both key and cert are set. GimKeyFile/GimCertFile/GimCaFile are
  # paths on the Terraform runner - copy them to the target before referencing them in the
  # installer args (the installer runs on the target and cannot read the runner's filesystem).
  $hasKey = [string]::IsNullOrWhiteSpace($GimKeyFile) -eq $false
  $hasCert = [string]::IsNullOrWhiteSpace($GimCertFile) -eq $false
  $hasCa = [string]::IsNullOrWhiteSpace($GimCaFile) -eq $false
  if ($hasKey -and $hasCert) {
    if (-not (Test-Path $GimKeyFile)) { throw "GimKeyFile not found on runner: $GimKeyFile" }
    if (-not (Test-Path $GimCertFile)) { throw "GimCertFile not found on runner: $GimCertFile" }
    if ($hasCa -and -not (Test-Path $GimCaFile)) { throw "GimCaFile not found on runner: $GimCaFile" }

    $remoteCertDir = Join-Path $remoteDir "certs"
    Log "Copying custom TLS certificate(s) to $HostName`:$remoteCertDir"
    Invoke-Command -Session $session -ScriptBlock { param($d) New-Item -ItemType Directory -Force -Path $d | Out-Null } -ArgumentList $remoteCertDir

    $remoteKeyFile = Join-Path $remoteCertDir ([System.IO.Path]::GetFileName($GimKeyFile))
    Copy-Item -ToSession $session -Path $GimKeyFile -Destination $remoteKeyFile -Force
    $remoteCertFile = Join-Path $remoteCertDir ([System.IO.Path]::GetFileName($GimCertFile))
    Copy-Item -ToSession $session -Path $GimCertFile -Destination $remoteCertFile -Force

    $argLine += " -KEY_FILE `"$($remoteKeyFile -replace '"', '`"')`" -CERT_FILE `"$($remoteCertFile -replace '"', '`"')`""
    if ($hasCa) {
      $remoteCaFile = Join-Path $remoteCertDir ([System.IO.Path]::GetFileName($GimCaFile))
      Copy-Item -ToSession $session -Path $GimCaFile -Destination $remoteCaFile -Force
      $argLine += " -CA_FILE `"$($remoteCaFile -replace '"', '`"')`""
    }
  } elseif ($hasKey -or $hasCert -or $hasCa) {
    Log "WARN: Custom TLS requires both GimKeyFile and GimCertFile; omitting cert args"
  }
  Log "Executing installer: $remoteSetup (args: secret not logged)"

  $exitCode = Invoke-Command -Session $session -ScriptBlock {
    param($exe, $args)
    $p = Start-Process -FilePath $exe -ArgumentList $args -Wait -PassThru
    $p.ExitCode
  } -ArgumentList $remoteSetup, $argLine

  Log "Installer exit code: $exitCode"
  if ($exitCode -ne 0) {
    Write-CentralSummary -Status "FAILED" -ErrorMessage "Installer failed with exit code $exitCode"
    throw "Installer failed with exit code $exitCode"
  }

  # Installer exit code 0 is not sufficient evidence of success on its own - confirm the GIM
  # service actually reached the Running state before reporting success.
  Log "Verifying GIM service is running on $HostName..."
  $svcCheck = Confirm-GimServiceRunning -Session $session
  if (-not $svcCheck.Ok) {
    Write-CentralSummary -Status "FAILED" -ErrorMessage "Installer exited 0 but GIM service not running (status: $($svcCheck.Status))"
    throw "Installer reported success (exit code 0) but the GIM service is not running on $HostName (status: $($svcCheck.Status)). Not reporting success."
  }
  Log "GIM service verified running on $HostName"

  Log "Verifying $HostName can reach Guardium appliance $GimServerHost`:$GimServerPort..."
  if (-not (Confirm-GimApplianceReachable -Session $session -ApplianceHost $GimServerHost -AppliancePort $GimServerPort)) {
    Write-CentralSummary -Status "FAILED" -ErrorMessage "GIM service running but $HostName cannot reach Guardium appliance $GimServerHost`:$GimServerPort"
    throw "GIM service is running on $HostName, but it cannot reach the Guardium appliance at $GimServerHost`:$GimServerPort (TCP connect failed). Not reporting success - check gim_server_host, firewall, and network routing."
  }
  Log "Confirmed $HostName can reach Guardium appliance $GimServerHost`:$GimServerPort"

  if ($InstallSTAP) {
    Log "STAP step requested, but the exact Windows STAP deployment differs by IBM kit and environment."
    Log "Placeholder: provide your internal procedure and we can wire it in (GIM package import / deployment)."
  }

  # Write success to central summary CSV
  Write-CentralSummary -Status "SUCCESS" -ErrorMessage ""
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
        (Join-Path $InstallDir "modules\GIM\current\GIM.log"),
        (Join-Path $InstallDir "central_logger.log"),
        "C:\IBM Windows GIM.ctl"
      )
      foreach ($rf in $remoteFiles) {
        $leaf = Split-Path $rf -Leaf
        $localDest = Join-Path $targetLogDir "$HostName-$leaf"
        try {
          $exists = Invoke-Command -Session $session -ScriptBlock { param($p) Test-Path $p } -ArgumentList $rf
          if ($exists) {
            # GIM may still have the file open (e.g. central_logger.log) right after the service
            # starts, so retry briefly rather than giving up on the first lock - but bounded, so
            # a file that's genuinely stuck locked doesn't stall the run.
            $copied = $false
            $lastError = $null
            for ($attempt = 1; $attempt -le 4; $attempt++) {
              try {
                Copy-Item -FromSession $session -Path $rf -Destination $localDest -Force
                $copied = $true
                break
              } catch {
                $lastError = $_
                if ($attempt -lt 4) { Start-Sleep -Seconds 5 }
              }
            }
            if ($copied) {
              Log "Collected remote log: $rf -> $localDest"
            } else {
              Log "WARN: Failed to collect remote log $rf after 4 attempts (~15s): $lastError"
            }
          } else {
            Log "Remote log not present (skipped): $rf"
          }
        } catch {
          Log "WARN: Failed to collect remote log $rf : $_"
        }
      }
    } catch {
      Log "WARN: Log collection step failed: $_"
    }
  }

  Log "Completed"
} catch {
  # Write failure to central summary CSV
  Write-CentralSummary -Status "FAILED" -ErrorMessage $_.Exception.Message
  throw
} finally {
  if ($session) { Remove-PSSession $session }
}
