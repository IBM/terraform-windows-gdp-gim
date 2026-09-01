#
# Copyright (c) IBM Corp. 2026
# SPDX-License-Identifier: Apache-2.0
#

variable "servers_csv_path" {
  description = "Path to CSV inventory file describing servers to onboard."
  type        = string
  default     = "./inventory/servers.csv"
}

variable "runner_log_dir" {
  description = "Directory on the Terraform runner (local machine) where per-host logs are written."
  type        = string
  default     = "./logs"
}

variable "central_summary_csv_path" {
  description = "Path to central summary CSV file that tracks installation status of all servers. This file contains a consolidated view of all installation attempts with status (SUCCESS/FAILED), timestamps, and error messages. Default: ./logs/central-summary.csv"
  type        = string
  default     = "./logs/central-summary.csv"
}

variable "gim_server_port" {
  description = "Guardium management port for GIM. Configured globally in terraform.tfvars; applies to all servers. Always passed to the install script."
  type        = number
  default     = 8446
}

variable "listener_port" {
  description = "Enable GIM listener port. If true, the script is given listener port 8445 (--listener-port / -ListenerPort). If false, the option is not passed."
  type        = bool
  default     = false
}

variable "ports_to_check" {
  description = "Comma-separated list of ports to validate connectivity from target server to Guardium. Used by WinRM deployment method."
  type        = string
  default     = "8446,8443"
}

# Windows GIM
variable "windows_gim_installer_dir" {
  description = "Legacy/explicit path (on the Terraform runner) to the Windows GIM installer directory. Must contain setup.exe or a guard-GIM-*.exe.signed file. e.g. ./packages/windows/Guardium_12.2.1.205_GIM_Windows/Gim-Kits. Only used when gim_kit_version (per-server in servers.csv) and default_gim_kit_version are both unset; prefer those instead so upgrading the kit doesn't require editing this path."
  type        = string
  default     = ""
}

variable "windows_gim_packages_base_dir" {
  description = "Base directory (on the Terraform runner) containing versioned GIM installer package folders named Guardium_<version>_GIM_Windows (e.g. Guardium_12.2.1.205_GIM_Windows, Guardium_12.2.3.100_GIM_Windows). Combined with gim_kit_version (per server in servers.csv) or default_gim_kit_version to resolve the installer directory automatically - so bumping the kit version doesn't require editing terraform.tfvars, only dropping in the new versioned folder."
  type        = string
  default     = "./packages/windows"
}

variable "default_gim_kit_version" {
  description = "Default GIM kit identifier used to resolve the installer directory for any server row in servers.csv that doesn't set its own gim_kit_version column. Matched as a case-insensitive substring against Guardium_*_GIM_Windows folder names under windows_gim_packages_base_dir - e.g. a full version (12.2.1.205), a fix-pack tag (12.x.p100_r120203321), or a unique fragment (259). Must match exactly one folder. Leave empty to fall back to windows_gim_installer_dir, or to auto-detection when exactly one Guardium_*_GIM_Windows folder exists under windows_gim_packages_base_dir."
  type        = string
  default     = ""
}

variable "skip_if_already_installed" {
  description = "If true, before installing, each script checks the target host's own gimver marker file (under InstallDir) against the kit being deployed and skips re-running the installer when they already match - based on the real state of the target, not just Terraform state. Protects against unnecessary reinstalls (or missed reinstalls) after state loss/drift, e.g. following a migration or disaster recovery."
  type        = bool
  default     = true
}

variable "collect_remote_logs" {
  description = "If true, after installation the GIM client logs (modules/GIM/current/GIM.log, central_logger.log, and the installer's C:\\IBM Windows GIM.ctl) are copied from each target host back to runner_log_dir/ for troubleshooting."
  type        = bool
  default     = true
}

variable "uninstall_on_destroy" {
  description = "If true, running terraform destroy uninstalls GIM from each Windows target first (locates GIM_Installer* under InstallDir on the target and runs its setup.exe -UNINSTALL), per IBM's documented uninstall procedure. If false, destroy only removes the resource from Terraform state and leaves GIM installed."
  type        = bool
  default     = true
}

variable "windows_install_dir" {
  description = "Installation directory for Windows GIM. Default: C:\\Program Files\\IBM\\Guardium Installation Manager (IBM standard)"
  type        = string
  default     = "C:\\Program Files\\IBM\\Guardium Installation Manager"
}

variable "install_windows_gim" {
  description = "If true, install GIM on Windows hosts. If false, skip Windows installations entirely."
  type        = bool
  default     = true
}

variable "windows_use_ssh" {
  description = "If true, install Windows GIM via SSH (for runners without WinRM, e.g. macOS). Requires OpenSSH Server on the Windows host; set mgmt_port=22 for that server in CSV. If false, use WinRM (PowerShell); run Terraform from a Windows runner."
  type        = bool
  default     = false
}

variable "windows_deployment_method" {
  description = "Windows deployment method: 'winrm' (default, requires WinRM), 'ssh' (requires OpenSSH Server), or 'smb' (uses SMB file sharing + scheduled tasks, no SSH/WinRM required)."
  type        = string
  default     = "winrm"

  validation {
    condition     = contains(["winrm", "ssh", "smb"], var.windows_deployment_method)
    error_message = "windows_deployment_method must be 'winrm', 'ssh', or 'smb'."
  }
}
