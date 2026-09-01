#
# Copyright (c) IBM Corp. 2026
# SPDX-License-Identifier: Apache-2.0
#

terraform {
  required_version = ">= 1.5.0"
}

locals {
  # Normalize line endings and strip lines that are blank or start with # (comments)
  _csv_raw   = replace(file(var.servers_csv_path), "\r\n", "\n")
  _csv_lines = split(local._csv_raw, "\n")
  servers_csv_cleaned = join("\n", [
    for line in local._csv_lines :
    line if trimspace(line) != "" && !startswith(trimspace(line), "#")
  ])
  # Use cleaned CSV if non-empty (e.g. after stripping comments); otherwise use raw so a comment-free CSV still works
  _csv_to_decode = trimspace(local.servers_csv_cleaned) != "" ? local.servers_csv_cleaned : local._csv_raw
  servers_raw    = csvdecode(local._csv_to_decode)

  # Listener port: when true, pass 8445; when false, do not pass (script will omit -ListenerPort)
  listener_port_arg = var.listener_port ? " -ListenerPort 8445" : ""

  windows_servers = {
    for s in local.servers_raw : s.name => {
      # gim_server_host from CSV only (required per server in servers.csv)
      gim_server_host = try(trimspace(try(s.gim_server_host, "")), "")
      # Ports are global (terraform.tfvars), not from CSV
      # install_dir from CSV or fallback
      install_dir = try(
        length(try(s.install_dir, "")) > 0 ? s.install_dir : try(var.windows_install_dir, "C:\\Program Files\\IBM\\Guardium Installation Manager"),
        "C:\\Program Files\\IBM\\Guardium Installation Manager"
      )
      name      = s.name
      os        = s.os
      host      = s.host
      mgmt_port = try(tonumber(s.mgmt_port), 5986)
      username  = s.username
      password  = s.password
      local_ip = try(
        length(try(s.local_ip, "")) > 0 ? s.local_ip : try(s.host, ""),
        try(s.host, "")
      )
      shared_secret            = try(trimspace(try(s.shared_secret, "")), "")
      failover_gim_server_host = try(trimspace(try(s.failover_gim_server_host, "")), "")
      gim_ca_file              = try(trimspace(try(s.gim_ca_file, "")), "")
      gim_key_file             = try(trimspace(try(s.gim_key_file, "")), "")
      gim_cert_file            = try(trimspace(try(s.gim_cert_file, "")), "")
      auto_assign_ip           = try(s.auto_assign_ip != "" ? s.auto_assign_ip : "0", "0")
      check_8443               = try(s.check_8443 != "" ? s.check_8443 : "TRUE", "TRUE")
      allow_tls_fallback       = try(s.allow_tls_fallback != "" ? s.allow_tls_fallback : "FALSE", "FALSE")
      # Per-server GIM kit version (optional). Empty means "use default_gim_kit_version / windows_gim_installer_dir".
      gim_kit_version = try(trimspace(try(s.gim_kit_version, "")), "")
    }
    if lower(trimspace(s.os)) == "windows"
  }

  # Optional args: only non-empty values are passed (no blank lines)
  failover_gim_server_args = {
    for k, v in local.windows_servers : k =>
    length(v.failover_gim_server_host) > 0 ? " -FailoverGimServerHost \"${v.failover_gim_server_host}\"" : ""
  }
  shared_secret_args = {
    for k, v in local.windows_servers : k =>
    length(v.shared_secret) > 0 ? " -SharedSecret \"${replace(v.shared_secret, "\"", "`\"")}\"" : ""
  }

  # ---------------------------------------------------------------------
  # Installer directory resolution
  #
  # Avoids hard-coding a version-specific path in terraform.tfvars (see
  # WINDOWS_DEPLOYMENT_OPTIONS.md): renaming/replacing the kit folder is
  # enough on its own, no tfvars edit required. Priority per server:
  #   1. gim_kit_version column in servers.csv
  #        -> <base>/Guardium_<version>_GIM_Windows
  #   2. default_gim_kit_version variable
  #        -> <base>/Guardium_<version>_GIM_Windows
  #   3. windows_gim_installer_dir variable (legacy, explicit full path)
  #   4. auto-detect the single Guardium_*_GIM_Windows folder under
  #      windows_gim_packages_base_dir
  # ---------------------------------------------------------------------
  _packages_base_dir = trimsuffix(var.windows_gim_packages_base_dir, "/")

  _auto_pkg_files     = try(fileset(var.windows_gim_packages_base_dir, "Guardium_*_GIM_Windows/**"), [])
  _auto_pkg_dirs      = distinct([for f in local._auto_pkg_files : split("/", f)[0]])
  _auto_installer_dir = length(local._auto_pkg_dirs) == 1 ? "${local._packages_base_dir}/${local._auto_pkg_dirs[0]}" : ""

  # Effective kit version label per server (for logging / version-check comparisons in the scripts)
  kit_version_for = {
    for k, s in local.windows_servers : k =>
    length(s.gim_kit_version) > 0 ? s.gim_kit_version : var.default_gim_kit_version
  }

  # gim_kit_version is matched as a substring against the available Guardium_*_GIM_Windows folder
  # names (case-insensitive), not an exact version format - so it works equally for a full version
  # (12.2.2.259), a fix-pack tag (12.x.p100_r120203321), or just a unique fragment of either
  # (e.g. r120203321). Must match exactly one folder; see the precondition below for ambiguous/
  # not-found handling.
  matched_pkg_dirs_for = {
    for k, v in local.kit_version_for : k => (
      v == "" ? [] : [for d in local._auto_pkg_dirs : d if strcontains(lower(d), lower(v))]
    )
  }

  installer_dir_for = {
    for k, s in local.windows_servers : k => (
      length(local.kit_version_for[k]) > 0
      ? (
        length(local.matched_pkg_dirs_for[k]) == 1
        ? "${local._packages_base_dir}/${local.matched_pkg_dirs_for[k][0]}"
        : ""
      )
      : length(var.windows_gim_installer_dir) > 0
      ? var.windows_gim_installer_dir
      : local._auto_installer_dir
    )
  }

  # Global deployment method, resolved once (also honors the legacy windows_use_ssh toggle)
  effective_deployment_method = (
    var.windows_deployment_method == "winrm" && var.windows_use_ssh
    ? "ssh"
    : var.windows_deployment_method
  )

  # ---------------------------------------------------------------------
  # Catch malformed IPv4-looking values before ever touching a target.
  #
  # gim_server_host / local_ip / failover_gim_server_host reach the installer
  # as -APPLIANCE / -LOCALIP / -FAILOVER_APPLIANCE. A typo like a missing dot
  # (e.g. "9.46194.103" instead of "9.46.194.103") is not a valid IPv4 address,
  # but the deployment scripts would still copy the installer, run Setup.exe,
  # and see the GIM service come up and stay Running - so "installed
  # successfully" would be reported even though the agent can never register
  # with the real appliance. A value only counts as "IPv4-shaped" (and is
  # checked) when every dot-separated segment is purely numeric; anything
  # else is assumed to be a hostname and is left alone.
  # ---------------------------------------------------------------------
  _ip_fields_for = {
    for k, s in local.windows_servers : k => [
      { name = "gim_server_host", value = s.gim_server_host },
      { name = "local_ip", value = s.local_ip },
      { name = "failover_gim_server_host", value = s.failover_gim_server_host },
    ]
  }

  _bad_ipv4_fields_for = {
    for k, fields in local._ip_fields_for : k => [
      for f in fields : "${f.name}=${f.value}"
      if(
        length(f.value) > 0
        && alltrue([for p in split(".", f.value) : can(regex("^[0-9]+$", p))])
        && (
          length(split(".", f.value)) != 4
          || anytrue([for p in split(".", f.value) : tonumber(p) > 255])
        )
      )
    ]
  }
}

############################
# WINDOWS – GIM
############################
resource "null_resource" "install_gim_windows" {
  for_each = var.install_windows_gim ? local.windows_servers : {}

  lifecycle {
    precondition {
      condition = (
        local.kit_version_for[each.key] == "" ||
        length(local.matched_pkg_dirs_for[each.key]) == 1
      )
      error_message = "gim_kit_version '${local.kit_version_for[each.key]}' for server '${each.key}' matched ${length(local.matched_pkg_dirs_for[each.key])} folder(s) under ${var.windows_gim_packages_base_dir} (expected exactly 1). Matched: [${join(", ", local.matched_pkg_dirs_for[each.key])}]. Available: [${join(", ", local._auto_pkg_dirs)}]. Use a value that uniquely identifies one folder."
    }
    precondition {
      condition     = length(local._bad_ipv4_fields_for[each.key]) == 0
      error_message = "Malformed IPv4-looking value(s) in servers.csv for server '${each.key}': ${join(", ", local._bad_ipv4_fields_for[each.key])}. Every segment is numeric but it isn't a valid IPv4 address (wrong number of segments, or an octet over 255) - check for a missing dot or other typo (e.g. '9.46194.103' is likely meant to be '9.46.194.103')."
    }
  }

  triggers = {
    host                     = each.value.host
    install_dir              = each.value.install_dir
    mgmt_port                = tostring(each.value.mgmt_port)
    username                 = each.value.username
    password                 = each.value.password
    gim_server_host          = each.value.gim_server_host
    gim_server_port          = tostring(var.gim_server_port)
    listener_port            = tostring(var.listener_port)
    failover_gim_server_host = try(each.value.failover_gim_server_host, "")
    shared_secret            = try(each.value.shared_secret, "")
    gim_ca_file              = try(each.value.gim_ca_file, "")
    gim_key_file             = try(each.value.gim_key_file, "")
    gim_cert_file            = try(each.value.gim_cert_file, "")
    auto_assign_ip           = try(each.value.auto_assign_ip, "0")
    gim_kit_version          = local.kit_version_for[each.key]
    installer_dir            = local.installer_dir_for[each.key]
    install_windows          = tostring(var.install_windows_gim)
    windows_use_ssh          = tostring(var.windows_use_ssh)
    deployment_method        = local.effective_deployment_method
    runner_log_dir           = var.runner_log_dir
    central_summary_csv_path = var.central_summary_csv_path
    uninstall_on_destroy     = tostring(var.uninstall_on_destroy)
    script_hash_ssh          = filesha256("${path.module}/../../scripts/windows/install_gim_windows_ssh.ps1")
    script_hash_winrm        = filesha256("${path.module}/../../scripts/windows/install_gim_windows.ps1")
    script_hash_smb          = filesha256("${path.module}/../../scripts/windows/install_gim_windows_smb.ps1")
  }

  provisioner "local-exec" {
    # Use PowerShell on Windows (always available)
    interpreter = ["powershell", "-Command"]
    command     = <<EOT
$ErrorActionPreference = "Stop"
$PSDefaultParameterValues['*:ErrorAction'] = 'Stop'

# Detect OS
$isWindows = $IsWindows -or $env:OS -eq "Windows_NT"

# Create logs directory
New-Item -ItemType Directory -Force -Path "${var.runner_log_dir}" | Out-Null
$LOG_FILE = "${var.runner_log_dir}/${each.key}.log"
$CENTRAL_SUMMARY_CSV = "${var.central_summary_csv_path}"
$INSTALLER_DIR_ABS = "${abspath(path.module)}/${replace(local.installer_dir_for[each.key], "./", "")}"
$REMOTE_LOG_DIR = "${var.runner_log_dir}/${each.key}"

# Determine deployment method (backward compatible with windows_use_ssh)
$deploymentMethod = "${local.effective_deployment_method}"

if ($deploymentMethod -eq "smb") {
  # SMB mode - uses file sharing + scheduled tasks (no SSH/WinRM required)
  $psExe = $null
  if (Get-Command pwsh -ErrorAction SilentlyContinue) {
    $psExe = "pwsh"
  } elseif (Get-Command powershell -ErrorAction SilentlyContinue) {
    $psExe = "powershell"
  } else {
    Write-Error "ERROR: PowerShell required for Windows GIM SMB installation."
    exit 1
  }

  # Use PowerShell SMB script. Ports from terraform.tfvars (global). Optional args only when set (no blank line when omitted).
  & $psExe -ExecutionPolicy Bypass -File "${path.module}/../../scripts/windows/install_gim_windows_smb.ps1" `
    -HostName "${each.value.host}" `
    -Username "${each.value.username}" `
    -Password "${each.value.password}" `
    -GimServerHost "${each.value.gim_server_host}" `
    -GimServerPort ${var.gim_server_port}${var.listener_port ? "   -ListenerPort 8445" : ""}${length(each.value.failover_gim_server_host) > 0 ? "   -FailoverGimServerHost \"${each.value.failover_gim_server_host}\"" : ""}${length(each.value.shared_secret) > 0 ? "   -SharedSecret \"${replace(each.value.shared_secret, "\"", "\\\"")}\"" : ""}${length(each.value.gim_ca_file) > 0 ? "   -GimCaFile \"${replace(each.value.gim_ca_file, "\"", "\\\"")}\"" : ""}${length(each.value.gim_key_file) > 0 ? "   -GimKeyFile \"${replace(each.value.gim_key_file, "\"", "\\\"")}\"" : ""}${length(each.value.gim_cert_file) > 0 ? "   -GimCertFile \"${replace(each.value.gim_cert_file, "\"", "\\\"")}\"" : ""} `
    -LocalIP "${each.value.local_ip}" `
    -AutoAssignIP "${each.value.auto_assign_ip}" `
    -InstallDir "${each.value.install_dir}" `
    -InstallerDir "$INSTALLER_DIR_ABS" `
    -LogFile "$LOG_FILE" `
    -CentralSummaryCsv "$CENTRAL_SUMMARY_CSV" `
    -Action install `
    -GimKitVersion "${local.kit_version_for[each.key]}" `
    -SkipIfAlreadyInstalled "${var.skip_if_already_installed ? "true" : "false"}" `
    -CollectRemoteLogs "${var.collect_remote_logs ? "true" : "false"}" `
    -RemoteLogDir "$REMOTE_LOG_DIR"

  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
} elseif ($deploymentMethod -eq "ssh") {
  # SSH mode - use PowerShell SSH script
  $psExe = $null
  if (Get-Command pwsh -ErrorAction SilentlyContinue) {
    $psExe = "pwsh"
  } elseif (Get-Command powershell -ErrorAction SilentlyContinue) {
    $psExe = "powershell"
  } else {
    Write-Error "ERROR: PowerShell required for Windows GIM SSH installation."
    exit 1
  }

  # Use PowerShell SSH script. Ports from terraform.tfvars (global). Optional args only when set.
  & $psExe -ExecutionPolicy Bypass -File "${path.module}/../../scripts/windows/install_gim_windows_ssh.ps1" `
    -HostName "${each.value.host}" `
    -Port ${each.value.mgmt_port} `
    -Username "${each.value.username}" `
    -Password "${each.value.password}" `
    -GimServerHost "${each.value.gim_server_host}" `
    -GimServerPort ${var.gim_server_port}${var.listener_port ? "   -ListenerPort 8445" : ""}${length(each.value.failover_gim_server_host) > 0 ? "   -FailoverGimServerHost \"${each.value.failover_gim_server_host}\"" : ""}${length(each.value.shared_secret) > 0 ? "   -SharedSecret \"${replace(each.value.shared_secret, "\"", "\\\"")}\"" : ""}${length(each.value.gim_ca_file) > 0 ? "   -GimCaFile \"${replace(each.value.gim_ca_file, "\"", "\\\"")}\"" : ""}${length(each.value.gim_key_file) > 0 ? "   -GimKeyFile \"${replace(each.value.gim_key_file, "\"", "\\\"")}\"" : ""}${length(each.value.gim_cert_file) > 0 ? "   -GimCertFile \"${replace(each.value.gim_cert_file, "\"", "\\\"")}\"" : ""} `
    -LocalIP "${each.value.local_ip}" `
    -AutoAssignIP "${each.value.auto_assign_ip}" `
    -InstallDir "${each.value.install_dir}" `
    -InstallerDir "$INSTALLER_DIR_ABS" `
    -LogFile "$LOG_FILE" `
    -CentralSummaryCsv "$CENTRAL_SUMMARY_CSV" `
    -Action install `
    -GimKitVersion "${local.kit_version_for[each.key]}" `
    -SkipIfAlreadyInstalled "${var.skip_if_already_installed ? "true" : "false"}" `
    -CollectRemoteLogs "${var.collect_remote_logs ? "true" : "false"}" `
    -RemoteLogDir "$REMOTE_LOG_DIR"

  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
} else {
  # WinRM mode - use PowerShell directly
  $psExe = $null
  if (Get-Command pwsh -ErrorAction SilentlyContinue) {
    $psExe = "pwsh"
  } elseif (Get-Command powershell -ErrorAction SilentlyContinue) {
    $psExe = "powershell"
  } else {
    Write-Error "ERROR: PowerShell required for Windows GIM (windows_deployment_method=winrm). Install PowerShell or use windows_deployment_method=smb."
    exit 1
  }

  # Bypass execution policy. Ports from terraform.tfvars (global). Optional args only when set.
  & $psExe -ExecutionPolicy Bypass -File "${path.module}/../../scripts/windows/install_gim_windows.ps1" `
    -HostName "${each.value.host}" `
    -Port ${each.value.mgmt_port} `
    -Username "${each.value.username}" `
    -Password "${each.value.password}" `
    -GimServerHost "${each.value.gim_server_host}" `
    -GimServerPort ${var.gim_server_port}${var.listener_port ? "   -ListenerPort 8445" : ""}${length(each.value.failover_gim_server_host) > 0 ? "   -FailoverGimServerHost \"${each.value.failover_gim_server_host}\"" : ""}${length(each.value.shared_secret) > 0 ? "   -SharedSecret \"${replace(each.value.shared_secret, "\"", "\\\"")}\"" : ""}${length(each.value.gim_ca_file) > 0 ? "   -GimCaFile \"${replace(each.value.gim_ca_file, "\"", "\\\"")}\"" : ""}${length(each.value.gim_key_file) > 0 ? "   -GimKeyFile \"${replace(each.value.gim_key_file, "\"", "\\\"")}\"" : ""}${length(each.value.gim_cert_file) > 0 ? "   -GimCertFile \"${replace(each.value.gim_cert_file, "\"", "\\\"")}\"" : ""} `
    -LocalIP "${each.value.local_ip}" `
    -AutoAssignIP "${each.value.auto_assign_ip}" `
    -InstallerDir "$INSTALLER_DIR_ABS" `
    -InstallDir "${each.value.install_dir}" `
    -Ports "${var.ports_to_check}" `
    -LogFile "$LOG_FILE" `
    -CentralSummaryCsv "$CENTRAL_SUMMARY_CSV" `
    -Action install `
    -GimKitVersion "${local.kit_version_for[each.key]}" `
    -SkipIfAlreadyInstalled "${var.skip_if_already_installed ? "true" : "false"}" `
    -CollectRemoteLogs "${var.collect_remote_logs ? "true" : "false"}" `
    -RemoteLogDir "$REMOTE_LOG_DIR"

  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
EOT
  }

  # ---------------------------------------------------------------------
  # Uninstall on `terraform destroy`
  #
  # IBM's documented procedure: locate the GIM_Installer* folder under the
  # install directory on the target and run its setup.exe -UNINSTALL. Runs
  # before the resource (and its triggers) are removed from state. Destroy
  # provisioners may only reference `self`, so everything needed here was
  # captured into `triggers` above at create time.
  # ---------------------------------------------------------------------
  provisioner "local-exec" {
    when        = destroy
    on_failure  = continue
    interpreter = ["powershell", "-Command"]
    command     = <<EOT
$ErrorActionPreference = "Stop"

if ("${self.triggers.uninstall_on_destroy}" -ne "true") {
  Write-Host "uninstall_on_destroy is false; leaving GIM installed on ${self.triggers.host}."
  exit 0
}

New-Item -ItemType Directory -Force -Path "${self.triggers.runner_log_dir}" | Out-Null
$LOG_FILE = "${self.triggers.runner_log_dir}/${each.key}-uninstall.log"
$CENTRAL_SUMMARY_CSV = "${self.triggers.central_summary_csv_path}"
$deploymentMethod = "${self.triggers.deployment_method}"

$psExe = $null
if (Get-Command pwsh -ErrorAction SilentlyContinue) {
  $psExe = "pwsh"
} elseif (Get-Command powershell -ErrorAction SilentlyContinue) {
  $psExe = "powershell"
} else {
  Write-Error "ERROR: PowerShell required to uninstall Windows GIM."
  exit 1
}

if ($deploymentMethod -eq "smb") {
  & $psExe -ExecutionPolicy Bypass -File "${path.module}/../../scripts/windows/install_gim_windows_smb.ps1" `
    -HostName "${self.triggers.host}" `
    -Username "${self.triggers.username}" `
    -Password "${self.triggers.password}" `
    -GimServerHost "${self.triggers.gim_server_host}" `
    -GimServerPort ${self.triggers.gim_server_port} `
    -InstallDir "${self.triggers.install_dir}" `
    -LogFile "$LOG_FILE" `
    -CentralSummaryCsv "$CENTRAL_SUMMARY_CSV" `
    -Action uninstall
} elseif ($deploymentMethod -eq "ssh") {
  & $psExe -ExecutionPolicy Bypass -File "${path.module}/../../scripts/windows/install_gim_windows_ssh.ps1" `
    -HostName "${self.triggers.host}" `
    -Port ${self.triggers.mgmt_port} `
    -Username "${self.triggers.username}" `
    -Password "${self.triggers.password}" `
    -GimServerHost "${self.triggers.gim_server_host}" `
    -GimServerPort ${self.triggers.gim_server_port} `
    -InstallDir "${self.triggers.install_dir}" `
    -LogFile "$LOG_FILE" `
    -CentralSummaryCsv "$CENTRAL_SUMMARY_CSV" `
    -Action uninstall
} else {
  & $psExe -ExecutionPolicy Bypass -File "${path.module}/../../scripts/windows/install_gim_windows.ps1" `
    -HostName "${self.triggers.host}" `
    -Port ${self.triggers.mgmt_port} `
    -Username "${self.triggers.username}" `
    -Password "${self.triggers.password}" `
    -GimServerHost "${self.triggers.gim_server_host}" `
    -GimServerPort ${self.triggers.gim_server_port} `
    -InstallDir "${self.triggers.install_dir}" `
    -LogFile "$LOG_FILE" `
    -CentralSummaryCsv "$CENTRAL_SUMMARY_CSV" `
    -Action uninstall
}

if ($LASTEXITCODE -ne 0) { Write-Warning "Uninstall on ${self.triggers.host} exited with code $LASTEXITCODE" }
EOT
  }
}
