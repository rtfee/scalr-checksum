#!/usr/bin/env bash
# Sets up RSA key pair for checksum signing and verification
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRIVATE_KEY="${SCRIPT_DIR}/private_key.pem"
PUBLIC_KEY="${SCRIPT_DIR}/public_key.pem"

echo "🔐 Setting up RSA key pair for checksum validation..."
echo "📁 Keys directory: ${SCRIPT_DIR}"

# Check if keys already exist
if [[ -f "${PRIVATE_KEY}" ]] || [[ -f "${PUBLIC_KEY}" ]]; then
    echo ""
    echo "⚠️  Key files already exist:"
    [[ -f "${PRIVATE_KEY}" ]] && echo "   🔑 Private key: ${PRIVATE_KEY}"
    [[ -f "${PUBLIC_KEY}" ]] && echo "   🔓 Public key: ${PUBLIC_KEY}"
    echo ""
    read -p "Do you want to overwrite them? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "❌ Aborted - keeping existing keys"
        exit 0
    fi
    echo ""
fi

echo "🔧 Generating RSA key pair (2048 bits)..."

# Generate private key (using more compatible command)
if openssl genrsa -out "${PRIVATE_KEY}" 2048; then
    echo "✅ Private key generated: ${PRIVATE_KEY}"
else
    echo "❌ Failed to generate private key"
    exit 1
fi

# Generate public key from private key
if openssl rsa -in "${PRIVATE_KEY}" -pubout -out "${PUBLIC_KEY}"; then
    echo "✅ Public key generated: ${PUBLIC_KEY}"
else
    echo "❌ Failed to generate public key"
    exit 1
fi

# Secure the private key
chmod 600 "${PRIVATE_KEY}"
chmod 644 "${PUBLIC_KEY}"

echo ""
echo "🔒 Setting secure permissions..."
echo "   Private key: 600 (read/write for owner only)"
echo "   Public key:  644 (readable by all, writable by owner)"

echo ""
echo "🎉 Key pair setup complete!"
echo ""
echo "Key files created:"
echo "   🔑 Private key: ${PRIVATE_KEY}"
echo "   🔓 Public key:  ${PUBLIC_KEY}"
echo ""
echo "⚠️  IMPORTANT SECURITY NOTES:"
echo "   • Keep the private key (${PRIVATE_KEY##*/}) secure and never share it"
echo "   • The public key (${PUBLIC_KEY##*/}) can be shared safely"
echo "   • Add private_key.pem to your .gitignore if not already present"
echo "   • Consider storing the private key in a secure vault for production use"
echo ""
echo "Next steps:"
echo "   1. Generate checksums: ./scripts/generate_checksums.sh"
echo "   2. Validate checksums: ./scripts/validate_checksums.sh"
