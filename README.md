# Terraform: IBM Guardium GIM Installation Automation

This project automates the installation of IBM Guardium **GIM (Guardium Installation Manager)** agents on remote Windows servers using Terraform. It supports multiple deployment methods: SMB (recommended), WinRM, or SSH.

## Table of Contents

- [Overview](#overview)
- [Features](#features)
- [Prerequisites](#prerequisites)
- [Installing Terraform](#installing-terraform)
- [Platform Differences](#platform-differences)
- [Quick Start](#quick-start)
- [Configuration](#configuration)
- [Usage](#usage)
- [Architecture](#architecture)
- [Troubleshooting](#troubleshooting)
- [Security Notes](#security-notes)

## Overview

This Terraform module automates the deployment of IBM Guardium GIM agents across multiple servers. It reads an inventory CSV file, connects to each target host, copies the installer packages, and runs the IBM installer in unattended mode.

### Quick guidance (minimal steps)

1. **Prepare installer** – Place the IBM GIM Windows package under `examples/windows-gdp-gim/packages/windows/` (e.g. `Guardium_12.2.1.205_GIM_Windows` with `GIM-Installer-*/Setup.exe` inside).
2. **Inventory** – Copy `examples/windows-gdp-gim/inventory/servers.csv.example` to `servers.csv` and set `host`, `username`, `password`, and `gim_server_host` (and optionally `failover_gim_server_host`) per server. Lines starting with `#` are ignored.
3. **Terraform vars** – Edit `examples/windows-gdp-gim/terraform.tfvars`: set `servers_csv_path`, `windows_gim_packages_base_dir` (or set `gim_kit_version` per server in `servers.csv`), and `windows_deployment_method` (e.g. `"smb"`). Ports and Guardium host come from tfvars (ports) and CSV (Guardium/failover per server).
4. **Run** – From `examples/windows-gdp-gim`: `terraform init` then `terraform apply`.

### What Gets Installed

- **GIM (Guardium Installation Manager)** - The core agent that connects to your Guardium central manager
  - Installed to: `C:\Program Files\IBM\Guardium Installation Manager` (default)
  - Service: Guardium Installation Manager (Windows Service)
  - Connects to Guardium central manager on port 8446
  - Listener port: 8445 (per IBM documentation)

### Supported Platforms

**Target Hosts:**
- **Windows**: Windows Server 2016/2019/2022/2025, Windows 10/11

**Terraform Runners:**
- **Windows** (recommended - PowerShell built-in)

## Features

- ✅ **Windows-only deployment**: Streamlined for Windows Server deployments
- ✅ **Multiple deployment methods**: SMB (recommended, no SSH/WinRM required), WinRM, or SSH
- ✅ **Multi-version kit support**: Set `gim_kit_version` per server in `servers.csv` to install different GIM versions in the same `apply`; the installer folder is resolved automatically (no hard-coded path to edit when you upgrade the kit)
- ✅ **Real-state install check**: Before installing, each script compares the target's own `gimver` marker against the kit being deployed and skips reinstalling when they already match - based on what's actually on the host, not just Terraform state (so it stays correct even after state loss/drift)
- ✅ **Service-verified success**: A run is only reported as `SUCCESS` once the `GIM` Windows service is confirmed `Running` on the target - an installer exit code of 0, or a completed file copy/scheduled task, is never enough on its own. If the service exists but is stopped, the script attempts `Start-Service` before failing.
- ✅ **Appliance-reachability gate**: Even with the service `Running`, success additionally requires a live TCP connection from the target to `gim_server_host:gim_server_port` - catching a wrong/unreachable appliance address (typo, firewall, appliance down) that the service state alone would never reveal.
- ✅ **Malformed-IP precondition**: `terraform plan`/`apply` fails immediately, before touching any target, if `gim_server_host`, `local_ip`, or `failover_gim_server_host` in `servers.csv` is IPv4-shaped (all-numeric segments) but not a valid IPv4 address - e.g. a missing dot like `9.46194.103`.
- ✅ **Uninstall on `terraform destroy`**: Locates GIM's InstallShield uninstall entry on each target (registry first, then known fallback paths) and runs `setup.exe -UNINSTALL -UNATTENDED` before removing it from state (toggle via `uninstall_on_destroy`)
- ✅ **Remote log collection**: Copies `GIM.log`, `central_logger.log`, and the installer's `.ctl` log back from each target into `runner_log_dir/<server>/` for troubleshooting
- ✅ **Enhanced logging system**: Log levels (INFO, WARN, ERROR, SUCCESS, DEBUG), color coding, progress indicators, section headers
- ✅ **Configurable ports**: GIM server port and listener port configured globally in `terraform.tfvars`; install directory configurable per server via CSV
- ✅ **Automatic installer detection**: Auto-detects Setup.exe in GIM-Installer-* subdirectories
- ✅ **SMB deployment**: Uses file sharing + scheduled tasks (no SSH/WinRM required)
- ✅ **Idempotent**: Safe to run multiple times
- ✅ **Comprehensive logging**: Per-host logs with enhanced formatting, colors, and installation summaries
- ✅ **Error handling**: Graceful handling of network issues with detailed troubleshooting steps
- ✅ **Installation summaries**: End-of-run summaries with key installation details

## Prerequisites

### On the Terraform Runner (Your Machine)

**Required:**
- Terraform 1.5+ (see [Installing Terraform](#installing-terraform) below)
- PowerShell 5.1+ (Windows) 

**For Windows Runners:**
- PowerShell 5.1+ (built-in) - **Required**


### On Windows Target Hosts

**Required:**
- Windows Server 2016+ or Windows 10/11
- **For SMB deployment (recommended)**: File and Printer Sharing enabled (port 445)
- **For WinRM**: WinRM service enabled (port 5986 HTTPS or 5985 HTTP)
- **For SSH**: OpenSSH Server installed and running (port 22)
- Network connectivity to Guardium appliance (port 8446)

**WinRM Setup (if using WinRM):**
```powershell
# Enable WinRM HTTPS listener
Enable-PSRemoting -Force
New-NetFirewallRule -DisplayName "WinRM HTTPS" -Direction Inbound -LocalPort 5986 -Protocol TCP -Action Allow
```

**OpenSSH Server Setup (if using SSH from Mac/Linux):**
```powershell
# Install OpenSSH Server (Windows 10/11 and Server 2019+)
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Start-Service sshd
Set-Service -Name sshd -StartupType 'Automatic'
New-NetFirewallRule -Name sshd -DisplayName 'OpenSSH Server (sshd)' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22
```

### Network Requirements

**From Target Hosts → Guardium Appliance:**
- TCP `8446` - GIM agent to central manager (required)
- TCP `8443` - Discovery and feature uploads (optional)
- TCP `8445` - GIM listener port (optional, for listener mode)

**From Terraform Runner → Target Hosts:**
- **SMB Method**: TCP `445` (File and Printer Sharing) - Recommended
- **WinRM Method**: TCP `5986` (WinRM HTTPS) or TCP `5985` (WinRM HTTP)
- **SSH Method**: TCP `22` (SSH) - Requires OpenSSH Server on Windows

#### AWS Security Groups / Firewall Configuration

**For AWS EC2 Instances:**

**Inbound Rules (Security Group):**
- **SMB Method**: TCP `445` (File and Printer Sharing) - From Terraform runner IP
- **WinRM Method**: TCP `5986` (WinRM HTTPS) - From Terraform runner IP
- **SSH Method**: TCP `22` (SSH) - From Terraform runner IP

**Outbound Rules (Security Group):**
- TCP `8446` - To Guardium appliance IP
  - Destination: Guardium central manager IP (e.g., `9.80.59.143`)
  - Required for: GIM agent registration and communication
- TCP `8443` - To Guardium appliance IP (optional)
  - Destination: Guardium central manager IP
  - Required for: Discovery and feature uploads
- TCP `8445` - To Guardium appliance IP (optional)
  - Destination: Guardium central manager IP
  - Required for: GIM listener mode

**Example AWS Security Group Configuration:**

**Inbound (SMB Method - Recommended):**
```
Type        Protocol    Port Range    Source
SMB         TCP         445           <Your-Terraform-Runner-IP>/32
```

**Inbound (WinRM Method):**
```
Type        Protocol    Port Range    Source
WinRM HTTPS TCP         5986          <Your-Terraform-Runner-IP>/32
```

**Inbound (SSH Method):**
```
Type        Protocol    Port Range    Source
SSH         TCP         22             <Your-Terraform-Runner-IP>/32
```

**Outbound:**
```
Type        Protocol    Port Range    Destination
Custom TCP  TCP         8446         <Guardium-Server-IP>/32
Custom TCP  TCP         8443         <Guardium-Server-IP>/32  (optional)
Custom TCP  TCP         8445         <Guardium-Server-IP>/32  (optional)
```

**For On-Premises / Other Cloud Providers:**

**Firewall Rules Required:**
- **Outbound from target hosts:**
  - TCP `8446` → Guardium appliance IP (required)
  - TCP `8443` → Guardium appliance IP (optional - discovery)
  - TCP `8445` → Guardium appliance IP (optional - listener)
- **Inbound to target hosts:**
  - TCP `445` (SMB) from Terraform runner (if using SMB method)
  - TCP `5986` (WinRM HTTPS) from Terraform runner (if using WinRM method)
  - TCP `22` (SSH) from Terraform runner (if using SSH method)

**Testing Connectivity:**

Before running Terraform, verify network connectivity:

**From Windows Target Host:**
```powershell
# Test connectivity to Guardium
Test-NetConnection -ComputerName <guardium-ip> -Port 8446
Test-NetConnection -ComputerName <guardium-ip> -Port 8443
Test-NetConnection -ComputerName <guardium-ip> -Port 8445
```

**From Terraform Runner:**
```powershell
# Test SMB connectivity (SMB method)
Test-NetConnection -ComputerName <target-host> -Port 445

# Test WinRM connectivity (WinRM method)
Test-WSMan -ComputerName <target-host> -Port 5986

# Test SSH connectivity (SSH method)
ssh <username>@<target-host>
```

**AWS CLI Example (Test Security Group Rules):**
```bash
# Test outbound connectivity from EC2 instance
aws ec2 describe-security-groups --group-ids sg-xxxxxxxxx
# Verify outbound rules allow TCP 8446 to Guardium IP
```

## Installing Terraform

### Windows Installation

#### Method 1: Using Chocolatey (Recommended)

**Install Chocolatey (if not already installed):**
```powershell
# Run PowerShell as Administrator
Set-ExecutionPolicy Bypass -Scope Process -Force
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
```

**Install Terraform:**
```powershell
# Run PowerShell as Administrator
choco install terraform -y

# Verify installation
terraform version
```

#### Method 2: Manual Installation

1. **Download Terraform:**
   - Visit https://www.terraform.io/downloads
   - Download the Windows AMD64 zip file

2. **Extract and Install:**
   ```powershell
   # Extract to a folder (e.g., C:\terraform)
   # Add to PATH:
   # 1. Open System Properties → Environment Variables
   # 2. Edit "Path" under System Variables
   # 3. Add: C:\terraform
   # 4. Click OK
   
   # Verify installation (open new PowerShell window)
   terraform version
   ```

3. **Additional Tools:**
   ```powershell
   # PowerShell 5.1+ is built-in on Windows 10/11 - no additional install needed for a Windows runner.
   # SSH client is also built into Windows 10/11 (used only if windows_deployment_method = "ssh").
   ```

#### Method 3: Using Winget (Windows 11 / Windows 10 1809+)

```powershell
# Install Terraform
winget install HashiCorp.Terraform

# Verify installation
terraform version
```
## Platform Differences

### Running Terraform from Different Platforms

This project deploys **Windows-only** targets, but Terraform can be run from any platform:

| Terraform Runner Platform | Windows Target Deployment | Notes |
|---------------------------|---------------------------|-------|
| **Windows** | ✅ SMB, WinRM, or SSH | **Recommended** - Native PowerShell, best compatibility |
| **Linux** | ✅ SMB, SSH (requires pwsh) | Requires PowerShell Core (pwsh) for Windows deployments |
| **macOS** | ✅ SMB, SSH (requires pwsh) | Requires PowerShell Core (pwsh) for Windows deployments |

### Key Differences

#### Windows Runner (Recommended)

**Advantages:**
- ✅ Native PowerShell 5.1+ (built-in)
- ✅ Native WinRM support (if using WinRM method)
- ✅ Best compatibility with Windows targets
- ✅ No additional software required

**Requirements:**
- PowerShell 5.1+ (built-in on Windows 10/11)
- Terraform installed

**Configuration:**
```hcl
windows_deployment_method = "smb"  # Recommended - no SSH/WinRM needed
# Or:
windows_deployment_method = "winrm"  # Native Windows remote management
```

#### Linux/macOS Runner

**Advantages:**
- ✅ Standard Unix tools available
- ✅ Can run Terraform from Linux/macOS environments

**Requirements:**
- PowerShell Core (pwsh) - **Required** for Windows deployments
  - Install: `sudo apt-get install -y powershell` (Ubuntu/Debian)
  - Install: `sudo yum install -y powershell` (RHEL/CentOS)
  - Install: `brew install --cask powershell` (macOS)

**Configuration:**
```hcl
windows_deployment_method = "smb"  # Recommended - works from any platform
# Or:
windows_deployment_method = "ssh"  # Requires OpenSSH Server on Windows hosts
```

**Note:** WinRM method is not available from Linux/macOS runners (PowerShell Core doesn't support WinRM client).

### Recommendation

**For Windows-only deployments:** Use a **Windows machine** as your Terraform runner for best compatibility and native PowerShell support. However, SMB method works well from any platform.

## Installation Guide

### Step 1: Install Terraform

Follow the [Installing Terraform](#installing-terraform) section below for your operating system.

**Quick Check:**
```bash
terraform version
# Should show: Terraform v1.5.0 or higher
```

### Step 2: Clone or Download This Repository

```bash
git clone <repository-url>
cd terraform-windows-gdp-gim
```

Or download and extract the ZIP file to your desired location.

### Step 3: Prepare Installer Packages

Place your IBM Guardium Windows installer package in the following directory structure:

```
examples/windows-gdp-gim/packages/windows/
└── Guardium_12.2.1.205_GIM_Windows/
    └── GIM-Installer-12.2_r120201205_1/
        └── Setup.exe
```

**Important:** The script automatically detects `Setup.exe` in `GIM-Installer-*` subdirectories. Alternative locations:
- `Setup.exe` or `setup.exe` in the root of `Guardium_12.2.1.205_GIM_Windows/`
- `*.exe.signed` files in `Gim-Kits/` subdirectory

### Step 4: Configure Server Inventory (servers.csv)

Create or edit `examples/windows-gdp-gim/inventory/servers.csv` with your Windows servers. See [Understanding servers.csv](#understanding-serverscsv) below for detailed explanation.

**Note:** Ports (`gim_server_port`, `listener_port`) are configured in `terraform.tfvars` (see Step 5), not in the CSV.

**Quick Example (20 columns; optional cert columns can be left empty):**
```csv
name,os,host,mgmt_port,username,password,use_sudo,pem_key_path,gim_server_host,local_ip,install_dir,perl_path,shared_secret,failover_gim_server_host,auto_assign_ip,check_8443,allow_tls_fallback,gim_ca_file,gim_key_file,gim_cert_file
server1,windows,server1.example.com,5986,Administrator,MyPassword123,FALSE,,10.80.59.143,server1.example.com,,,,,0,TRUE,FALSE,,,
server2,windows,server2.example.com,5986,Administrator,MyPassword456,FALSE,,10.80.59.143,server2.example.com,,,,,0,TRUE,FALSE,,,
```

**Copy the example file:**
```bash
cd examples/windows-gdp-gim/inventory
cp servers.csv.example servers.csv
# Edit servers.csv with your server details
```

### Step 5: Configure Terraform Variables

Edit `examples/windows-gdp-gim/terraform.tfvars`:

```hcl
servers_csv_path = "./inventory/servers.csv"
runner_log_dir = "./logs"
gim_server_port = 8446
listener_port   = false
windows_gim_packages_base_dir = "./packages/windows"
windows_deployment_method = "smb"
```
Guardium central manager and failover are set per server in `servers.csv` (`gim_server_host`, `failover_gim_server_host`). The GIM kit version is likewise set per server via `gim_kit_version` in `servers.csv` (or `default_gim_kit_version` here for a single version shared by all servers) - see [Installer Directory Resolution](#installer-directory-resolution-multi-version-kit-support).

**Copy the example file:**
```bash
cd examples/windows-gdp-gim
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your configuration
```

### Step 6: Initialize Terraform

```bash
cd examples/windows-gdp-gim
terraform init
```

This downloads the required Terraform providers and prepares the working directory.

**Expected Output:**
```
Initializing the backend...
Initializing provider plugins...
- Finding hashicorp/null versions matching "3.2.4"...
- Installing hashicorp/null v3.2.4...
Terraform has been successfully initialized!
```

## How to Run / Deploy

### Step 1: Review the Deployment Plan

Before deploying, review what Terraform will do:

```bash
cd examples/windows-gdp-gim
terraform plan
```

This shows:
- Which servers will be deployed
- What resources will be created
- Any configuration issues

**Example Output:**
```
Plan: 3 to add, 0 to change, 0 to destroy.

  # null_resource.install_gim_windows["server1"] will be created
  # null_resource.install_gim_windows["server2"] will be created
  # null_resource.install_gim_windows["server3"] will be created
```

### Step 2: Execute the Deployment

```bash
terraform apply
```

Terraform will:
1. Show the execution plan
2. Ask for confirmation: `Do you want to perform these actions? Enter a value:`
3. Type `yes` and press Enter to proceed
4. Execute installations in parallel (if multiple servers)
5. Show real-time progress and logs

**Expected Output:**
```
null_resource.install_gim_windows["server1"]: Creating...
null_resource.install_gim_windows["server1"] (local-exec): [2026-02-12T18:42:32Z] [1/8] Windows GIM Installation (SMB/Scheduled Task Method)
null_resource.install_gim_windows["server1"] (local-exec): [2026-02-12T18:42:33Z] [SUCCESS] Found installer: C:\...\Setup.exe
...
null_resource.install_gim_windows["server1"]: Creation complete after 1m28s
```

### Step 3: Verify Installation

**Check Logs:**
```bash
# View logs for a specific server
cat logs/server1.log

# Or on Windows PowerShell:
Get-Content logs\server1.log
```

**Check Installation Summary:**
Each log file ends with an installation summary:
```
═══════════════════════════════════════════════════════════════
  Installation Completed Successfully
═══════════════════════════════════════════════════════════════
[SUCCESS] Target Host: server1.example.com
[SUCCESS] GIM Server: 10.80.59.143:8446
[SUCCESS] Install Directory: C:\Program Files\IBM\Guardium Installation Manager
[SUCCESS] Listener Port: 8445
[SUCCESS] Duration: 82.13 seconds
```

**Verify on Target Server:**
```powershell
# Connect to Windows server and check GIM service
Get-Service | Where-Object {$_.Name -like "*guard*"}
# Should show: Guardium Installation Manager service running

# Check installation directory
Test-Path "C:\Program Files\IBM\Guardium Installation Manager"
# Should return: True
```

### Step 4: Re-run or Update

**Re-run Installation:**
```bash
# If you need to re-install (e.g., after configuration changes)
terraform apply
```

**Update Specific Server:**
```bash
# Taint a specific server to force re-installation
terraform taint 'null_resource.install_gim_windows["server1"]'
terraform apply
```

**Remove Server from Deployment:**
```bash
# Remove server from servers.csv, then:
terraform apply
# Terraform will destroy the resource for removed servers
```

## Understanding servers.csv

The `servers.csv` file is the **inventory file** that defines all Windows servers where GIM will be installed. Each row represents one server.

### File Location

```
examples/windows-gdp-gim/inventory/servers.csv
```

### File Format

The CSV file uses standard CSV format:
- **First row**: Column headers (required)
- **Subsequent rows**: Server entries (one per server)
- **Delimiter**: Comma (`,`)
- **Quotes**: Optional (values can be quoted: `"value"`)
- **Comments**: Lines that start with `#` and blank lines are ignored by Terraform, so you can copy `servers.csv.example` to `servers.csv` and keep the comment lines while editing.

### Column Reference

#### Required Columns

| Column | Description | Example | Notes |
|--------|-------------|---------|-------|
| `name` | Unique identifier for the server | `server1`, `poc-windows2022` | Used as Terraform resource name |
| `os` | Operating system | `windows` | Must be `windows` (case-insensitive) |
| `host` | Hostname or IP address | `server1.example.com`, `192.168.1.100` | Must be resolvable/accessible |
| `mgmt_port` | Management port | `5986` (WinRM), `22` (SSH), or `5986` (SMB) | Not used for SMB method, but required |
| `username` | Login username | `Administrator` | Must have admin privileges |
| `password` | Login password | `MyPassword123!` | Required for authentication |
| `gim_server_host` | Guardium central manager IP/hostname | `10.80.59.143` | Where GIM agent connects |

#### Configured in terraform.tfvars (global – not in CSV)

| Setting | Description | Default | Notes |
|---------|-------------|---------|-------|
| `gim_server_port` | Guardium management port for GIM | `8446` | Always passed to the install script; applies to all servers |
| `listener_port` | Enable GIM listener port | `false` | **Boolean.** `true` = script gets listener port 8445; `false` = option not passed |

#### Optional CSV columns (per-server)

| Column | Description | Default | Example | Notes |
|--------|-------------|---------|---------|-------|
| `install_dir` | Installation directory | `C:\Program Files\IBM\Guardium Installation Manager` | `C:\Program Files\IBM\Guardium Installation Manager` | Can be customized per server |
| `local_ip` | Client IP address | `host` value | `192.168.1.100` | Auto-detected if empty |
| `shared_secret` | Shared secret for agent authentication | Empty | (secret value) | Optional; passed as `-SHARED_SECRET` when set. **Protect CSV and Terraform state.** |
| `failover_gim_server_host` | Failover Guardium server IP/hostname | Empty | `9.80.59.144` | Optional; passed as `-FAILOVER_APPLIANCE` when set. Leave empty to omit. |
| `gim_ca_file` | Path on the Terraform runner to CA PEM file | Empty | `C:\Guardium\ca.pem` | Optional; for custom/listener TLS. **Both** `gim_key_file` and `gim_cert_file` must be set; CA is optional for self-signed. Copied automatically to each target before install - no manual staging needed. |
| `gim_key_file` | Path on the Terraform runner to private key PEM | Empty | `C:\Guardium\client.key` | Optional; for custom TLS. Required together with `gim_cert_file`; omit both to use default TLS. Copied automatically to each target before install. |
| `gim_cert_file` | Path on the Terraform runner to certificate PEM | Empty | `C:\Guardium\client.pem` | Optional; for custom TLS. Required together with `gim_key_file`. Copied automatically to each target before install. See [IBM Docs: Installing GIM on Windows](https://www.ibm.com/docs/en/gdp/12.x?topic=iuugcws-installing-gim-other-packages-windows-servers-by-using-consolidated-installer). |
| `auto_assign_ip` | Auto-assign IP | `0` | `0` or `1` | Set to `1` for auto-assignment. **IBM: Do not specify both auto_assign_ip and local_ip.** When `1`, LOCALIP is omitted and `-GIM_AUTO_SET_CLIENT_IP 1` is passed. |
| `check_8443` | Check port 8443 connectivity | `TRUE` | `TRUE` or `FALSE` | Parsed from CSV but **not currently passed to any deployment script** - reserved for future use; has no effect today |
| `allow_tls_fallback` | Allow TLS fallback | `FALSE` | `TRUE` or `FALSE` | Parsed from CSV but **not currently passed to any deployment script** - reserved for future use; has no effect today |
| `gim_kit_version` | GIM kit to install on this server | `default_gim_kit_version` (tfvars) | `12.2.1.205`, `12.x.p100_r120203321`, or just `259` | Optional. Matched as a case-insensitive substring against `windows_gim_packages_base_dir/Guardium_*_GIM_Windows` folder names - must uniquely identify one folder or `terraform plan` fails with the ambiguous/missing matches. Lets different servers use different GIM versions in one `apply`. Leave empty to use `default_gim_kit_version` / `windows_gim_installer_dir` from `terraform.tfvars`. See [Installer Directory Resolution](#installer-directory-resolution-multi-version-kit-support). |

#### Compatibility Columns (not used, but kept for CSV compatibility)

| Column | Description | Notes |
|--------|-------------|-------|
| `use_sudo` | Sudo usage flag | Not used for Windows (kept for compatibility) |
| `pem_key_path` | SSH key path | Not used for Windows (kept for compatibility) |
| `perl_path` | Perl path | Not used for Windows (kept for compatibility) |

### Complete Example

```csv
name,os,host,mgmt_port,username,password,use_sudo,pem_key_path,gim_server_host,local_ip,install_dir,perl_path,shared_secret,failover_gim_server_host,auto_assign_ip,check_8443,allow_tls_fallback,gim_ca_file,gim_key_file,gim_cert_file,gim_kit_version
win2019a,windows,win2019a.dev.company.com,5986,Administrator,MyPassword!234,FALSE,,10.80.59.145,10.60.250.172,,,,107.22.123.11,0,TRUE,FALSE,C:\Users\Administrator\gim_0802\terraform-windows-gdp-gim\examples\windows-gdp-gim\gim-certs\SKgim_ca.pem,C:\Users\Administrator\gim_0802\terraform-windows-gdp-gim\examples\windows-gdp-gim\gim-certs\SKgimListenerServer.key.pem,C:\Users\Administrator\gim_0802\terraform-windows-gdp-gim\examples\windows-gdp-gim\gim-certs\SKgimListenerServer.cert.pem,12.2.1.205
win2025a,windows,win2025a.dev.company.com,5986,Administrator,MyPassword!234,FALSE,,10.80.59.145,10.60.254.223,,,,107.22.123.11,0,TRUE,FALSE,C:\Users\Administrator\gim_0802\terraform-windows-gdp-gim\examples\windows-gdp-gim\gim-certs\SKgim_ca.pem,C:\Users\Administrator\gim_0802\terraform-windows-gdp-gim\examples\windows-gdp-gim\gim-certs\SKgimListenerServer.key.pem,C:\Users\Administrator\gim_0802\terraform-windows-gdp-gim\examples\windows-gdp-gim\gim-certs\SKgimListenerServer.cert.pem,12.2.1.205
win2022a,windows,win2022a.dev.company.com,5986,Administrator,MyPassword!234,FALSE,,10.80.59.145,10.30.234.196,,,,107.22.123.11,0,TRUE,FALSE,C:\Users\Administrator\gim_0802\terraform-windows-gdp-gim\examples\windows-gdp-gim\gim-certs\SKgim_ca.pem,C:\Users\Administrator\gim_0802\terraform-windows-gdp-gim\examples\windows-gdp-gim\gim-certs\SKgimListenerServer.key.pem,C:\Users\Administrator\gim_0802\terraform-windows-gdp-gim\examples\windows-gdp-gim\gim-certs\SKgimListenerServer.cert.pem,12.2.2.259

```

**Important notes:** Quote `install_dir` paths with backslashes (e.g. `"C:\IBM"`) or use forward slashes to avoid CSV parse errors. Keep `install_dir` directly after `local_ip` (no extra comma). For custom TLS, set both `gim_key_file` and `gim_cert_file`; see [Testing with custom TLS](docs/TESTING_WITH_CERT.md).

### Configuration split (CSV vs tfvars)

- **terraform.tfvars (global):** `gim_server_port` (default 8446), `listener_port` (boolean; `true` = use port 8445).
- **servers.csv (per-server):** `gim_server_host` (required), `failover_gim_server_host`, `install_dir`, `local_ip`, `shared_secret`, and optionally `gim_ca_file`, `gim_key_file`, `gim_cert_file`. Optional columns are only passed when non-empty.

### Common Patterns

#### Minimal Configuration (using all defaults)
```csv
name,os,host,mgmt_port,username,password,use_sudo,pem_key_path,gim_server_host,local_ip,install_dir,perl_path,shared_secret,failover_gim_server_host,auto_assign_ip,check_8443,allow_tls_fallback,gim_ca_file,gim_key_file,gim_cert_file
server1,windows,server1.example.com,5986,Administrator,Password123,FALSE,,10.80.59.143,,,,,0,TRUE,FALSE,,,
```

#### Custom ports (in terraform.tfvars, not CSV)
Set in `examples/windows-gdp-gim/terraform.tfvars`:
```hcl
gim_server_port = 8446   # Guardium management port (default)
listener_port   = true   # Use GIM listener port 8445; set false to omit
```
Ports apply to all servers; they are not configured per server in CSV.

#### Custom Installation Directory
```csv
name,os,host,mgmt_port,username,password,use_sudo,pem_key_path,gim_server_host,local_ip,install_dir,perl_path,shared_secret,failover_gim_server_host,auto_assign_ip,check_8443,allow_tls_fallback,gim_ca_file,gim_key_file,gim_cert_file
server1,windows,server1.example.com,5986,Administrator,Password123,FALSE,,10.80.59.143,server1.example.com,"C:\IBM",,,,0,TRUE,FALSE,,,
```
**Note:** Quote paths with backslashes (e.g. `"C:\IBM"`) to avoid CSV parse errors. Forward slashes (e.g. `C:/IBM`) also work.

#### Custom TLS certificates (optional)
To use custom CA/key/cert for GIM TLS (paths on the **Terraform runner** - the scripts copy them to each target automatically), add the three optional columns and set both `gim_key_file` and `gim_cert_file`; `gim_ca_file` is optional (e.g. for self-signed).
```csv
name,os,host,mgmt_port,username,password,use_sudo,pem_key_path,gim_server_host,local_ip,install_dir,perl_path,shared_secret,failover_gim_server_host,auto_assign_ip,check_8443,allow_tls_fallback,gim_ca_file,gim_key_file,gim_cert_file
server1,windows,server1.example.com,5986,Administrator,Password123,FALSE,,9.80.59.143,server1.example.com,,,,,0,TRUE,FALSE,C:\Guardium\ca.pem,C:\Guardium\client.key,C:\Guardium\client.pem
```
If you omit custom TLS, use the 17-column format or leave the last three fields empty (`,,,`).  
**Step-by-step:** See [Testing with custom TLS certificates](docs/TESTING_WITH_CERT.md) for generating test certs and running a test.

### Tips and Best Practices

1. **Start with the example file**: Copy `servers.csv.example` to `servers.csv` and modify
2. **Use descriptive names**: Server names should be meaningful (e.g., `prod-db-01` not `s1`)
3. **Test with one server first**: Add one server, test, then add more
4. **Keep CSV in version control**: But use `.gitignore` to exclude actual passwords
5. **Use environment variables**: For sensitive values, consider using Terraform variables
6. **Validate before running**: Check CSV syntax and required fields before `terraform apply`
7. **Document custom values**: Add comments in a separate file explaining custom configurations

### Troubleshooting CSV Issues

**"CSV parse error on line N: wrong number of fields"**
- **Cause**: Paths with backslashes (e.g., `C:\IBM`) may not parse correctly without quotes
- **Fix**: Quote the `install_dir` value: `"C:\IBM"` instead of `C:\IBM`. Or use forward slashes: `C:/IBM`
- **Also check**: All rows must have the same number of columns as the header - 17 base columns, +3 (20) if using the optional cert columns, +1 more (18 or 21) if also using `gim_kit_version`. Verify no extra or missing commas

**Installation goes to default folder instead of custom `install_dir`**
- **Cause**: Extra comma in the row, causing your path to land in the `perl_path` column instead of `install_dir`
- **Fix**: Ensure `install_dir` comes directly after `local_ip` with no extra comma. Correct: `...,local_ip_value,C:\IBM,,,0,...` Wrong: `...,local_ip_value,,C:\IBM,,,0,...`
- **Verify**: Run `terraform plan` and check that the provisioner shows `-InstallDir "C:\IBM"` (or your path) for the server in question

**"Invalid CSV format"**
- Check for missing commas
- Ensure all rows have the same number of columns
- Verify quotes are properly closed

**"Missing required column"**
- Ensure first row contains all required column headers
- Check for typos in column names (case-sensitive)

**"Empty value error"**
- Required columns (`name`, `os`, `host`, etc.) cannot be empty
- Optional columns can be empty (will use defaults)

**"Duplicate name"**
- Each server must have a unique `name` value
- Check for duplicate rows

**"missing header line" or empty CSV**
- Terraform ignores lines that start with `#` and blank lines. If every line is a comment or blank, the CSV becomes empty.
- **Fix**: Ensure at least one line is the header row (column names) and the next lines are data rows. You can keep `#` comment lines above the header; the first non-comment, non-blank line must be the header.

#### Enhanced Logging System

The installation scripts use an enhanced logging system with the following features:

**Log Levels:**
- `INFO` - General information (white)
- `WARN` - Warnings (yellow)
- `ERROR` - Errors (red)
- `SUCCESS` - Success messages (green)
- `DEBUG` - Debug information (gray)

**Features:**
- **Color coding**: Logs are color-coded in terminal output (colors disabled in log files)
- **Progress indicators**: Shows `[1/8]`, `[2/8]`, etc. for major steps
- **Section headers**: Clear section separators for major phases:
  - Locating Installer Files
  - Configuring SMB Connection
  - Copying Files to Remote Host
  - Creating Installation Script
  - Creating Scheduled Task
  - Executing Installation
  - Installation Summary
- **Installation summary**: End-of-run summary with key details:
  - Target Host
  - GIM Server
  - Install Directory
  - Listener Port
  - Duration

**Example Log Output:**
```
═══════════════════════════════════════════════════════════════
  [1/8] Windows GIM Installation (SMB/Scheduled Task Method)
═══════════════════════════════════════════════════════════════

[2026-02-12T11:19:27Z] [INFO] [1/8] Target Host: server1.example.com
[2026-02-12T11:19:27Z] [INFO] GIM Server: 10.80.59.143:8446
[2026-02-12T11:19:27Z] [SUCCESS] [2/8] Found installer: C:\...\Setup.exe
[2026-02-12T11:19:28Z] [INFO] [3/8] Testing SMB connectivity...
[2026-02-12T11:19:28Z] [SUCCESS] SMB connectivity test successful
...
═══════════════════════════════════════════════════════════════
  Installation Completed Successfully
═══════════════════════════════════════════════════════════════
[2026-02-12T11:20:15Z] [SUCCESS] Target Host: server1.example.com
[2026-02-12T11:20:15Z] [SUCCESS] Duration: 48.5 seconds
```

## Configuration

### Terraform Variables

#### Required Variables

| Variable | Description | Example |
|----------|-------------|---------|
| `servers_csv_path` | Path to inventory CSV file | `"./inventory/servers.csv"` |

Guardium central manager and failover are set **per server in `servers.csv`** (`gim_server_host`, `failover_gim_server_host`), not in tfvars. The installer directory is resolved automatically (see below) - there is no longer a required path variable to set.

#### Optional Variables (including ports – global)

| Variable | Description | Default |
|----------|-------------|---------|
| `gim_server_port` | Guardium management port for GIM (global; applies to all servers) | `8446` |
| `listener_port` | Enable GIM listener port: `true` = use port 8445, `false` = do not pass listener port | `false` |
| `install_windows_gim` | Enable/disable Windows GIM installation | `true` |
| `windows_deployment_method` | Deployment method: 'smb', 'winrm', or 'ssh' | `"smb"` |
| `windows_use_ssh` | Legacy: Use SSH for Windows (use windows_deployment_method instead) | `false` |
| `windows_install_dir` | Windows installation directory (fallback if not in CSV) | `"C:\\Program Files\\IBM\\Guardium Installation Manager"` |
| `runner_log_dir` | Directory for log files | `"./logs"` |
| `windows_gim_packages_base_dir` | Base directory containing versioned `Guardium_<version>_GIM_Windows` folders | `"./packages/windows"` |
| `default_gim_kit_version` | Default GIM kit version used when a server row doesn't set its own `gim_kit_version` | `""` |
| `windows_gim_installer_dir` | **Legacy** explicit path to the installer directory. Only used when no `gim_kit_version`/`default_gim_kit_version` is set | `""` |
| `skip_if_already_installed` | Skip reinstall when the target's own `gimver` marker already matches the kit being deployed | `true` |
| `collect_remote_logs` | Copy `GIM.log` / `central_logger.log` / installer `.ctl` log back from each target | `true` |
| `uninstall_on_destroy` | `terraform destroy` runs `setup.exe -UNINSTALL` on each target before removing state | `true` |

**Note:** Ports are in `terraform.tfvars`. All per-server settings (`gim_server_host`, `failover_gim_server_host`, `install_dir`, etc.) are in `servers.csv`. See [Understanding servers.csv](#understanding-serverscsv).

**Inventory:** All server settings (including `gim_server_host` and `failover_gim_server_host`) come from `servers.csv`. See [Understanding servers.csv](#understanding-serverscsv) for column reference and examples. Copy `examples/windows-gdp-gim/inventory/servers.csv.example` to `servers.csv` and edit.

### Windows Deployment Methods

This project supports three deployment methods for Windows servers:

#### 1. SMB Method (Recommended)

**Advantages:**
- ✅ No SSH or WinRM required
- ✅ Uses File and Printer Sharing (port 445) - standard Windows feature
- ✅ More secure (no remote execution protocols needed)
- ✅ Works with standard Windows configurations

**Configuration:**
- Set `windows_deployment_method = "smb"` in `terraform.tfvars`
- Ensure File and Printer Sharing is enabled on Windows hosts
- `mgmt_port` in CSV is not used but must be present (use `5986`)

**Requirements:**
- File and Printer Sharing enabled on Windows host (port 445)
- Administrator credentials with access to C$ share
- Network connectivity from Terraform runner to Windows host

#### 2. WinRM Method

**Advantages:**
- ✅ Native Windows remote management
- ✅ Works well from Windows Terraform runners

**Configuration:**
- Set `windows_deployment_method = "winrm"` in `terraform.tfvars`
- Set `mgmt_port = 5986` in CSV (WinRM HTTPS)
- WinRM must be enabled on Windows hosts

**Requirements:**
- WinRM service enabled on Windows host (port 5986 HTTPS or 5985 HTTP)
- PowerShell remoting configured
- Firewall rules allowing WinRM access

**Setup on Windows Host:**
```powershell
# Enable WinRM HTTPS listener
Enable-PSRemoting -Force
New-NetFirewallRule -DisplayName "WinRM HTTPS" -Direction Inbound -LocalPort 5986 -Protocol TCP -Action Allow
```

#### 3. SSH Method

**Advantages:**
- ✅ Works from Linux/macOS Terraform runners
- ✅ Standard SSH protocol

**Configuration:**
- Set `windows_deployment_method = "ssh"` in `terraform.tfvars`
- Set `mgmt_port = 22` in CSV (SSH)
- OpenSSH Server must be installed on Windows hosts

**Requirements:**
- OpenSSH Server installed and running on Windows host (port 22)
- Firewall rules allowing SSH access

**Setup on Windows Host:**
```powershell
# Install OpenSSH Server (Windows 10/11 and Server 2019+)
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Start-Service sshd
Set-Service -Name sshd -StartupType 'Automatic'
New-NetFirewallRule -Name sshd -DisplayName 'OpenSSH Server (sshd)' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22
```

### Installation Directory

**Default:** `C:\Program Files\IBM\Guardium Installation Manager`

**Configurable:**
- Per server: Set `install_dir` column in CSV
- Global fallback: Set `windows_install_dir` in `terraform.tfvars`

## Usage Examples

### Basic Installation (All Servers)

```bash
cd examples/windows-gdp-gim
terraform init
terraform plan    # Review what will be deployed
terraform apply   # Deploy to all servers in servers.csv
```

### Install Specific Server Only

```bash
# Use Terraform target to deploy only one server
terraform apply -target='null_resource.install_gim_windows["server1"]'
```

### Force Re-installation

If you need to re-install a server (e.g., after configuration changes):

```bash
# Taint the resource to force re-creation
terraform taint 'null_resource.install_gim_windows["server1"]'
terraform apply
```

### Update Configuration and Re-deploy

1. **Update servers.csv** or **terraform.tfvars** with new values (e.g., change `listener_port` in tfvars)
2. **Run terraform apply** - Terraform will detect changes and update

```bash
# Edit terraform.tfvars: set listener_port = true to use listener port 8445, or false to omit
terraform apply
```

### Remove Server from Deployment

1. **Remove server row** from `servers.csv`
2. **Run terraform apply** - Terraform will destroy the resource

```bash
# Remove server1 row from servers.csv
terraform apply
# Terraform will show: null_resource.install_gim_windows["server1"]: Destroying...
```

### Check Installation Status

**View Logs:**
```bash
# Linux/macOS
cat logs/server1.log

# Windows PowerShell
Get-Content logs\server1.log

# View last 50 lines
tail -n 50 logs/server1.log
```

**View Central Summary CSV:**
The central summary CSV (`logs/central-summary.csv`) provides a consolidated view of all installation attempts:

```bash
# Linux/macOS
cat logs/central-summary.csv

# Windows PowerShell
Get-Content logs\central-summary.csv

# Import into Excel/CSV viewer for better formatting
```

**CSV Format:**
```csv
Timestamp,ServerName,Status,GIMServer,InstallDirectory,ListenerPort,DurationSeconds,ErrorMessage
2026-02-12T18:43:54Z,poc-windows2025,SUCCESS,10.80.59.143:8446,C:\Program Files\IBM\Guardium Installation Manager,8445,82.13,
2026-02-12T18:44:27Z,poc-windows2022,SUCCESS,10.80.59.143:8446,C:\Program Files\IBM\Guardium Installation Manager,8445,114.63,
2026-02-12T18:44:53Z,poc-windows2019,SUCCESS,10.80.59.143:8446,C:\Program Files\IBM\Guardium Installation Manager,8445,140.66,
```

**Columns:**
- `Timestamp` - UTC timestamp when installation completed
- `ServerName` - Hostname/IP of the target server
- `Status` - `SUCCESS` or `FAILED`
- `GIMServer` - Guardium central manager (format: IP:Port)
- `InstallDirectory` - Installation directory path
- `ListenerPort` - GIM listener port used
- `DurationSeconds` - Installation duration in seconds
- `ErrorMessage` - Error message if failed (empty if successful)

**Check Installation Summary:**
Each log file ends with a summary showing:
- Target Host
- GIM Server
- Install Directory
- Listener Port
- Duration

**Verify on Windows Server:**
```powershell
# Connect to Windows server and check GIM service
Get-Service | Where-Object {$_.Name -like "*guard*"}

# Check installation directory
Test-Path "C:\Program Files\IBM\Guardium Installation Manager"

# Check GIM service status
Get-Service "Guardium Installation Manager"
```

### Troubleshooting Failed Installations

**Check Logs:**
```bash
# View full log for failed server
cat logs/failed-server.log

# Search for errors
grep -i error logs/failed-server.log
```

**Common Issues:**
- SMB connectivity failures → Check File and Printer Sharing
- Installer not found → Verify `gim_kit_version`/`default_gim_kit_version` match an existing `windows_gim_packages_base_dir/Guardium_<version>_GIM_Windows` folder, or that `windows_gim_installer_dir` points to the correct directory
- Authentication failures → Check username/password in CSV
- Network connectivity → Verify firewall rules and network access

## Architecture

### Component Overview

```
┌─────────────────────┐
│ Terraform Runner     │
│  (Your Machine)      │
│  - Windows/Linux/Mac│
└──────────┬───────────┘
           │
           │ PowerShell Scripts
           │
    ┌──────▼──────┐
    │ Windows     │
    │ Hosts       │
    │ (Targets)   │
    └──────┬──────┘
           │
           ├─────────────────────┐
           │                     │
    ┌──────▼──────┐      ┌──────▼──────┐
    │ SMB (445)   │      │ WinRM/SSH   │
    │ (Recommended)│      │ (Alternative)│
    └──────┬──────┘      └──────┬──────┘
           │                     │
    ┌──────▼─────────────────────▼──────┐
    │  IBM Guardium Installer            │
    │  (Copied and executed locally)     │
    │  Setup.exe -UNATTENDED ...         │
    └──────┬─────────────────────────────┘
           │
    ┌──────▼──────────────┐
    │ Guardium            │
    │ Central Manager      │
    │ (8446, 8445, 8443)  │
    └─────────────────────┘
```

### Deployment Flow

#### SMB Method (Recommended)

1. **Read servers.csv** - Terraform parses CSV file
2. **Locate installer** - Script finds `Setup.exe` in `GIM-Installer-*` directory
3. **Configure SMB connection** - Map a network drive (falls back to a temporary `New-PSDrive` over the UNC path if drive mapping fails) and verify access to `\\<host>\C$` (port 445)
4. **Check existing installation** - Compare the target's own `gimver` marker against the kit being deployed; skip straight to verification if they already match (see [Skip-If-Already-Installed](#skip-if-already-installed-real-target-state-not-just-terraform-state))
5. **Copy files** - Copy the installer to `C:\Windows\Temp\guardium_gim\` via the SMB share; if `gim_key_file`/`gim_cert_file` (and optionally `gim_ca_file`) are set, also copy those PEM files from the runner to `C:\Windows\Temp\guardium_gim\certs\` (see [Custom TLS certificates](#custom-tls-certificates-optional))
6. **Create installation script** - Generate a PowerShell script with the installer parameters, including `-KEY_FILE`/`-CERT_FILE`/`-CA_FILE` when custom TLS certs were copied
7. **Create scheduled task** - Schedule a task to run the installer locally on the target (SMB alone can't execute anything remotely)
8. **Execute installation** - Run the scheduled task, wait for completion, then verify the `GIM` service is `Running` and the target can reach `gim_server_host:gim_server_port` before reporting success (see [Success Requires a Verified Running Service and a Reachable Appliance](#success-requires-a-verified-running-service-and-a-reachable-appliance))
9. **Collect logs and clean up** - Best-effort copy of `GIM.log`/`central_logger.log`/installer `.ctl` log back to the runner, then remove the scheduled task and temporary files on the target

#### WinRM Method

1. **Connect** via WinRM to target host (port 5986)
2. **Find installer** - Locate `Setup.exe` in `GIM-Installer-*` folder
3. **Check existing installation** - Compare the target's own `gimver` marker against the kit being deployed; skip reinstall if already current
4. **Copy installer** - Copy to target host via WinRM (`C:\Windows\Temp\guardium_gim\`)
5. **Get Windows host IP** - Detect IP address for `-LOCALIP` parameter (unless `auto_assign_ip = 1`)
6. **Copy custom TLS certs (if configured)** - Copy `gim_key_file`/`gim_cert_file`/`gim_ca_file` from the runner to `C:\Windows\Temp\guardium_gim\certs\` on the target, then reference the copied paths via `-KEY_FILE`/`-CERT_FILE`/`-CA_FILE`
7. **Run installer** - Execute via PowerShell remoting with IBM parameters
8. **Verify success** - Check installer exit code, confirm the `GIM` service is `Running`, and confirm the target can reach `gim_server_host:gim_server_port`
9. **Collect remote logs** - Best-effort copy of GIM's own logs back to the runner

#### SSH Method

1. **Connect** via SSH to target host (port 22)
2. **Find installer** - Locate `Setup.exe` in installer directory
3. **Check existing installation** - Compare the target's own `gimver` marker against the kit being deployed; skip reinstall if already current
4. **Copy installer** - Copy via SCP (or PSCP for password auth) to target host
5. **Get Windows host IP** - Detect IP via PowerShell over SSH (unless `auto_assign_ip = 1`)
6. **Copy custom TLS certs (if configured)** - Copy `gim_key_file`/`gim_cert_file`/`gim_ca_file` from the runner to the target via SCP/PSCP, then reference the copied paths via `-KEY_FILE`/`-CERT_FILE`/`-CA_FILE`
7. **Run installer** - Execute via PowerShell over SSH with IBM parameters
8. **Verify success** - Check installer exit code, confirm the `GIM` service is `Running`, and confirm the target can reach `gim_server_host:gim_server_port`
9. **Collect remote logs** - Best-effort copy of GIM's own logs back to the runner

### Installer Directory Resolution (Multi-Version Kit Support)

Instead of hard-coding a version-specific path in `terraform.tfvars`, the installer directory is resolved per server, in this order:

1. **`gim_kit_version` in `servers.csv`** (per server) → matched as a **case-insensitive substring** against the `Guardium_*_GIM_Windows` folder names under `windows_gim_packages_base_dir`. This lets a single `apply` install different GIM versions on different servers, and it doesn't require an exact/full identifier - any of these work as long as the value uniquely identifies one folder:
   - a full version: `12.2.2.259` → matches `Guardium_12.2.2.259_GIM_Windows`
   - a fix pack tag: `12.x.p100_r120203321` → matches `Guardium_12.x.p100_r120203321_GIM_Windows`
   - just a unique fragment of either: `259`, or `r120203321`
   - If the value matches **zero or more than one** folder, `terraform plan`/`apply` fails immediately with a clear error listing what matched and every available folder - it never silently guesses.
2. **`default_gim_kit_version`** (tfvars) → same substring-matching behavior, used for any server that doesn't set its own `gim_kit_version`.
3. **`windows_gim_installer_dir`** (tfvars, legacy) → an explicit full path, used only if neither of the above is set.
4. **Auto-detect** → if none of the above is set and exactly one `Guardium_*_GIM_Windows` folder exists under `windows_gim_packages_base_dir`, that folder is used automatically.

This means **upgrading the GIM kit is just "drop the new `Guardium_<version>_GIM_Windows` folder under `packages/windows/`"** - no `terraform.tfvars` path to edit and no risk of the previously-reported `InstallerDir not found on runner` error after renaming/replacing the kit folder.

**Example Structure (supports multiple versions side by side):**
```
packages/windows/
├── Guardium_12.2.1.205_GIM_Windows/
│   └── GIM-Installer-12.2_r120201205_1/
│       └── Setup.exe
└── Guardium_12.2.3.100_GIM_Windows/
    └── GIM-Installer-12.2_r122301100_1/
        └── Setup.exe
```

Within a resolved installer directory, `Setup.exe` is located in this order:
1. `Setup.exe` in `GIM-Installer-*` subdirectories (preferred - IBM standard structure)
2. `Setup.exe` or `setup.exe` in root directory
3. `*.exe.signed` files in `Gim-Kits` folder (fallback)

### Skip-If-Already-Installed (Real Target State, Not Just Terraform State)

Before running the installer, each script reads the kit's own version marker file (`gimver`, shipped next to `Setup.exe`) and compares it against `<InstallDir>\gimver` **on the target host itself**. If they already match, the installer is not re-run. Because this check reads the actual target, it stays correct even if the Terraform state file is lost, deleted, or out of sync (e.g. after a migration or disaster recovery) - unlike relying on Terraform state alone, which would either force a needless reinstall or silently skip one with no warning. Disable with `skip_if_already_installed = false` if you always want to (re)run the installer.

### Success Requires a Verified Running Service and a Reachable Appliance

A local-exec provisioner completing without a PowerShell exception is not proof that GIM actually works - the installer can exit 0, or a file copy and scheduled task can all complete cleanly, against a host that never ends up with a running agent (or, as a degenerate case, against the wrong host entirely if DNS/IP resolution is stale). Worse, the GIM service can come up and stay `Running` even when it's misconfigured to talk to the wrong Guardium appliance - the service doesn't crash just because registration fails (see the "Failed sending REGISTER message" entry under [Troubleshooting](#troubleshooting)). To close both gaps, **every path that can lead to a `SUCCESS`/`SKIPPED_ALREADY_INSTALLED` result runs two checks, in order, before reporting success**:

1. **Service check** - the script queries `Get-Service -Name "GIM"` on the target (over the same channel used to install - WinRM session, SSH, or a small SMB scheduled task) and polls for up to ~15 seconds. If the service exists but is stopped, it attempts `Start-Service -Name "GIM"` once, then keeps polling. If it's still not `Running`, the run **throws and reports `FAILED`**, even though the installer itself returned exit code 0.
2. **Appliance reachability check** - only once the service is confirmed `Running`, the script opens a TCP connection *from the target* to `gim_server_host:gim_server_port` (5-second timeout). If that connect fails, the run **throws and reports `FAILED`** - a running service alone is not accepted as success if the agent can't actually reach Guardium.

Both checks run on the [skip-if-already-installed](#skip-if-already-installed-real-target-state-not-just-terraform-state) path too - matching `gimver` isn't enough either if the service is stopped or the appliance is unreachable.

Separately, malformed input is caught even earlier: a `lifecycle.precondition` on the resource rejects any `gim_server_host` / `local_ip` / `failover_gim_server_host` value that's IPv4-shaped (every dot-separated segment is purely numeric) but not a valid IPv4 address - for example a missing dot (`9.46194.103` instead of `9.46.194.103`). That fails `terraform plan`/`apply` outright, before any target is ever touched.

Together, this means a green `terraform apply` is a real signal that the agent is installed, running, *and* able to reach the appliance you configured - not just that a script executed without error.

### Uninstalling GIM (`terraform destroy`)

When `uninstall_on_destroy = true` (default), destroying a server's resource runs GIM's uninstall procedure on the target before it's removed from state, using the same deployment method (SMB/WinRM/SSH) that was used to install. The uninstaller is located in this order (matching how GIM actually registers itself on the target - as a standard InstallShield product in the Windows Uninstall registry):

1. **Registry (primary)** - the `HKLM\...\Uninstall\*` entry whose `DisplayName` matches `*Guardium*` or `Publisher` is `IBM` (real-world `DisplayName` is `"IBM(R) Guardium(R) GIM"` - note it does *not* contain the words "Installation Manager", despite IBM's own docs calling the product that). Its `QuietUninstallString`/`UninstallString` gives the uninstaller's path.
2. **Known fixed path (fallback)** - `C:\Windows\$IBM Windows GIM$\Setup.exe`, used if no usable registry entry is found.
3. **Install directory search (last resort)** - a kept `GIM*Installer*` copy under the configured `install_dir`.

Whichever is found is run as `setup.exe -UNINSTALL -UNATTENDED`. If none of the three are found, the run is treated as `UNINSTALL_SKIPPED` (not a failure) - GIM is assumed already removed. Uninstall failures are logged as a warning rather than blocking `terraform destroy` (so a temporarily-unreachable host doesn't strand your state); check `runner_log_dir/<server>-uninstall.log` if a destroy reports a warning. Set `uninstall_on_destroy = false` to only remove the resource from Terraform state and leave GIM installed.

### Remote Log Collection

When `collect_remote_logs = true` (default), after installation each script best-effort copies the GIM client's own logs from the target back to `runner_log_dir/<server>/` on the runner:
- `<InstallDir>\modules\GIM\current\GIM.log` - operation/connection log
- `<InstallDir>\central_logger.log`
- `C:\IBM Windows GIM.ctl` - installer log

Collection never fails the overall run; missing files are logged and skipped.

### Installation Parameters

The installer is executed with IBM-standard parameters:

```powershell
Setup.exe -UNATTENDED `
  -LOCALIP <server-ip> `
  -APPLIANCE <guardium-ip> `
  -LISTENER_PORT <port> `
  -INSTALLPATH <install-dir> `
  [-GIM_AUTO_SET_CLIENT_IP 1] `
  [-FAILOVER_APPLIANCE <failover-ip>] `
  [-SHARED_SECRET <secret>] `
  [-KEY_FILE <path> -CERT_FILE <path> [-CA_FILE <path>]]
```

**Parameters:**
- `-UNATTENDED` - Silent installation mode
- `-LOCALIP` - IP address of Windows server (auto-detected if not specified); omitted when `auto_assign_ip = 1`
- `-APPLIANCE` - Guardium central manager IP/hostname
- `-LISTENER_PORT` - GIM listener port (default: 8445 per IBM documentation; only passed when `listener_port = true`)
- `-INSTALLPATH` - Installation directory (default: `C:\Program Files\IBM\Guardium Installation Manager`)
- `-GIM_AUTO_SET_CLIENT_IP` - Passed instead of `-LOCALIP` when `auto_assign_ip = 1` in `servers.csv` (IBM: never pass both)
- `-FAILOVER_APPLIANCE` - Optional failover Guardium appliance, from `failover_gim_server_host` in `servers.csv`
- `-SHARED_SECRET` - Optional shared secret (if required), from `shared_secret` in `servers.csv`
- `-KEY_FILE` / `-CERT_FILE` / `-CA_FILE` - Custom TLS cert paths **on the target**, only passed when `gim_key_file` and `gim_cert_file` are both set in `servers.csv`; the actual PEM files are copied there automatically from the runner first - see [Custom TLS certificates](#custom-tls-certificates-optional)

## Troubleshooting

### Common Issues

#### "powershell: executable file not found" (Linux/macOS runner)

**Cause:** Terraform runs PowerShell as the provisioner interpreter for every deployment method (SMB, WinRM, SSH), but PowerShell Core (`pwsh`) is not installed on the Linux/macOS runner.

**Solution:** Install PowerShell Core:
```bash
# Ubuntu/Debian
curl -sSL https://aka.ms/install-powershell.sh | sudo bash
sudo apt-get install -y powershell

# RHEL/CentOS/Fedora
curl -sSL https://aka.ms/install-powershell.sh | sudo bash
sudo yum install -y powershell

# macOS
brew install --cask powershell
```

#### "Failed sending REGISTER message ... Can't connect to sqlguard server"

**Cause:** Network connectivity issue from the target host to the Guardium appliance (see [Network Requirements](#network-requirements) above for required ports and security group rules).

**Solution:**
1. From the target host, test connectivity: `Test-NetConnection -ComputerName <guardium-ip> -Port 8446`
2. Check the target's outbound firewall/security group rules allow TCP `8446` (required) and `8443` (optional, discovery)
3. Verify the Guardium appliance is running and listening on those ports

**Note:** GIM itself treats this as a soft failure internally (the service keeps running and retries), but this module does **not** report `terraform apply` as successful in that case - see [Success Requires a Verified Running Service and a Reachable Appliance](#success-requires-a-verified-running-service-and-a-reachable-appliance). The run will fail with a clear error until the target can reach `gim_server_host:gim_server_port`, so fix connectivity and re-run `terraform apply` (or, if GIM is already correctly installed and just temporarily lost network access, simply re-running once connectivity is restored will pass).

#### "This parameter set requires WSMan" (Windows from Mac)

**Cause:** PowerShell on macOS doesn't have WinRM client support, but `windows_deployment_method` is set to `"winrm"` (or the legacy `windows_use_ssh` fallback isn't set).

**Solutions:**
1. **Use SMB (recommended):** Set `windows_deployment_method = "smb"` - works from any platform, no WinRM or SSH required, only File and Printer Sharing (port 445) on the targets.
2. **Use SSH:** Set `windows_deployment_method = "ssh"` and install OpenSSH Server on Windows hosts.
3. **Run from Windows:** Use a Windows machine as Terraform runner with `windows_deployment_method = "winrm"`.

#### "Installer not found" (Windows)

**Cause:** `Setup.exe` or `.exe.signed` file not found in installer directory.

**Solution:**
1. Verify `gim_kit_version` (servers.csv) or `default_gim_kit_version` (tfvars) matches an existing `windows_gim_packages_base_dir/Guardium_<version>_GIM_Windows` folder - or that `windows_gim_installer_dir` points to the correct directory if using the legacy explicit path
2. Ensure `GIM-Installer-*/Setup.exe` exists, or `.exe.signed` files are in `Gim-Kits/`
3. Check file permissions

#### Installation succeeds but GIM folder not found on Windows

**Cause:** Installer may have failed silently or used a different path.

**Solution:**
1. Check installer log: `C:\IBM Windows GIM.ctl` on Windows host
2. Verify installer exit code in Terraform logs
3. Check if GIM service is running: `Get-Service | Where-Object {$_.Name -like "*guard*"}`

### Debugging Tips

**Enable verbose logging:**
- Check individual log files in `logs/` directory
- Each host has its own log file with timestamps

**Test connectivity manually:**

**Windows (WinRM):**
```powershell
# Test WinRM
Test-WSMan -ComputerName hostname -Port 5986

# Test Guardium connectivity from target
Invoke-Command -ComputerName hostname -ScriptBlock { Test-NetConnection -ComputerName guardium-ip -Port 8446 }
```

**Windows (SSH):**
```bash
# Test SSH
ssh Administrator@hostname

# Test Guardium connectivity from target
ssh Administrator@hostname "powershell -Command 'Test-NetConnection -ComputerName guardium-ip -Port 8446'"
```

**Check Terraform state:**
```bash
terraform show
terraform state list
```

## Security Notes

### Credentials Management

**⚠️ Important Security Considerations:**

1. **Never commit passwords to Git:**
   - Use `.gitignore` to exclude `terraform.tfvars` and `servers.csv`
   - Use environment variables or secret management tools

2. **Passwords are currently required:** `password` in `servers.csv` is a mandatory column, and it's passed through to (and logged as "set", never in plaintext, by) whichever deployment script runs. The `pem_key_path` CSV column exists for schema compatibility only - the underlying SSH script (`install_gim_windows_ssh.ps1`) has an `-SshKeyPath` parameter for key-based auth, but `examples/windows-gdp-gim/main.tf` doesn't currently wire `pem_key_path` through to it, so key-based auth isn't available end-to-end yet.

3. **Protect log files:**
   - Logs contain passwords and sensitive information
   - Review `logs/` directory before sharing
   - Add `logs/` to `.gitignore`

4. **Network security:**
   - Use VPN or private networks when possible
   - Restrict SSH/WinRM access to trusted IPs
   - Use firewall rules to limit access

### Best Practices

1. **Least privilege:** Use accounts with minimal required permissions
2. **Audit logs:** Review installation logs regularly
3. **Rotate credentials:** Change passwords/keys periodically
4. **Encrypt sensitive data:** Use Terraform's encryption or external secret management

## Advanced Configuration

### Explicit Installer Path (bypass auto-resolution)

To pin an exact installer directory instead of resolving it from `gim_kit_version`/`default_gim_kit_version`, set the legacy path variable directly:

```hcl
# In terraform.tfvars
windows_gim_installer_dir = "./packages/windows/Guardium_12.2.1.205_GIM_Windows"
```
See [Installer Directory Resolution](#installer-directory-resolution-multi-version-kit-support) for how this interacts with `gim_kit_version`.

### Central Summary Log

Every install/uninstall run appends a row to a central CSV summarizing all attempts:

```hcl
central_summary_csv_path = "./logs/central-summary.csv"
```
Format: `Timestamp,ServerName,Status,GIMServer,InstallDirectory,ListenerPort,DurationSeconds,ErrorMessage` - see [Check Installation Status](#check-installation-status) for a worked example.

### Force Re-installation of an Already-Installed Agent

By default (`skip_if_already_installed = true`), a server whose `gimver` marker already matches the resolved kit version is skipped - see [Skip-If-Already-Installed](#skip-if-already-installed-real-target-state-not-just-terraform-state). To force a reinstall anyway:

```bash
terraform taint 'null_resource.install_gim_windows["server-name"]'
terraform apply
```
Or set `skip_if_already_installed = false` to always (re)run the installer for every server.

## File Structure

```
terraform-windows-gdp-gim/
├── README.md                    # This file
├── scripts/
│   └── windows/
│       ├── install_gim_windows.ps1       # WinRM deployment (install/uninstall)
│       ├── install_gim_windows_smb.ps1   # SMB + scheduled task deployment (recommended)
│       ├── install_gim_windows_ssh.ps1   # SSH deployment (used when windows_deployment_method = "ssh")
│       ├── install_gim_windows_ssh.sh    # Legacy bash SSH variant, not invoked by any .tf file
│       └── generate_test_certs.sh        # Helper for generating test TLS certs (see docs/TESTING_WITH_CERT.md)
└── examples/
    └── windows-gdp-gim/                    # Self-contained working example - this is what you actually run
        ├── main.tf               # Real deployment logic: CSV parsing, installer resolution, install/uninstall provisioners
        ├── variables.tf
        ├── terraform.tfvars      # Your configuration (gitignored)
        ├── terraform.tfvars.example
        ├── inventory/
        │   ├── servers.csv         # Your server inventory (gitignored)
        │   └── servers.csv.example
        ├── packages/
        │   └── windows/
        │       └── Guardium_<version>_GIM_Windows/  # One folder per GIM kit version; see Multi-Version Kit Support
        └── logs/                 # Per-host logs, central-summary.csv, and collected remote GIM logs (generated)
```

**Note:** The root `main.tf`/`variables.tf`/`outputs.tf` are a separate, generic module skeleton (kept for Terraform Registry structure - see `REGISTRY.md`); `examples/windows-gdp-gim/main.tf` does not call it as a module and has its own complete, actively-maintained implementation. When following this README, all paths and commands refer to `examples/windows-gdp-gim/`.

## Support and Contributing

For issues and questions:
- Create an issue in this repository
- Contact the maintainers listed in [MAINTAINERS.md](MAINTAINERS.md)

### Getting Help

1. Check the [Troubleshooting](#troubleshooting) section
2. Review log files in `logs/` directory
3. Check IBM Guardium documentation: https://www.ibm.com/docs/en/gdp

### Reporting Issues

When reporting issues, please include:
- Terraform version: `terraform version`
- Operating system and version
- Relevant log files (sanitize passwords)
- Steps to reproduce
- Error messages

## References

- [IBM Guardium Documentation](https://www.ibm.com/docs/en/gdp)
- [Installing GIM client on Windows](https://www.ibm.com/docs/en/gdp/12.x?topic=servers-installing-gim-client-windows-server)
- [Installing GIM and other packages on Windows](https://www.ibm.com/docs/en/gdp/12.x?topic=iuugcws-installing-gim-other-packages-windows-servers-by-using-consolidated-installer)
- [Terraform Documentation](https://www.terraform.io/docs)

---

## Contributing

Contributions are welcome! Please read [CONTRIBUTING.md](CONTRIBUTING.md) for details on our code of conduct and the process for submitting pull requests.


## License

This project is licensed under the Apache 2.0 License - see the [LICENSE](LICENSE) file for details.

```text
#
# Copyright (c) IBM Corp. 2026
# SPDX-License-Identifier: Apache-2.0
#
```

## Authors

Module is maintained by IBM with help from [these awesome contributors](https://github.com/IBM/terraform-guardium-datastore-va/graphs/contributors).

## Recent Updates

