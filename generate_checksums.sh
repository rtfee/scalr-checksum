#!/bin/bash
# Generates checksums.json for all relevant files and signs it with private key

# Check if we're running with bash
if [ -z "$BASH_VERSION" ]; then
    echo "❌ Error: This script requires bash, but it's being run with: $0"
    echo "   Please run with: bash $0 or ./$0"
    exit 1
fi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Default configuration
OUTFILE="${PWD}/checksums.json"
SIGFILE="${OUTFILE}.sig"
PRIVATE_KEY="${SCRIPT_DIR}/private_key.pem"
PRIVATE_KEY_ENV=""
CONFIG_FILE="${SCRIPT_DIR}/checksum_config.json"
VERBOSE=false
INCLUDE_TERRAFORM=true
INCLUDE_PYTHON=true
INCLUDE_CONFIG=true
INCLUDE_SCRIPTS=true
INCLUDE_DOCS=true

# Additional include/exclude patterns
INCLUDE_PATTERNS=()
EXCLUDE_PATTERNS=()

# Function to show usage
show_usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Generates checksums for project files and creates a cryptographic signature.

OPTIONS:
    -h, --help              Show this help message
    -v, --verbose           Enable verbose output
    -c, --config FILE       Use custom configuration file
    -o, --output FILE       Custom output file (default: checksums.json)
    -k, --key FILE          Custom private key file
    --key-env VAR           Read private key from environment variable
    --no-terraform          Skip Terraform files (.tf)
    --no-python            Skip Python files (.py)
    --no-config            Skip configuration files
    --no-scripts           Skip shell scripts (.sh)
    --no-docs              Skip documentation files
    --include PATTERN      Additional file pattern to include (can be used multiple times)
    --exclude PATTERN      File pattern to exclude (can be used multiple times)

EXAMPLES:
    $0                                    # Generate with default settings
    $0 --verbose                          # Generate with verbose output
    $0 --include "*.md" --exclude "test*" # Include markdown, exclude test files
    $0 --no-docs --no-scripts            # Only include code files
    $0 --config custom_config.json       # Use custom configuration
    $0 --key-env PRIVATE_KEY             # Read private key from environment variable

ENVIRONMENT VARIABLES:
    SCALR_PRIVATE_KEY                     # Private key content (alternative to file)
    PRIVATE_KEY                           # Private key content (alternative to file)

CONFIGURATION FILE:
    Create ${CONFIG_FILE} to set default options:
    {
        "include_terraform": true,
        "include_python": true,
        "include_config": true,
        "include_scripts": true,
        "include_docs": true,
        "include_patterns": ["*.md"],
        "exclude_patterns": ["test*", "*.tmp"]
    }
EOF
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_usage
            exit 0
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -c|--config)
            CONFIG_FILE="$2"
            shift 2
            ;;
        -o|--output)
            OUTFILE="$2"
            SIGFILE="${OUTFILE}.sig"
            shift 2
            ;;
        -k|--key)
            PRIVATE_KEY="$2"
            shift 2
            ;;
        --key-env)
            PRIVATE_KEY_ENV="$2"
            shift 2
            ;;
        --no-terraform)
            INCLUDE_TERRAFORM=false
            shift
            ;;
        --no-python)
            INCLUDE_PYTHON=false
            shift
            ;;
        --no-config)
            INCLUDE_CONFIG=false
            shift
            ;;
        --no-scripts)
            INCLUDE_SCRIPTS=false
            shift
            ;;
        --no-docs)
            INCLUDE_DOCS=false
            shift
            ;;
        --include)
            INCLUDE_PATTERNS+=("$2")
            shift 2
            ;;
        --exclude)
            EXCLUDE_PATTERNS+=("$2")
            shift 2
            ;;
        *)
            echo "❌ Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Load configuration file if it exists
if [[ -f "${CONFIG_FILE}" ]]; then
    if command -v jq &> /dev/null; then
        echo "📝 Loading configuration from ${CONFIG_FILE}"

        # Override defaults with config file values
        INCLUDE_TERRAFORM=$(jq -r '.include_terraform // true' "${CONFIG_FILE}")
        INCLUDE_PYTHON=$(jq -r '.include_python // true' "${CONFIG_FILE}")
        INCLUDE_CONFIG=$(jq -r '.include_config // true' "${CONFIG_FILE}")
        INCLUDE_SCRIPTS=$(jq -r '.include_scripts // true' "${CONFIG_FILE}")
        INCLUDE_DOCS=$(jq -r '.include_docs // true' "${CONFIG_FILE}")

        # Load patterns from config
        if jq -e '.include_patterns' "${CONFIG_FILE}" &> /dev/null; then
            while IFS= read -r pattern; do
                INCLUDE_PATTERNS+=("$pattern")
            done < <(jq -r '.include_patterns[]?' "${CONFIG_FILE}")
        fi

        if jq -e '.exclude_patterns' "${CONFIG_FILE}" &> /dev/null; then
            while IFS= read -r pattern; do
                EXCLUDE_PATTERNS+=("$pattern")
            done < <(jq -r '.exclude_patterns[]?' "${CONFIG_FILE}")
        fi
    else
        echo "⚠️  Configuration file found but jq not available - using defaults"
    fi
fi

echo "🔧 Generating checksums for Scalr EventBridge integration..."
echo "📁 Workspace: ${PWD}"
echo "📄 Output: ${OUTFILE}"

if [[ "$VERBOSE" == "true" ]]; then
    echo ""
    echo "🔧 Configuration:"
    echo "   Include Terraform files: ${INCLUDE_TERRAFORM}"
    echo "   Include Python files: ${INCLUDE_PYTHON}"
    echo "   Include config files: ${INCLUDE_CONFIG}"
    echo "   Include scripts: ${INCLUDE_SCRIPTS}"
    echo "   Include documentation: ${INCLUDE_DOCS}"
    [[ ${#INCLUDE_PATTERNS[@]} -gt 0 ]] && echo "   Additional include patterns: ${INCLUDE_PATTERNS[*]}"
    [[ ${#EXCLUDE_PATTERNS[@]} -gt 0 ]] && echo "   Exclude patterns: ${EXCLUDE_PATTERNS[*]}"
fi

# Check if jq is available
if ! command -v jq &> /dev/null; then
    echo "❌ Error: jq is required but not installed"
    echo "   Install with: brew install jq (macOS) or apt-get install jq (Ubuntu)"
    exit 1
fi

echo ""
echo "📋 Step 1: Generating file checksums..."

# Create temporary JSON file
temp_json=$(mktemp)

# Dynamically discover files to include in checksum validation
echo ""
echo "🔍 Discovering files to include in checksums..."

# Initialize array for discovered files
files_to_check=()

# Helper function to check if file should be excluded
should_exclude_file() {
    local file="$1"
    # Remove leading ./ for consistent matching
    file="${file#./}"

    for pattern in "${EXCLUDE_PATTERNS[@]}"; do
        # Use bash pattern matching for globs
        if [[ "$file" == $pattern ]]; then
            [[ "$VERBOSE" == "true" ]] && echo "   ⚠️  Excluding $file (matches pattern: $pattern)"
            return 0  # Should exclude
        fi
    done
    return 1  # Should not exclude
}

# Find Terraform files (.tf)
if [[ "$INCLUDE_TERRAFORM" == "true" ]]; then
    [[ "$VERBOSE" == "true" ]] && echo "   Looking for Terraform files (.tf)..."
    while IFS= read -r -d '' file; do
        if ! should_exclude_file "$file"; then
            files_to_check+=("$file")
        fi
    done < <(find . -name "*.tf" -type f -not -path "./.terraform/*" -not -path "./.*" -print0 | sort -z)
fi

# Find Python files (.py)
if [[ "$INCLUDE_PYTHON" == "true" ]]; then
    [[ "$VERBOSE" == "true" ]] && echo "   Looking for Python files (.py)..."
    while IFS= read -r -d '' file; do
        if ! should_exclude_file "$file"; then
            files_to_check+=("$file")
        fi
    done < <(find . -name "*.py" -type f -not -path "./.*" -not -path "./.terraform/*" -print0 | sort -z)
fi

# Find configuration files
if [[ "$INCLUDE_CONFIG" == "true" ]]; then
    [[ "$VERBOSE" == "true" ]] && echo "   Looking for configuration files..."
    config_patterns=("*.json" "*.yaml" "*.yml" "*.toml" "*.ini" "*.cfg")
    for pattern in "${config_patterns[@]}"; do
        while IFS= read -r -d '' file; do
            # Skip checksums.json and its signature
            if [[ "$file" != "./checksums.json" && "$file" != "./checksums.json.sig" ]] && ! should_exclude_file "$file"; then
                files_to_check+=("$file")
            fi
        done < <(find . -name "$pattern" -type f -not -path "./.*" -not -path "./.terraform/*" -print0 2>/dev/null | sort -z)
    done
fi

# Find shell scripts (.sh)
if [[ "$INCLUDE_SCRIPTS" == "true" ]]; then
    [[ "$VERBOSE" == "true" ]] && echo "   Looking for shell scripts (.sh)..."
    while IFS= read -r -d '' file; do
        if ! should_exclude_file "$file"; then
            files_to_check+=("$file")
        fi
    done < <(find . -name "*.sh" -type f -not -path "./.*" -print0 | sort -z)
fi

# Find README and LICENSE files
if [[ "$INCLUDE_DOCS" == "true" ]]; then
    [[ "$VERBOSE" == "true" ]] && echo "   Looking for documentation files..."
    doc_patterns=("README*" "LICENSE*" "CHANGELOG*" "CONTRIBUTING*")
    for pattern in "${doc_patterns[@]}"; do
        while IFS= read -r -d '' file; do
            if ! should_exclude_file "$file"; then
                files_to_check+=("$file")
            fi
        done < <(find . -name "$pattern" -type f -not -path "./.*" -print0 2>/dev/null | sort -z)
    done
fi

# Find additional patterns from include list
if [[ ${#INCLUDE_PATTERNS[@]} -gt 0 ]]; then
    [[ "$VERBOSE" == "true" ]] && echo "   Looking for additional patterns: ${INCLUDE_PATTERNS[*]}"
    for pattern in "${INCLUDE_PATTERNS[@]}"; do
        while IFS= read -r -d '' file; do
            if ! should_exclude_file "$file"; then
                files_to_check+=("$file")
            fi
        done < <(find . -name "$pattern" -type f -not -path "./.*" -not -path "./.terraform/*" -print0 2>/dev/null | sort -z)
    done
fi

# Remove duplicates and sort
files_to_check_unique=()
while IFS= read -r file; do
    files_to_check_unique+=("$file")
done < <(printf '%s\n' "${files_to_check[@]}" | sort -u)
files_to_check=("${files_to_check_unique[@]}")

# Convert to relative paths (remove leading ./)
for i in "${!files_to_check[@]}"; do
    files_to_check[$i]="${files_to_check[$i]#./}"
done

echo "   📊 Found ${#files_to_check[@]} files to include in checksums"

if [[ "$VERBOSE" == "true" && ${#files_to_check[@]} -gt 0 ]]; then
    echo ""
    echo "📋 Files to be included:"
    for file in "${files_to_check[@]}"; do
        echo "   • $file"
    done
fi

# Start JSON object
echo "{" > "${temp_json}"
first=true

total_files=0
processed_files=0

for file in "${files_to_check[@]}"; do
    total_files=$((total_files + 1))

    if [[ -f "$file" ]]; then
        echo "   Processing ${file}..."
        hash=$(sha256sum "$file" | awk '{print $1}')

        # Add comma if not first entry
        if [[ $first == true ]]; then
            first=false
        else
            echo "," >> "${temp_json}"
        fi

        # Add entry to JSON
        echo -n "  \"${file}\": \"${hash}\"" >> "${temp_json}"
        processed_files=$((processed_files + 1))
    else
        echo "   ⚠️  Skipping ${file} (not found)"
    fi
done

# Close JSON object
echo "" >> "${temp_json}"
echo "}" >> "${temp_json}"

# Format JSON properly
jq . "${temp_json}" > "${OUTFILE}"
rm "${temp_json}"

echo ""
echo "📊 Checksum Generation Summary:"
echo "   Total files considered: ${total_files}"
echo "   Files processed: ${processed_files}"
echo "   Checksums file: ${OUTFILE}"

echo ""
echo "🔐 Step 2: Generating cryptographic signature..."

# Determine private key source
PRIVATE_KEY_CONTENT=""
PRIVATE_KEY_SOURCE=""

# Check for environment variable (priority order: custom env var, SCALR_PRIVATE_KEY, PRIVATE_KEY)
if [[ -n "${PRIVATE_KEY_ENV}" ]]; then
    if [[ -n "${!PRIVATE_KEY_ENV}" ]]; then
        PRIVATE_KEY_CONTENT="${!PRIVATE_KEY_ENV}"
        PRIVATE_KEY_SOURCE="environment variable ${PRIVATE_KEY_ENV}"
    else
        echo "❌ Error: Environment variable ${PRIVATE_KEY_ENV} is not set or empty"
        exit 1
    fi
elif [[ -n "${SCALR_PRIVATE_KEY:-}" ]]; then
    PRIVATE_KEY_CONTENT="${SCALR_PRIVATE_KEY}"
    PRIVATE_KEY_SOURCE="environment variable SCALR_PRIVATE_KEY"
elif [[ -n "${PRIVATE_KEY:-}" && "${PRIVATE_KEY}" != "${SCRIPT_DIR}/private_key.pem" ]]; then
    # Only use PRIVATE_KEY env var if it's different from our default file path
    PRIVATE_KEY_CONTENT="${PRIVATE_KEY}"
    PRIVATE_KEY_SOURCE="environment variable PRIVATE_KEY"
fi

if [[ -n "${PRIVATE_KEY_CONTENT}" ]]; then
    # Use private key from environment variable
    echo "🔑 Using private key from ${PRIVATE_KEY_SOURCE}"

    # Create temporary file for the key
    TEMP_KEY=$(mktemp)
    echo "${PRIVATE_KEY_CONTENT}" > "${TEMP_KEY}"
    chmod 600 "${TEMP_KEY}"

    # Sign the checksums file
    if openssl dgst -sha256 -sign "${TEMP_KEY}" \
                    -out "${SIGFILE}" "${OUTFILE}"; then
        echo "✅ Signature generated successfully"
        echo "   Signature file: ${SIGFILE}"
    else
        echo "❌ Failed to generate signature"
        rm -f "${TEMP_KEY}"
        exit 1
    fi

    # Clean up temporary key file
    rm -f "${TEMP_KEY}"
else
    # Use private key from file (original behavior)
    if [[ ! -f "${PRIVATE_KEY}" ]]; then
        echo "❌ Error: Private key not found at ${PRIVATE_KEY}"
        echo ""
        echo "Options to provide a private key:"
        echo "   1. Generate a key pair:"
        echo "      openssl genrsa -out ${PRIVATE_KEY} 2048"
        echo "      openssl rsa -in ${PRIVATE_KEY} -pubout -out ${SCRIPT_DIR}/public_key.pem"
        echo "      chmod 600 ${PRIVATE_KEY}"
        echo ""
        echo "   2. Use an environment variable:"
        echo "      export SCALR_PRIVATE_KEY=\"\$(cat your-private-key.pem)\""
        echo "      $0"
        echo ""
        echo "   3. Specify a custom environment variable:"
        echo "      export MY_PRIVATE_KEY=\"\$(cat your-private-key.pem)\""
        echo "      $0 --key-env MY_PRIVATE_KEY"
        exit 1
    fi

    echo "🔑 Using private key from file: ${PRIVATE_KEY}"

    # Sign the checksums file
    if openssl dgst -sha256 -sign "${PRIVATE_KEY}" \
                    -out "${SIGFILE}" "${OUTFILE}"; then
        echo "✅ Signature generated successfully"
        echo "   Signature file: ${SIGFILE}"
    else
        echo "❌ Failed to generate signature"
        exit 1
    fi
fi

echo ""
echo "🎉 Checksum generation complete!"
echo ""
echo "Files created:"
echo "   📄 ${OUTFILE}"
echo "   🔐 ${SIGFILE}"
echo ""
echo "To verify the checksums, run:"
echo "   ./validate_checksums.sh"
