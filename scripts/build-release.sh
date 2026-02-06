#!/bin/bash

# Cross-platform build script for Satibot
# Builds for multiple architectures and creates release artifacts

set -euo pipefail

# Configuration
PROJECT_NAME="satibot"
VERSION="${1:-$(git describe --tags --always --dirty 2>/dev/null || echo "dev")}"
BUILD_DIR="zig-out"
RELEASE_DIR="releases"
BUILD_TYPE="ReleaseSmall"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Clean previous builds
clean_build() {
    print_status "Cleaning previous builds..."
    rm -rf "$RELEASE_DIR"
    mkdir -p "$RELEASE_DIR"
}

# Build for specific target
build_target() {
    local target=$1
    local output_name=$2
    
    print_status "Building for $target..."
    
    if zig build -Doptimize="$BUILD_TYPE" -Dtarget="$target" -p "$RELEASE_DIR/$target"; then
        # Rename the binary to include architecture info
        if [ -f "$RELEASE_DIR/$target/bin/$PROJECT_NAME" ]; then
            mv "$RELEASE_DIR/$target/bin/$PROJECT_NAME" "$RELEASE_DIR/$output_name"
            rmdir "$RELEASE_DIR/$target/bin" 2>/dev/null || true
            rmdir "$RELEASE_DIR/$target" 2>/dev/null || true
            print_status "✓ Successfully built for $target"
        else
            print_error "Binary not found after build for $target"
            return 1
        fi
    else
        print_error "Failed to build for $target"
        return 1
    fi
}

# Main build function
main() {
    print_status "Starting cross-platform build for $PROJECT_NAME version $VERSION"
    
    # Check if zig is installed
    if ! command -v zig &> /dev/null; then
        print_error "Zig is not installed or not in PATH"
        exit 1
    fi
    
    clean_build
    
    # Define targets and their output names
    declare -A targets=(
        ["x86_64-macos"]="satibot-x86_64-macos"
        ["aarch64-macos"]="satibot-arm64-macos"
        ["x86_64-linux"]="satibot-x86_64-linux"
        ["aarch64-linux"]="satibot-arm64-linux"
        ["x86_64-windows"]="satibot-x86_64-windows.exe"
    )
    
    # Build for each target
    local failed_targets=()
    for target in "${!targets[@]}"; do
        if ! build_target "$target" "${targets[$target]}"; then
            failed_targets+=("$target")
        fi
    done
    
    # Create checksums
    print_status "Creating checksums..."
    cd "$RELEASE_DIR"
    if command -v sha256sum &> /dev/null; then
        sha256sum * > SHA256SUMS
    elif command -v shasum &> /dev/null; then
        shasum -a 256 * > SHA256SUMS
    else
        print_warning "Could not find sha256sum or shasum command"
    fi
    cd ..
    
    # Report results
    echo
    print_status "Build complete!"
    print_status "Artifacts created in $RELEASE_DIR/:"
    ls -la "$RELEASE_DIR/"
    
    if [ ${#failed_targets[@]} -gt 0 ]; then
        print_warning "Failed to build for: ${failed_targets[*]}"
        exit 1
    fi
}

# Show usage
usage() {
    echo "Usage: $0 [VERSION]"
    echo "  VERSION: Optional version string (defaults to git tag or 'dev')"
    echo
    echo "Examples:"
    echo "  $0"
    echo "  $0 v1.0.0"
}

# Parse arguments
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

# Run main function
main "$@"
