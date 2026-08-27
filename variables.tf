#
# Copyright (c) IBM Corp. 2026
# SPDX-License-Identifier: Apache-2.0
#

variable "inventory_csv_path" {
  description = "Path to servers.csv inventory file."
  type        = string
}

variable "runner_log_dir" {
  description = "Directory on the Terraform runner where per-host logs will be written."
  type        = string
  default     = "./logs"
}

variable "gim_ports" {
  description = "Ports to validate from target server to Guardium appliance (typical: 8446 and optionally 8443/8445)."
  type        = list(number)
  default     = [8446, 8443]
}

variable "install_stap" {
  description = "If true, also install S-TAP (requires STAP installer paths)."
  type        = bool
  default     = false
}

# -----------------------------
# Windows installers
# -----------------------------
variable "windows_gim_installer_dir" {
  description = "Directory on the Terraform runner containing the extracted Windows GIM installer (must include setup.exe)."
  type        = string
  default     = null
}

variable "windows_stap_installer_dir" {
  description = "Optional directory on the Terraform runner containing the extracted Windows STAP installer kit (best-effort support)."
  type        = string
  default     = null
}
