# WinRM Troubleshooting Guide

If WinRM is failing, here are step-by-step instructions to fix it **without enabling SSH**.

## Quick Fix: Enable WinRM on Target Hosts

Run these commands **on each Windows target host**:

```powershell
# Enable WinRM service
Enable-PSRemoting -Force

# Configure WinRM for HTTPS (recommended, port 5986)
winrm quickconfig -transport:https

# Or configure for HTTP (less secure, port 5985)
# winrm quickconfig -transport:http

# Set authentication
winrm set winrm/config/service/auth '@{Basic="true"}'
winrm set winrm/config/service '@{AllowUnencrypted="false"}'

# Configure firewall rule
New-NetFirewallRule -DisplayName "WinRM HTTPS" -Direction Inbound -LocalPort 5986 -Protocol TCP -Action Allow
```

## Common WinRM Issues and Solutions

### Issue 1: "The client cannot connect to the destination"

**Symptoms:**
```
New-PSSession : [hostname] Connecting to remote server failed
The client cannot connect to the destination specified in the request.
```

**Solutions:**

1. **Check WinRM service is running:**
   ```powershell
   # On target host
   Get-Service WinRM
   Start-Service WinRM
   Set-Service -Name WinRM -StartupType Automatic
   ```

2. **Check firewall:**
   ```powershell
   # On target host
   Get-NetFirewallRule -DisplayName "*WinRM*"
   # If missing, add rule:
   New-NetFirewallRule -DisplayName "WinRM HTTPS" -Direction Inbound -LocalPort 5986 -Protocol TCP -Action Allow
   ```

3. **Verify WinRM listener:**
   ```powershell
   # On target host
   winrm enumerate winrm/config/Listener
   # Should show HTTPS listener on port 5986
   ```

4. **Test connectivity from runner:**
   ```powershell
   # From Terraform runner
   Test-WSMan -ComputerName hostname -Port 5986
   ```

### Issue 2: "Access Denied" or Authentication Failures

**Solutions:**

1. **Enable Basic authentication (if using password):**
   ```powershell
   # On target host
   winrm set winrm/config/service/auth '@{Basic="true"}'
   ```

2. **Add runner to TrustedHosts (if using IP address):**
   ```powershell
   # On target host
   winrm set winrm/config/client '@{TrustedHosts="runner-ip-address"}'
   ```

3. **Check user permissions:**
   ```powershell
   # On target host - ensure user is in Remote Management Users group
   Add-LocalGroupMember -Group "Remote Management Users" -Member "username"
   ```

### Issue 3: Certificate/SSL Errors

**Solutions:**

1. **Skip certificate validation (for testing):**
   - The script already uses `-SkipCACheck -SkipCNCheck` for this
   - For production, configure proper certificates

2. **Configure self-signed certificate:**
   ```powershell
   # On target host
   $cert = New-SelfSignedCertificate -DnsName hostname -CertStoreLocation Cert:\LocalMachine\My
   winrm create winrm/config/Listener?Address=*+Transport=HTTPS '@{Hostname="hostname";CertificateThumbprint="' + $cert.Thumbprint + '"}'
   ```

### Issue 4: WinRM Not Available (Windows Server Core, older versions)

**Solutions:**

1. **Install WinRM feature:**
   ```powershell
   # On target host
   Install-WindowsFeature -Name WinRM-IIS-Ext
   ```

2. **Use SMB deployment method instead:**
   ```hcl
   # In terraform.tfvars
   windows_deployment_method = "smb"
   ```

## Alternative: Use SMB Deployment (No WinRM Required)

If you cannot enable WinRM, use the SMB deployment method:

```hcl
# In terraform.tfvars
windows_deployment_method = "smb"
```

**Requirements:**
- File and Printer Sharing enabled on target hosts
- Network access to admin shares (C$)
- Credentials with local admin rights

**How it works:**
1. Copies installer files via SMB/CIFS (\\hostname\C$\...)
2. Creates a scheduled task on the target host
3. Runs installer locally via scheduled task
4. No SSH or WinRM required

## Testing WinRM Connectivity

**From Terraform runner:**

```powershell
# Test WinRM HTTPS
Test-WSMan -ComputerName hostname -Port 5986

# Test PowerShell remoting
$cred = Get-Credential
Invoke-Command -ComputerName hostname -Credential $cred -ScriptBlock { "Hello from $env:COMPUTERNAME" }
```

**From target host:**

```powershell
# Check WinRM configuration
winrm get winrm/config

# Check listeners
winrm enumerate winrm/config/Listener

# Check service status
Get-Service WinRM
```

## Security Best Practices

1. **Use HTTPS (port 5986) instead of HTTP (port 5985)**
2. **Restrict firewall rules to specific source IPs:**
   ```powershell
   New-NetFirewallRule -DisplayName "WinRM HTTPS" -Direction Inbound -LocalPort 5986 -Protocol TCP -Action Allow -RemoteAddress "runner-ip-address"
   ```
3. **Use certificate-based authentication when possible**
4. **Limit Remote Management Users group membership**
5. **Consider using Group Policy for centralized WinRM configuration**

## Still Having Issues?

If WinRM still doesn't work after troubleshooting:

1. **Use SMB deployment method** (no WinRM required):
   ```hcl
   windows_deployment_method = "smb"
   ```

2. **Check Windows Event Logs:**
   ```powershell
   # On target host
   Get-WinEvent -LogName Microsoft-Windows-WinRM/Operational | Select-Object -First 20
   ```

3. **Verify network connectivity:**
   ```powershell
   # From runner
   Test-NetConnection -ComputerName hostname -Port 5986
   ```
