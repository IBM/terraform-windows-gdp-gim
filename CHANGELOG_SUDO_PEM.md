# Changelog: Sudo User and PEM Key Support

## Summary

Added support for:
1. **Sudo users** - Install GIM using non-root users with sudo privileges
2. **PEM key authentication** - Use SSH keys instead of passwords
3. **SLES 16 fix** - Automatically maps SLES 16 to suse-15 bundle (since suse-16 bundles don't exist)

## Changes Made

### 1. Updated `examples/basic/inventory/servers.csv`

Added two new columns:
- `use_sudo`: Set to `true` if user needs sudo, `false` or empty for root
- `pem_key_path`: Path to SSH private key file (leave empty for password auth)

**Example:**
```csv
name,os,host,mgmt_port,username,password,use_sudo,pem_key_path,...
server1,linux,server1.example.com,22,admin,,true,/path/to/key.pem,...
```

### 2. Updated `examples/basic/main.tf`

- Added `use_sudo` and `pem_key_path` to triggers
- Updated script call to pass `--use-sudo` and `--pem-key` parameters
- Used `try()` function for optional CSV columns

### 3. Updated `scripts/unix/install_gim_unix.sh`

**New Parameters:**
- `--use-sudo`: Enable sudo prefix for commands
- `--pem-key`: Path to PEM/SSH private key file

**Changes:**
- Added `USE_SUDO` and `PEM_KEY` variables
- Updated argument parsing to accept new parameters
- Modified `ssh_exec()` function to add sudo prefix when needed
- Updated SSH/SCP commands to use PEM key if provided
- Fixed SLES 16 detection to map to `suse-15` bundle

**Sudo Logic:**
- Commands that need root (systemctl, dnf, yum, apt-get, chmod, etc.) get sudo prefix
- Read-only commands (source, echo, hostname, uname) don't get sudo
- Heredoc commands get wrapped in `sudo bash -c`

**SLES 16 Fix:**
- Detects SLES 16 and automatically maps to `suse-15` kit
- Logs: "Detected platform: sles 16 - mapping to kit: suse-15 (suse-16 bundle not available)"

### 4. Updated `README.md`

- Added `use_sudo` and `pem_key_path` to CSV format documentation
- Added authentication examples (password, PEM key, sudo user)
- Added "Sudo Configuration" section in Advanced Configuration
- Added troubleshooting note for SLES 16
- Updated Features section to mention sudo and PEM key support
- Updated Security Notes to mention PEM key authentication

## Usage Examples

### Example 1: Sudo User with PEM Key
```csv
name,os,host,mgmt_port,username,password,use_sudo,pem_key_path,...
prod-server1,linux,server1.example.com,22,deploy,,true,/home/terraform/.ssh/prod-key.pem,...
```

### Example 2: Root User with Password
```csv
name,os,host,mgmt_port,username,password,use_sudo,pem_key_path,...
test-server1,linux,server1.example.com,22,root,MyPassword123,false,,...
```

### Example 3: Sudo User with Password
```csv
name,os,host,mgmt_port,username,password,use_sudo,pem_key_path,...
dev-server1,linux,server1.example.com,22,admin,DevPass123,true,,...
```

## Requirements

### For Sudo Users:
- Passwordless sudo must be configured on target servers
- User must be in `sudo` or `wheel` group
- See README.md "Sudo Configuration" section for setup instructions

### For PEM Key Authentication:
- PEM key file must exist and be readable by Terraform runner
- Key permissions: `chmod 600 /path/to/key.pem`
- Public key must be in `~/.ssh/authorized_keys` on target servers

## Testing

Test SSH connection before running Terraform:

```bash
# With PEM key
ssh -i /path/to/key.pem -p 22 username@hostname

# With password
sshpass -p 'password' ssh -p 22 username@hostname

# Test sudo
ssh -i /path/to/key.pem username@hostname "sudo whoami"
# Should output: root
```

## Backward Compatibility

- Existing CSV files without `use_sudo` and `pem_key_path` columns will work (defaults to `false` and empty)
- Script still supports `--ssh-key` parameter (legacy, `--pem-key` is preferred)
- Password authentication still works as before
