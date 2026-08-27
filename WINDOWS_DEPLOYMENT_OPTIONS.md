# Windows Deployment Options

When WinRM is not available or fails, you have several options to deploy GIM to Windows hosts using existing Windows tools.

## Option 0: Fix WinRM (Recommended - Most Secure)

**Best for:** Windows-to-Windows deployments when you can configure target hosts

**Requirements:**
- WinRM service enabled on target Windows hosts
- Firewall rules allowing port 5986 (HTTPS) or 5985 (HTTP)

**Setup:** See [WINRM_TROUBLESHOOTING.md](WINRM_TROUBLESHOOTING.md) for detailed instructions.

**Quick fix on target hosts:**
```powershell
Enable-PSRemoting -Force
winrm quickconfig -transport:https
New-NetFirewallRule -DisplayName "WinRM HTTPS" -Direction Inbound -LocalPort 5986 -Protocol TCP -Action Allow
```

**Configuration:**
```hcl
windows_deployment_method = "winrm"  # Default
```

## Option 1: SMB/CIFS File Sharing + Scheduled Tasks (No SSH/WinRM Required) ⭐ RECOMMENDED

**Best for:** When you cannot enable SSH or WinRM on Windows servers

**Requirements:**
- File and Printer Sharing enabled on target Windows hosts (usually enabled by default)
- Network access to admin shares (C$)
- Credentials with local admin rights
- PowerShell 5.1+ on runner

**Advantages:**
- ✅ **No SSH required** - Servers remain secure
- ✅ **No WinRM required** - Works even if WinRM is disabled
- ✅ Uses standard Windows file sharing (SMB/CIFS)
- ✅ Uses Windows Scheduled Tasks (built-in)
- ✅ No additional ports to open

**Setup:**

1. **Enable SMB mode in `terraform.tfvars`:**
   ```hcl
   windows_deployment_method = "smb"
   ```

2. **Ensure File and Printer Sharing is enabled on target hosts:**
   ```powershell
   # On target host (usually already enabled)
   Get-NetFirewallRule -DisplayGroup "File and Printer Sharing" | Enable-NetFirewallRule
   ```

3. **Run Terraform:**
   ```powershell
   terraform apply
   ```

**How it works:**
1. Maps network drive to target host's C$ admin share
2. Copies installer files via SMB to `C:\Windows\Temp\guardium_gim`
3. Creates a PowerShell script on target host
4. Creates a scheduled task to run the installer locally
5. Executes task and monitors completion
6. Cleans up task and disconnects drive

**Security Notes:**
- Uses Windows admin shares (C$) - standard Windows feature
- Files are copied to temporary directory
- Scheduled task runs with provided credentials
- No SSH or WinRM ports need to be opened
- Task is automatically cleaned up after execution

## Option 2: SSH Mode with PowerShell Script

**Best for:** Windows runners when WinRM is unavailable

**Requirements:**
- PowerShell 5.1+ (built-in on Windows 10/11)
- OpenSSH Server installed on Windows target hosts
- **Authentication:** SSH key (preferred) OR PuTTY tools (Plink/PSCP)

**Setup:**

1. **Enable SSH mode in `terraform.tfvars`:**
   ```hcl
   windows_use_ssh = true
   ```

2. **In your `servers.csv`, set Windows hosts to use SSH port:**
   ```csv
   name,os,host,mgmt_port,username,password,...
   poc-windows2025,windows,poc-windows2025.dev.fyre.ibm.com,22,Administrator,Welcome2Guardium!,...
   ```

3. **Choose authentication method:**

   **Option A: SSH Key (Recommended)**
   ```powershell
   # Generate SSH key if you don't have one
   ssh-keygen -t rsa -b 4096
   
   # Copy public key to Windows host
   type $env:USERPROFILE\.ssh\id_rsa.pub | ssh Administrator@hostname "powershell -Command `"New-Item -ItemType Directory -Force -Path `$env:USERPROFILE\.ssh | Out-Null; Add-Content -Path `$env:USERPROFILE\.ssh\authorized_keys -Value (Get-Content stdin)`""
   
   # Update Terraform to use SSH key (modify examples/basic/main.tf provisioner)
   # Add: -SshKeyPath "$env:USERPROFILE\.ssh\id_rsa"
   ```

   **Option B: PuTTY Tools (Password Authentication)**
   ```powershell
   # Install PuTTY (includes plink.exe and pscp.exe)
   choco install putty
   # Or download from: https://www.putty.org/
   ```

4. **Run Terraform:**
   ```powershell
   terraform apply
   ```

**How it works:**
- Uses PowerShell script `install_gim_windows_ssh.ps1` (no bash required)
- Automatically detects and uses SSH keys or PuTTY tools
- Works with Windows built-in SSH client

## Option 3: Fix WinRM (If Possible)

**Best for:** Windows-to-Windows deployments when you can configure target hosts

**Requirements:**
- WinRM service enabled on target Windows hosts
- Firewall rules allowing port 5986 (HTTPS) or 5985 (HTTP)

**Setup on Target Windows Hosts:**

```powershell
# Run on each Windows target host
winrm quickconfig
winrm set winrm/config/service/auth '@{Basic="true"}'
winrm set winrm/config/service '@{AllowUnencrypted="false"}'

# For HTTPS (recommended)
winrm create winrm/config/Listener?Address=*+Transport=HTTPS '@{Hostname="hostname";CertificateThumbprint="thumbprint"}'

# Or for HTTP (less secure)
winrm set winrm/config/service '@{AllowUnencrypted="true"}'
```

**Then use WinRM mode:**
```hcl
windows_use_ssh = false  # Default
```

## Option 4: Use Linux/macOS Runner with SSH

**Best for:** When you have access to a Linux/macOS machine

**Requirements:**
- Linux/macOS machine with Terraform
- OpenSSH Server on Windows target hosts
- Bash shell (default on Linux/macOS)

**Setup:**

1. **Enable SSH mode:**
   ```hcl
   windows_use_ssh = true
   ```

2. **Run from Linux/macOS:**
   ```bash
   terraform apply
   ```

**How it works:**
- Uses bash script `install_gim_windows_ssh.sh`
- Requires `sshpass` for password authentication (or use SSH keys)

## Comparison

| Option | Runner OS | Target Auth | Tools Required | SSH Required | WinRM Required |
|-------|-----------|-------------|-----------------|--------------|----------------|
| **Option 0: WinRM** | Windows | WinRM | PowerShell | ❌ No | ✅ Yes |
| **Option 1: SMB** ⭐ | Windows | SMB/CIFS | PowerShell | ❌ No | ❌ No |
| **Option 2: PowerShell SSH** | Windows | SSH Key or PuTTY | PowerShell, SSH client | ✅ Yes | ❌ No |
| **Option 4: Bash SSH** | Linux/macOS | SSH Key or sshpass | Bash, sshpass | ✅ Yes | ❌ No |

## Troubleshooting

### "Password authentication requires Plink.exe (PuTTY) or SSH key"

**Solution:** Install PuTTY or use SSH keys:
```powershell
# Install PuTTY
choco install putty

# Or set up SSH key
ssh-keygen -t rsa -b 4096
ssh-copy-id Administrator@hostname
```

### "The client cannot connect to the destination specified in the request"

**Cause:** WinRM is not configured on target host.

**Solution:** Use SSH mode (`windows_use_ssh = true`) or configure WinRM on target hosts.

### "bash not found" (when using SSH mode on Windows)

**Solution:** This error should no longer occur with the PowerShell SSH script. If you see it, ensure you're using the updated `examples/basic/main.tf` that uses `install_gim_windows_ssh.ps1`.

## Quick Start: Use SMB Mode (No SSH/WinRM Required) ⭐

1. Edit `examples/basic/terraform.tfvars`:
   ```hcl
   windows_deployment_method = "smb"
   ```

2. Ensure File and Printer Sharing is enabled on target hosts (usually already enabled):
   ```powershell
   # On Windows target host (if needed)
   Get-NetFirewallRule -DisplayGroup "File and Printer Sharing" | Enable-NetFirewallRule
   ```

3. Run Terraform:
   ```powershell
   terraform apply
   ```

The SMB script will:
- Map network drive to target host
- Copy installer files via SMB
- Create and run scheduled task
- Monitor installation
- Clean up automatically

**No SSH or WinRM required!**

## Alternative: Quick Start for SSH Mode

If you prefer SSH mode:

1. Edit `examples/basic/terraform.tfvars`:
   ```hcl
   windows_deployment_method = "ssh"
   ```

2. Update `servers.csv` - change Windows hosts `mgmt_port` from `5986` to `22`

3. Ensure OpenSSH Server is installed on Windows targets:
   ```powershell
   # On Windows target host
   Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
   Start-Service sshd
   Set-Service -Name sshd -StartupType 'Automatic'
   ```

4. Run Terraform:
   ```powershell
   terraform apply
   ```

The PowerShell SSH script will automatically use SSH keys if available, or fall back to PuTTY tools if installed.
