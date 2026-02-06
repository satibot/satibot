#!/bin/bash

# Script to create a GitHub release manually
# Requires: gh CLI to be installed and authenticated

set -euo pipefail

# Configuration
VERSION="${1:-}"
RELEASE_DIR="releases"
DRAFT="${2:-false}"
PRERELEASE="${3:-false}"

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

# Show usage
usage() {
    echo "Usage: $0 <VERSION> [DRAFT] [PRERELEASE]"
    echo
    echo "Arguments:"
    echo "  VERSION     Release version (e.g., v1.0.0)"
    echo "  DRAFT       Set to 'true' to create a draft release (default: false)"
    echo "  PRERELEASE  Set to 'true' to mark as prerelease (default: false)"
    echo
    echo "Examples:"
    echo "  $0 v1.0.0"
    echo "  $0 v1.0.0 true false   # Create as draft"
    echo "  $0 v1.0.0 false true   # Create as prerelease"
    echo
    echo "Prerequisites:"
    echo "  - Install GitHub CLI: https://cli.github.com/"
    echo "  - Authenticate: gh auth login"
}

# Check if gh CLI is installed
check_gh_cli() {
    if ! command -v gh &> /dev/null; then
        print_error "GitHub CLI (gh) is not installed"
        echo "Please install it from: https://cli.github.com/"
        exit 1
    fi
    
    # Check if authenticated
    if ! gh auth status &> /dev/null; then
        print_error "GitHub CLI is not authenticated"
        echo "Please run: gh auth login"
        exit 1
    fi
}

# Validate version format
validate_version() {
    if [[ ! "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9]+)?$ ]]; then
        print_error "Invalid version format: $VERSION"
        echo "Version should follow semantic versioning (e.g., v1.0.0, v1.0.0-beta)"
        exit 1
    fi
}

# Check if release directory exists and has artifacts
check_artifacts() {
    if [ ! -d "$RELEASE_DIR" ]; then
        print_error "Release directory '$RELEASE_DIR' not found"
        echo "Please run 'make build-all' or './scripts/build-release.sh' first"
        exit 1
    fi
    
    # Count non-checksum files
    local artifact_count=$(find "$RELEASE_DIR" -type f ! -name 'SHA256SUMS' ! -name '*.md' | wc -l)
    if [ "$artifact_count" -eq 0 ]; then
        print_error "No release artifacts found in '$RELEASE_DIR'"
        exit 1
    fi
    
    print_status "Found $artifact_count release artifacts"
}

# Create the release
create_release() {
    local draft_flag=""
    local prerelease_flag=""
    
    if [ "$DRAFT" = "true" ]; then
        draft_flag="--draft"
    fi
    
    if [ "$PRERELEASE" = "true" ]; then
        prerelease_flag="--prerelease"
    fi
    
    # Generate release notes
    local notes_file="release-notes.md"
    cat > "$notes_file" << EOF
# Release $VERSION

## Installation

### macOS
```bash
# For Intel Macs
curl -L -o satibot "https://github.com/$(git config --get remote.origin.url | sed 's/.*github.com[:/]\([^.]*\).*/\1/')/releases/download/$VERSION/satibot-x86_64-macos"
chmod +x satibot

# For Apple Silicon Macs
curl -L -o satibot "https://github.com/$(git config --get remote.origin.url | sed 's/.*github.com[:/]\([^.]*\).*/\1/')/releases/download/$VERSION/satibot-arm64-macos"
chmod +x satibot
```

### Linux
```bash
# For x86_64
curl -L -o satibot "https://github.com/$(git config --get remote.origin.url | sed 's/.*github.com[:/]\([^.]*\).*/\1/')/releases/download/$VERSION/satibot-x86_64-linux"
chmod +x satibot

# For ARM64
curl -L -o satibot "https://github.com/$(git config --get remote.origin.url | sed 's/.*github.com[:/]\([^.]*\).*/\1/')/releases/download/$VERSION/satibot-arm64-linux"
chmod +x satibot
```

### Windows
```powershell
# For x86_64
Invoke-WebRequest -Uri "https://github.com/$(git config --get remote.origin.url | sed 's/.*github.com[:/]\([^.]*\).*/\1/')/releases/download/$VERSION/satibot-x86_64-windows.exe" -OutFile "satibot.exe"
```

## Checksums

Verify the integrity of the downloaded files using the provided SHA256 checksums.

\`\`\`
$(cat "$RELEASE_DIR/SHA256SUMS" 2>/dev/null || echo "Checksums not available")
\`\`\`

## Changes

$(git tag --sort=-version:refname | grep -v "$VERSION" | head -1 | xargs git log --pretty=format:"- %s" --no-merges 2>/dev/null || echo "- Initial release")
EOF
    
    print_status "Creating release $VERSION..."
    
    # Upload assets and create release
    local assets=()
    while IFS= read -r -d '' file; do
        assets+=("$file")
    done < <(find "$RELEASE_DIR" -type f ! -name 'SHA256SUMS' ! -name '*.md' -print0)
    
    if gh release create "$VERSION" "${assets[@]}" --title "Release $VERSION" --notes-file "$notes_file" $draft_flag $prerelease_flag; then
        print_status "✓ Release $VERSION created successfully!"
        
        if [ "$DRAFT" = "true" ]; then
            print_warning "This is a DRAFT release. Edit and publish it on GitHub."
        fi
        
        # Show release URL
        local repo_url=$(git remote get-url origin 2>/dev/null | sed 's/\.git$//' | sed 's/git@github.com:/https:\/\/github.com\//' || echo "")
        if [ -n "$repo_url" ]; then
            echo "Release URL: $repo_url/releases/tag/$VERSION"
        fi
    else
        print_error "Failed to create release"
        exit 1
    fi
    
    # Clean up notes file
    rm -f "$notes_file"
}

# Main function
main() {
    if [ -z "$VERSION" ]; then
        print_error "Version is required"
        usage
        exit 1
    fi
    
    if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
        usage
        exit 0
    fi
    
    print_status "Creating GitHub release for version $VERSION"
    
    check_gh_cli
    validate_version
    check_artifacts
    create_release
}

# Run main function
main "$@"
