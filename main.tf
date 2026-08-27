#
# Copyright (c) IBM Corp. 2026
# SPDX-License-Identifier: Apache-2.0
#

locals {
  csv_lines_raw = [
    for l in split("\n", trimspace(file(var.inventory_csv_path))) :
    trimspace(l) if trimspace(l) != ""
  ]

  header_raw = [for h in split(",", local.csv_lines_raw[0]) : trimspace(h)]

  # Normalize header names (handles Excel/Windows BOM and case)
  header = [
    for h in local.header_raw :
    replace(lower(trimspace(h)), "\ufeff", "")
  ]

  rows = [
    for r in slice(local.csv_lines_raw, 1, length(local.csv_lines_raw)) :
    [
      for c in split(",", r) :
      (
        # Trim and strip optional surrounding double-quotes (common in CSV exports)
        # Implemented without regexreplace for compatibility.
        (
          startswith(trimspace(c), "\"") && endswith(trimspace(c), "\"") && length(trimspace(c)) >= 2
        )
        ? trimsuffix(trimprefix(trimspace(c), "\""), "\"")
        : trimspace(c)
      )
    ]
  ]
  idx = { for i, v in local.header : v => i }

  # Full schema supported (empty values use defaults):
  # Required columns:
  #   name, os, host, mgmt_port, username, password, gim_server_host, gim_server_port, local_ip
  # Optional columns:
  #   install_dir, listener_port, shared_secret, failover_gim_server_host,
  #   auto_assign_ip, check_8443, allow_tls_fallback
  # Note: Only Windows OS is supported

  servers = {
    for r in local.rows :
    r[local.idx["name"]] => {
      name = r[local.idx["name"]]
      os   = lower(r[local.idx["os"]])
      host = r[local.idx["host"]]

      mgmt_port = tonumber(
        (
          (contains(keys(local.idx), "mgmt_port") && r[local.idx["mgmt_port"]] != "")
          ? r[local.idx["mgmt_port"]]
          : "5986"
        )
      )

      username = r[local.idx["username"]]
      password = r[local.idx["password"]]

      gim_server_host = try(r[local.idx["gim_server_host"]], "")

      gim_server_port = tonumber(
        (
          (contains(keys(local.idx), "gim_server_port") && r[local.idx["gim_server_port"]] != "")
          ? r[local.idx["gim_server_port"]]
          : "8446"
        )
      )

      local_ip = try(
        (contains(keys(local.idx), "local_ip") && try(r[local.idx["local_ip"]], "") != "")
        ? r[local.idx["local_ip"]]
        : r[local.idx["host"]],
        r[local.idx["host"]]
      )

      install_dir = try(
        (contains(keys(local.idx), "install_dir") && try(r[local.idx["install_dir"]], "") != "")
        ? r[local.idx["install_dir"]]
        : "C:\\Program Files\\IBM\\Guardium Installation Manager",
        "C:\\Program Files\\IBM\\Guardium Installation Manager"
      )

      listener_port = tonumber(
        (
          (contains(keys(local.idx), "listener_port") && try(r[local.idx["listener_port"]], "") != "")
          ? r[local.idx["listener_port"]]
          : "8445"
        )
      )

      shared_secret = (
        (contains(keys(local.idx), "shared_secret") && r[local.idx["shared_secret"]] != "")
        ? r[local.idx["shared_secret"]]
        : ""
      )

      failover_gim_server_host = (
        (contains(keys(local.idx), "failover_gim_server_host") && r[local.idx["failover_gim_server_host"]] != "")
        ? r[local.idx["failover_gim_server_host"]]
        : ""
      )

      auto_assign_ip = (
        (contains(keys(local.idx), "auto_assign_ip") && r[local.idx["auto_assign_ip"]] != "")
        ? lower(r[local.idx["auto_assign_ip"]])
        : "0"
      )

      check_8443 = (
        (contains(keys(local.idx), "check_8443") && r[local.idx["check_8443"]] != "")
        ? lower(r[local.idx["check_8443"]])
        : "true"
      )

      allow_tls_fallback = (
        (contains(keys(local.idx), "allow_tls_fallback") && r[local.idx["allow_tls_fallback"]] != "")
        ? lower(r[local.idx["allow_tls_fallback"]])
        : "false"
      )
    }
  }

  # Only Windows servers are supported
  is_win = { for k, s in local.servers : k => s.os == "windows" }

  # Avoid null-in-template issues; empty string means "not provided"
  win_installer_dir = var.windows_gim_installer_dir == null ? "" : var.windows_gim_installer_dir

  # Optional STAP for Windows (best effort / placeholder)
  win_stap_dir = var.windows_stap_installer_dir == null ? "" : var.windows_stap_installer_dir
}

resource "null_resource" "install_gim_windows" {
  for_each = { for k, s in local.servers : k => s if local.is_win[k] }

  triggers = {
    host            = each.value.host
    username        = each.value.username
    gim_server_host = each.value.gim_server_host
    installer_dir   = var.windows_gim_installer_dir == null ? "null" : var.windows_gim_installer_dir
    stap_enabled    = tostring(var.install_stap)
    stap_dir        = var.windows_stap_installer_dir == null ? "null" : var.windows_stap_installer_dir
  }

  provisioner "local-exec" {
    # Use PowerShell (Windows PowerShell or PowerShell Core/pwsh)
    interpreter = ["powershell", "-Command"]
    command = <<EOT
$ErrorActionPreference = "Stop"
$PSDefaultParameterValues['*:ErrorAction'] = 'Stop'

# Detect OS
$isWindows = $IsWindows -or $env:OS -eq "Windows_NT"

# Create logs directory
New-Item -ItemType Directory -Force -Path "${var.runner_log_dir}" | Out-Null
$LOG_FILE = "${var.runner_log_dir}/${each.key}.log"

# Find PowerShell executable
$psExe = $null
if ($isWindows) {
  if (Get-Command pwsh -ErrorAction SilentlyContinue) {
    $psExe = "pwsh"
  } elseif (Get-Command powershell -ErrorAction SilentlyContinue) {
    $psExe = "powershell"
  } else {
    Write-Error "ERROR: PowerShell required for Windows GIM installation."
    exit 1
  }
} else {
  # Non-Windows runner - use PowerShell Core (pwsh)
  if (Get-Command pwsh -ErrorAction SilentlyContinue) {
    $psExe = "pwsh"
  } else {
    Write-Error "ERROR: PowerShell Core (pwsh) required for Windows GIM installation. Install pwsh or run Terraform from Windows."
    exit 1
  }
}

# Execute PowerShell script with execution policy bypass
& $psExe -ExecutionPolicy Bypass -File "${path.module}/scripts/windows/install_gim_windows.ps1" `
  -HostName "${each.value.host}" `
  -Port "${each.value.mgmt_port}" `
  -Username "${each.value.username}" `
  -Password "${each.value.password}" `
  -GimServerHost "${each.value.gim_server_host}" `
  -GimServerPort "${each.value.gim_server_port}" `
  -LocalIP "${each.value.local_ip}" `
  -InstallDir "${each.value.install_dir}" `
  -ListenerPort "${each.value.listener_port}" `
  -SharedSecret "${each.value.shared_secret}" `
  -InstallerDir "${local.win_installer_dir}" `
  -Ports "${join(",", var.gim_ports)}" `
  -InstallSTAP ${var.install_stap} `
  -StapInstallerDir "${local.win_stap_dir}" `
  -LogFile "$LOG_FILE"

if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
EOT
  }
}
