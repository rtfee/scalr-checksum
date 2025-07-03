#!/usr/bin/env bash
# Verifies the signature on checksums.json with public_key.pem.
# If that passes, it also re-computes each file's hash and compares.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

OUTFILE="${WORKSPACE_ROOT}/checksums.json"
SIGFILE="${OUTFILE}.sig"
PUBLIC_KEY="${SCRIPT_DIR}/public_key.pem"

echo "🔍 Starting signature validation for Scalr EventBridge integration..."
echo "📁 Workspace: ${WORKSPACE_ROOT}"
echo "📄 Checksums file: ${OUTFILE}"
echo "🔐 Public key: ${PUBLIC_KEY}"

# Check if required files exist
if [[ ! -f "${OUTFILE}" ]]; then
    echo "❌ Error: checksums.json not found at ${OUTFILE}"
    exit 1
fi

if [[ ! -f "${SIGFILE}" ]]; then
    echo "❌ Error: Signature file not found at ${SIGFILE}"
    exit 1
fi

if [[ ! -f "${PUBLIC_KEY}" ]]; then
    echo "❌ Error: Public key not found at ${PUBLIC_KEY}"
    exit 1
fi

# Check if jq is available
if ! command -v jq &> /dev/null; then
    echo "❌ Error: jq is required but not installed"
    echo "   Install with: brew install jq (macOS) or apt-get install jq (Ubuntu)"
    exit 1
fi

echo ""
echo "🔐 Step 1: Cryptographic signature verification..."

# 1. Cryptographic signature check
if openssl dgst -sha256 -verify "${PUBLIC_KEY}" \
                -signature "${SIGFILE}" "${OUTFILE}" > /dev/null 2>&1; then
    echo "✅ Signature verification passed"
else
    echo "❌ Signature verification failed"
    echo "   The checksums.json file may have been tampered with"
    exit 1
fi

echo ""
echo "🔍 Step 2: File integrity verification..."

# 2. Compare on-disk files with recorded hashes
fail=0
total_files=0
verified_files=0

cd "${WORKSPACE_ROOT}"

while IFS=$'\t' read -r file hash; do
    total_files=$((total_files + 1))
    
    # Skip empty lines or malformed entries
    if [[ -z "$file" || -z "$hash" ]]; then
        continue
    fi
    
    echo -n "   Checking ${file}... "
    
    if [[ ! -f "$file" ]]; then
        echo "❌ Missing"
        fail=$((fail + 1))
        continue
    fi
    
    current=$(sha256sum "$file" | awk '{print $1}')
    if [[ "$current" != "$hash" ]]; then
        echo "❌ Hash mismatch"
        echo "      Expected: ${hash}"
        echo "      Found:    ${current}"
        fail=$((fail + 1))
    else
        echo "✅ OK"
        verified_files=$((verified_files + 1))
    fi
done < <(jq -r 'to_entries[] | "\(.key)\t\(.value)"' "${OUTFILE}")

echo ""
echo "📊 Verification Summary:"
echo "   Total files checked: ${total_files}"
echo "   Files verified: ${verified_files}"
echo "   Failed verifications: ${fail}"

if [[ $fail -eq 0 ]]; then
    echo ""
    echo "🎉 All verification checks passed!"
    echo "   ✅ Signature is valid"
    echo "   ✅ All ${verified_files} files match recorded checksums"
    echo ""
    echo "Your Scalr EventBridge integration files are verified and secure."
else
    echo ""
    echo "❌ Verification failed!"
    echo "   ${fail} file(s) failed checksum verification"
    echo "   This could indicate file corruption or tampering"
    exit 1
fi 