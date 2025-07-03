#!/bin/bash
# Verifies the signature on checksums.json with public_key.pem.
# If that passes, it also re-computes each file's hash and compares.

# Check if we're running with bash
if [ -z "$BASH_VERSION" ]; then
    echo "❌ Error: This script requires bash, but it's being run with: $0"
    echo "   Please run with: bash $0 or ./$0"
    exit 1
fi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

OUTFILE="${WORKSPACE_ROOT}/checksums.json"
SIGFILE="${OUTFILE}.sig"
PUBLIC_KEY="${SCRIPT_DIR}/public_key.pem"
PUBLIC_KEY_ENV=""

# Function to show usage
show_usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Validates checksums and verifies cryptographic signature.

OPTIONS:
    -h, --help              Show this help message
    -f, --file FILE         Custom checksums file (default: checksums.json)
    -k, --key FILE          Custom public key file
    --key-env VAR           Read public key from environment variable

EXAMPLES:
    $0                                    # Validate with default settings
    $0 --file custom-checksums.json      # Use custom checksums file
    $0 --key-env PUBLIC_KEY              # Read public key from environment variable

ENVIRONMENT VARIABLES:
    SCALR_PUBLIC_KEY                      # Public key content (alternative to file)
    PUBLIC_KEY                            # Public key content (alternative to file)
EOF
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_usage
            exit 0
            ;;
        -f|--file)
            OUTFILE="$2"
            SIGFILE="${OUTFILE}.sig"
            shift 2
            ;;
        -k|--key)
            PUBLIC_KEY="$2"
            shift 2
            ;;
        --key-env)
            PUBLIC_KEY_ENV="$2"
            shift 2
            ;;
        *)
            echo "❌ Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

echo "🔍 Starting signature validation for Scalr EventBridge integration..."
echo "📁 Workspace: ${WORKSPACE_ROOT}"
echo "📄 Checksums file: ${OUTFILE}"

# Check if required files exist
if [[ ! -f "${OUTFILE}" ]]; then
    echo "❌ Error: checksums.json not found at ${OUTFILE}"
    exit 1
fi

if [[ ! -f "${SIGFILE}" ]]; then
    echo "❌ Error: Signature file not found at ${SIGFILE}"
    exit 1
fi

# Determine public key source
PUBLIC_KEY_CONTENT=""
PUBLIC_KEY_SOURCE=""

# Check for environment variable (priority order: custom env var, SCALR_PUBLIC_KEY, PUBLIC_KEY)
if [[ -n "${PUBLIC_KEY_ENV}" ]]; then
    if [[ -n "${!PUBLIC_KEY_ENV}" ]]; then
        PUBLIC_KEY_CONTENT="${!PUBLIC_KEY_ENV}"
        PUBLIC_KEY_SOURCE="environment variable ${PUBLIC_KEY_ENV}"
    else
        echo "❌ Error: Environment variable ${PUBLIC_KEY_ENV} is not set or empty"
        exit 1
    fi
elif [[ -n "${SCALR_PUBLIC_KEY:-}" ]]; then
    PUBLIC_KEY_CONTENT="${SCALR_PUBLIC_KEY}"
    PUBLIC_KEY_SOURCE="environment variable SCALR_PUBLIC_KEY"
elif [[ -n "${PUBLIC_KEY:-}" && "${PUBLIC_KEY}" != "${SCRIPT_DIR}/public_key.pem" ]]; then
    # Only use PUBLIC_KEY env var if it's different from our default file path
    PUBLIC_KEY_CONTENT="${PUBLIC_KEY}"
    PUBLIC_KEY_SOURCE="environment variable PUBLIC_KEY"
fi

if [[ -n "${PUBLIC_KEY_CONTENT}" ]]; then
    echo "🔓 Using public key from ${PUBLIC_KEY_SOURCE}"

    # Create temporary file for the key
    TEMP_KEY=$(mktemp)
    echo "${PUBLIC_KEY_CONTENT}" > "${TEMP_KEY}"
    chmod 644 "${TEMP_KEY}"
    PUBLIC_KEY_FILE="${TEMP_KEY}"
else
    # Use public key from file (original behavior)
    if [[ ! -f "${PUBLIC_KEY}" ]]; then
        echo "❌ Error: Public key not found at ${PUBLIC_KEY}"
        echo ""
        echo "Options to provide a public key:"
        echo "   1. Generate a key pair:"
        echo "      ./scripts/setup_keys.sh"
        echo ""
        echo "   2. Use an environment variable:"
        echo "      export SCALR_PUBLIC_KEY=\"\$(cat your-public-key.pem)\""
        echo "      $0"
        echo ""
        echo "   3. Specify a custom environment variable:"
        echo "      export MY_PUBLIC_KEY=\"\$(cat your-public-key.pem)\""
        echo "      $0 --key-env MY_PUBLIC_KEY"
        exit 1
    fi

    echo "🔓 Using public key from file: ${PUBLIC_KEY}"
    PUBLIC_KEY_FILE="${PUBLIC_KEY}"
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
if openssl dgst -sha256 -verify "${PUBLIC_KEY_FILE}" \
                -signature "${SIGFILE}" "${OUTFILE}" > /dev/null 2>&1; then
    echo "✅ Signature verification passed"
else
    echo "❌ Signature verification failed"
    echo "   The checksums.json file may have been tampered with"

    # Clean up temporary key file if it exists
    [[ -n "${PUBLIC_KEY_CONTENT}" ]] && rm -f "${TEMP_KEY}"
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

# Clean up temporary key file if it exists
[[ -n "${PUBLIC_KEY_CONTENT}" ]] && rm -f "${TEMP_KEY}"

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
