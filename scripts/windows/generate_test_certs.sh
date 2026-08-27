#!/usr/bin/env bash
#
# Copyright (c) IBM Corp. 2026
# SPDX-License-Identifier: Apache-2.0
#

# Generate self-signed CA and client key/cert for testing GIM custom TLS.
# Usage: run from repo root: ./scripts/windows/generate_test_certs.sh
# Output: scripts/windows/test_certs/ca.pem, client.key, client.pem
# Use only for testing; the deployment scripts copy these files from the runner to each target
# Windows host automatically, so just point servers.csv at the local scripts/windows/test_certs/ paths.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${SCRIPT_DIR}/test_certs"
mkdir -p "$OUT_DIR"
cd "$OUT_DIR"

if ! command -v openssl &>/dev/null; then
  echo "ERROR: openssl is required. Install OpenSSL (e.g. via Git Bash, WSL, or system package)."
  exit 1
fi

echo "Generating test CA and client cert in $OUT_DIR ..."

# CA key and cert
openssl genrsa -out ca.key 2048
openssl req -x509 -new -nodes -key ca.key -sha256 -days 3650 -out ca.pem \
  -subj "/CN=GIM-Test-CA"

# Client key and CSR
openssl genrsa -out client.key 2048
openssl req -new -key client.key -out client.csr \
  -subj "/CN=GIM-Client-Test"

# Sign client cert with CA
openssl x509 -req -in client.csr -CA ca.pem -CAkey ca.key -CAcreateserial \
  -out client.pem -days 3650 -sha256
rm -f client.csr ca.srl

echo "Done. Created:"
echo "  $OUT_DIR/ca.pem"
echo "  $OUT_DIR/client.key"
echo "  $OUT_DIR/client.pem"
echo ""
echo "Set these local (runner) paths in servers.csv - they are copied to each target automatically:"
echo "  gim_ca_file   = $OUT_DIR/ca.pem"
echo "  gim_key_file  = $OUT_DIR/client.key"
echo "  gim_cert_file = $OUT_DIR/client.pem"
echo "See docs/TESTING_WITH_CERT.md for full steps."
