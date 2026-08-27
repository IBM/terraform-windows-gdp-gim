#
# Copyright (c) IBM Corp. 2026
# SPDX-License-Identifier: Apache-2.0
#

output "parsed_servers" {
  description = "Inventory parsed from CSV (sanitized: password omitted). Useful for debugging."
  value = {
    for k, s in local.servers : k => {
      name                      = s.name
      os                        = s.os
      host                      = s.host
      mgmt_port                 = s.mgmt_port
      username                  = s.username
      gim_server_host           = s.gim_server_host
      gim_server_port           = s.gim_server_port
      local_ip                  = s.local_ip
      install_dir               = s.install_dir
      listener_port             = s.listener_port
      shared_secret_set         = (s.shared_secret != "")
      failover_gim_server_host  = s.failover_gim_server_host
      auto_assign_ip            = s.auto_assign_ip
      check_8443                = s.check_8443
      allow_tls_fallback        = s.allow_tls_fallback
    }
  }
  sensitive = false
}

output "log_directory" {
  description = "Directory on the Terraform runner where per-host logs are written."
  value       = var.runner_log_dir
}
