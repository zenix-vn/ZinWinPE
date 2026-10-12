#!/usr/bin/env bash
# Creates the ZinWinPE MOK signing key (design 5.2 step 2). Run ONCE in WSL/Linux.
# The private key stays in boot/mok/ (git-ignored). Back it up offline (USB/password manager);
# losing it means every machine has to enroll a new key.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p mok
if [[ -f mok/ZinWinPE.key ]]; then echo "mok/ZinWinPE.key already exists - refusing to overwrite"; exit 1; fi
openssl req -new -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 \
  -subj "/CN=ZinWinPE Secure Boot Signing Key/O=ZinWinPE/" \
  -addext "extendedKeyUsage=codeSigning" \
  -keyout mok/ZinWinPE.key -out mok/ZinWinPE.crt
openssl x509 -in mok/ZinWinPE.crt -outform DER -out mok/ZinWinPE.cer
chmod 600 mok/ZinWinPE.key
echo "OK: mok/ZinWinPE.key (PRIVATE - do not commit), mok/ZinWinPE.crt, mok/ZinWinPE.cer"
