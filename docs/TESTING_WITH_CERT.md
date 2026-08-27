# Running GIM Install with Custom TLS Certificates

This guide walks you through testing the installation **with custom TLS certificates** (CA, client key, and client cert) so the GIM agent uses your own certs to talk to the Guardium central manager. Guardium central manager and failover are set per server in `servers.csv` (`gim_server_host`, `failover_gim_server_host`), not in terraform.tfvars.

## Requirements

- **Key + cert are required together.** The installer only receives cert arguments when both `gim_key_file` and `gim_cert_file` are set.
- **Paths are on the Terraform runner.** The CSV columns (`gim_ca_file`, `gim_key_file`, `gim_cert_file`) must point to files that exist **on the machine running `terraform apply`** (e.g. `C:\Guardium\ca.pem`, `C:\Guardium\client.key`, `C:\Guardium\client.pem`). The deployment scripts copy these files to each target host automatically (into `C:\Windows\Temp\guardium_gim\certs` there) before running the installer - you do not need to pre-stage anything on the targets.
- **CA is optional** (e.g. for self-signed or when the CA is already trusted).

---

## Step 1: Get or generate certificates

You need three PEM files (for testing you can use self-signed certs):

| File   | Description              | Required |
|--------|--------------------------|----------|
| CA     | Certificate authority PEM | Optional (use for custom/listener TLS or self-signed) |
| Key    | Client private key PEM   | **Yes** (with cert) |
| Cert   | Client certificate PEM   | **Yes** (with key) |

**Option A – Generate test certs (OpenSSL)**  
From the project root, run:

```bash
# Linux/macOS or Git Bash / WSL on Windows
./scripts/windows/generate_test_certs.sh
```

This creates `scripts/windows/test_certs/` with `ca.pem`, `client.key`, and `client.pem`. Use these only for **testing**, not production.

**Option B – Use your own CA/key/cert**  
Ensure you have PEM-format files (e.g. from your PKI or Guardium docs).

---

## Step 2: Place the certs somewhere the runner can read

No manual copying to the targets is required - the deployment scripts do that for you. Just make sure the CA, key, and cert PEM files are readable from the machine you'll run `terraform apply` on.

**Example: one shared folder, `C:\Guardium`**

```powershell
mkdir C:\Guardium
```

Put your three files there, e.g.:
- `C:\Guardium\ca.pem`
- `C:\Guardium\client.key`
- `C:\Guardium\client.pem`

If you used the test script, the files are already local at `scripts/windows/test_certs/ca.pem`, `client.key`, and `client.pem` - you can point the CSV directly at those, no copying needed.

---

## Step 3: Add cert columns to `servers.csv`

Use the **20-column** format and set the last three columns for the server(s) that should use custom TLS.

1. Open `examples/basic/inventory/servers.csv`.
2. Add the three headers if missing (they must be the last three columns):
   `gim_ca_file`, `gim_key_file`, `gim_cert_file`
3. For each server that uses custom certs, set the paths **as they are on the Terraform runner** (not the target). Use the same path style (e.g. backslashes). You can quote paths that contain spaces or backslashes.

**Example: 20-column CSV with certs for one server**

```csv
name,os,host,mgmt_port,username,password,use_sudo,pem_key_path,gim_server_host,local_ip,install_dir,perl_path,shared_secret,failover_gim_server_host,auto_assign_ip,check_8443,allow_tls_fallback,gim_ca_file,gim_key_file,gim_cert_file
win-2019,windows,win-2019.dev.fyre.ibm.com,5986,Administrator,Welcome2Guardium!,FALSE,,9.80.59.143,win-2019.dev.fyre.ibm.com,,,,9.80.59.144,0,TRUE,FALSE,,,
win-2022a,windows,win-2022a.dev.fyre.ibm.com,5986,Administrator,Welcome2Guardium!,FALSE,,9.80.59.143,win-2022a.dev.fyre.ibm.com,,,,,0,TRUE,FALSE,C:\Guardium\ca.pem,C:\Guardium\client.key,C:\Guardium\client.pem
win-2025a,windows,win-2025a.dev.fyre.ibm.com,5986,Administrator,Welcome2Guardium!,FALSE,,9.80.59.143,win-2025a.dev.fyre.ibm.com,,,guard,9.80.59.144,0,TRUE,FALSE,,,
```

- Rows with custom TLS: set all three paths (or at least `gim_key_file` and `gim_cert_file`; `gim_ca_file` can be empty for some setups).
- Rows without custom TLS: leave the last three fields empty (`,,,`).
- Every row must have the **same number of columns** (20 here). No extra or missing commas.

---

## Step 4: Run Terraform

From the example directory:

```bash
cd examples/basic
terraform init
terraform plan
terraform apply
```

Terraform will run the install script for each Windows server. For servers with `gim_key_file` and `gim_cert_file` set, the script copies those files (and `gim_ca_file`, when set) from the runner to `C:\Windows\Temp\guardium_gim\certs` on the target, then passes `-KEY_FILE`, `-CERT_FILE`, and `-CA_FILE` (pointing at the copied target paths) to the IBM installer.

---

## Step 5: Check logs

- Per-host log: `./logs/<server_name>.log`
- Look for a line like “Copying custom TLS certificate(s) to ...” confirming the copy happened, followed by the installer command (paths may be redacted). If you see a warning that both key and cert are required, one of the two CSV fields was empty for that server. If a copy step throws `... not found on runner: ...`, the CSV path doesn't exist on the machine running `terraform apply`.

---

## Quick checklist

- [ ] CA, key, and cert PEM files exist **on the Terraform runner** (key + cert required; CA optional).
- [ ] `servers.csv` has 20 columns with `gim_ca_file`, `gim_key_file`, `gim_cert_file` at the end.
- [ ] For each server using certs: all three paths set (or at least key + cert); paths point at files on the runner (e.g. `C:\Guardium\client.key`), not the target.
- [ ] No extra/missing commas (same column count in every row).
- [ ] Run `terraform apply` and check `./logs/<name>.log` for the "Copying custom TLS certificate(s)" line.

For production, use proper PKI-issued certificates and secure the key; the test script is for validation only.
