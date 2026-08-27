#!/usr/bin/env bash
#
# Copyright (c) IBM Corp. 2026
# SPDX-License-Identifier: Apache-2.0
#

set -euo pipefail

#############################################
# Windows GIM installer via SSH (for runners without WinRM, e.g. macOS)
# Requires OpenSSH Server on the Windows host. Use mgmt_port=22 in CSV for SSH.
#############################################

MGMT_PORT=22
INSTALL_DIR_WIN="C:\\Program Files\\IBM\\Guardium Installation Manager"
REMOTE_DIR="guardium_gim"   # under user's home on Windows (e.g. C:\Users\Administrator\guardium_gim)

HOST=""
USER=""
PASS=""
SSH_KEY=""
GIM_SERVER=""
GIM_SERVER_PORT=8446
INSTALLER_DIR=""
LOG_FILE=""

usage() {
  echo "Usage: install_gim_windows_ssh.sh --host --mgmt-port 22 --username (--password|--ssh-key) --gim-server --installer-dir --log-file"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) HOST="$2"; shift 2;;
    --mgmt-port) MGMT_PORT="$2"; shift 2;;
    --username) USER="$2"; shift 2;;
    --password) PASS="$2"; shift 2;;
    --ssh-key) SSH_KEY="$2"; shift 2;;
    --gim-server) GIM_SERVER="$2"; shift 2;;
    --gim-server-port) GIM_SERVER_PORT="$2"; shift 2;;
    --installer-dir) INSTALLER_DIR="$2"; shift 2;;
    --install-dir) INSTALL_DIR_WIN="$2"; shift 2;;
    --log-file) LOG_FILE="$2"; shift 2;;
    *) echo "ERROR: Unknown argument $1"; usage;;
  esac
done

[[ -z "$HOST" || -z "$USER" || -z "$GIM_SERVER" || -z "$INSTALLER_DIR" || -z "$LOG_FILE" ]] && usage
[[ -z "$PASS" && -z "$SSH_KEY" ]] && usage
[[ ! -d "$INSTALLER_DIR" ]] && { echo "ERROR: InstallerDir not found: $INSTALLER_DIR"; exit 1; }

mkdir -p "$(dirname "$LOG_FILE")"
log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" | tee -a "$LOG_FILE"; }

SSH_OPTS="-o StrictHostKeyChecking=accept-new -o LogLevel=ERROR"
ssh_exec() {
  if [[ -n "$SSH_KEY" ]]; then
    ssh -i "$SSH_KEY" -p "$MGMT_PORT" $SSH_OPTS "$USER@$HOST" "$@"
  else
    sshpass -p "$PASS" ssh -p "$MGMT_PORT" $SSH_OPTS "$USER@$HOST" "$@"
  fi
}

log "Starting Windows GIM installation (SSH)"
log "Target: $HOST (port $MGMT_PORT)"
log "GIM server: $GIM_SERVER:$GIM_SERVER_PORT"
log "InstallerDir (runner): $INSTALLER_DIR"

# Find installer exe (Setup.exe in GIM-Installer-* folder, or setup.exe, or guard-GIM-*.exe.signed)
SETUP_EXE=""
SETUP_PATH=""
# Prefer Setup.exe in GIM-Installer-* subdirectory (IBM standard structure)
for dir in "$INSTALLER_DIR"/GIM-Installer-*; do
  if [[ -d "$dir" && -f "$dir/Setup.exe" ]]; then
    SETUP_EXE="Setup.exe"
    SETUP_PATH="$dir"
    break
  fi
done
# Fallback: setup.exe in root
if [[ -z "$SETUP_EXE" && -f "$INSTALLER_DIR/setup.exe" ]]; then
  SETUP_EXE="setup.exe"
  SETUP_PATH="$INSTALLER_DIR"
fi
# Fallback: Setup.exe in root (case-insensitive check)
if [[ -z "$SETUP_EXE" && -f "$INSTALLER_DIR/Setup.exe" ]]; then
  SETUP_EXE="Setup.exe"
  SETUP_PATH="$INSTALLER_DIR"
fi
# Fallback: .exe.signed files (for consolidated installer approach)
if [[ -z "$SETUP_EXE" ]]; then
  for f in "$INSTALLER_DIR"/*.exe.signed; do
    if [[ -f "$f" ]]; then
      SETUP_EXE=$(basename "$f")
      SETUP_PATH="$INSTALLER_DIR"
      break
    fi
  done
fi
# Last fallback: guard-GIM*.exe
if [[ -z "$SETUP_EXE" ]]; then
  for f in "$INSTALLER_DIR"/guard-GIM*.exe; do
    if [[ -f "$f" ]]; then
      SETUP_EXE=$(basename "$f")
      SETUP_PATH="$INSTALLER_DIR"
      break
    fi
  done
fi
[[ -z "$SETUP_EXE" ]] && { log "ERROR: No Setup.exe, setup.exe, or guard-GIM*.exe(.signed) found in $INSTALLER_DIR"; exit 1; }
log "Using installer: $SETUP_PATH/$SETUP_EXE"

# Create remote dir and copy installer (copy entire installer directory structure)
log "Creating remote directory and copying installer..."
ssh_exec "mkdir -p $REMOTE_DIR" 2>/dev/null || ssh_exec "if (!(Test-Path $REMOTE_DIR)) { New-Item -ItemType Directory -Force -Path $REMOTE_DIR | Out-Null }" 2>/dev/null || true

# Copy the installer directory structure (GIM-Installer-* folder or root)
if [[ -n "$SETUP_PATH" && "$SETUP_PATH" != "$INSTALLER_DIR" ]]; then
  # Copy the GIM-Installer-* subdirectory
  if [[ -n "$SSH_KEY" ]]; then
    scp -i "$SSH_KEY" -P "$MGMT_PORT" -r $SSH_OPTS "$SETUP_PATH" "$USER@$HOST:$REMOTE_DIR/" || true
  else
    sshpass -p "$PASS" scp -P "$MGMT_PORT" -r $SSH_OPTS "$SETUP_PATH" "$USER@$HOST:$REMOTE_DIR/" || true
  fi
  REMOTE_SETUP_DIR="$REMOTE_DIR/$(basename "$SETUP_PATH")"
else
  # Copy entire installer directory
  if [[ -n "$SSH_KEY" ]]; then
    scp -i "$SSH_KEY" -P "$MGMT_PORT" -r $SSH_OPTS "$INSTALLER_DIR"/* "$USER@$HOST:$REMOTE_DIR/" || true
  else
    sshpass -p "$PASS" scp -P "$MGMT_PORT" -r $SSH_OPTS "$INSTALLER_DIR"/* "$USER@$HOST:$REMOTE_DIR/" || true
  fi
  REMOTE_SETUP_DIR="$REMOTE_DIR"
fi

# Run installer via PowerShell over SSH (IBM format: -UNATTENDED -INSTALLPATH -LOCALIP -APPLIANCE)
INSTALL_DIR_PS=$(echo "$INSTALL_DIR_WIN" | sed 's/\\/\\\\/g')
log "Getting Windows host IP address..."
LOCAL_IP=$(ssh_exec "powershell -NoProfile -Command \"try { (Get-NetIPAddress -AddressFamily IPv4 | Where-Object {\$_.IPAddress -notlike '127.*' -and \$_.IPAddress -notlike '169.254.*'}).IPAddress | Select-Object -First 1 } catch { [System.Net.Dns]::GetHostAddresses([System.Net.Dns]::GetHostName()) | Where-Object {\$_.AddressFamily -eq 'InterNetwork' -and \$_.ToString() -notlike '127.*'} | Select-Object -First 1 -ExpandProperty ToString }\"" | tr -d '\r\n' || echo "$HOST")
[[ -z "$LOCAL_IP" || "$LOCAL_IP" == "$HOST" ]] && LOCAL_IP=$(ssh_exec "hostname -i 2>/dev/null | awk '{print \$1}'" | tr -d '\r\n' || echo "$HOST")
log "Using LOCALIP: $LOCAL_IP"
log "Running installer on remote host..."
# In bash double-quotes \$ sends literal $ to remote; use \$exe so remote PowerShell sees $exe
# IBM docs: Setup.exe -UNATTENDED -LOCALIP <IP> -APPLIANCE <Appliance IP> [-INSTALLPATH <path>]
REMOTE_EXE_PATH="${REMOTE_SETUP_DIR}/${SETUP_EXE}"
log "Installer path: $REMOTE_EXE_PATH"
log "Command: Setup.exe -UNATTENDED -LOCALIP $LOCAL_IP -APPLIANCE $GIM_SERVER -INSTALLPATH $INSTALL_DIR_WIN"

# Run installer and capture exit code properly
INSTALL_OUTPUT=$(ssh_exec "powershell -NoProfile -ExecutionPolicy Bypass -Command \"\$exe = Get-Item '$REMOTE_EXE_PATH' -ErrorAction SilentlyContinue; if (-not \$exe) { \$exe = Get-ChildItem -Path '$REMOTE_SETUP_DIR' -Filter 'Setup.exe' -ErrorAction SilentlyContinue | Select-Object -First 1 }; if (-not \$exe) { \$exe = Get-ChildItem -Path '$REMOTE_SETUP_DIR' -Filter 'setup.exe' -ErrorAction SilentlyContinue | Select-Object -First 1 }; if (-not \$exe) { \$exe = Get-ChildItem -Path '$REMOTE_DIR' -Filter '*.exe.signed' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1 }; if (\$exe) { Write-Host 'Running installer: ' \$exe.FullName; \$proc = Start-Process -FilePath (\$exe.FullName) -ArgumentList '-UNATTENDED', '-LOCALIP', '$LOCAL_IP', '-APPLIANCE', '$GIM_SERVER', '-INSTALLPATH', '$INSTALL_DIR_WIN' -Wait -PassThru -NoNewWindow; Write-Host 'ExitCode:' \$proc.ExitCode; exit \$proc.ExitCode } else { Write-Error 'Installer not found'; exit 1 }\"")
EXIT_CODE=$?

# Extract exit code from output if available
if echo "$INSTALL_OUTPUT" | grep -q "ExitCode:"; then
  EXIT_CODE=$(echo "$INSTALL_OUTPUT" | grep "ExitCode:" | sed 's/.*ExitCode: *//' | tr -d '\r\n')
fi

log "$INSTALL_OUTPUT"

if [[ "$EXIT_CODE" != "0" ]]; then
  log "ERROR: Installer failed with exit code: $EXIT_CODE"
  log "Check installer logs on Windows host: C:\\IBM Windows GIM.ctl"
  log "Verify installer exists at: $REMOTE_EXE_PATH"
  exit 1
fi

log "Installer completed successfully (exit code: $EXIT_CODE)"
log "GIM should be installed at: $INSTALL_DIR_WIN"
log "Verify installation: Check if folder exists: $INSTALL_DIR_WIN"
log "Completed"
