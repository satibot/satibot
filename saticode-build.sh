#!/bin/bash
# SatiCode Build Script
# 
# Quick build and run script for SatiCode CLI
# 
# Usage:
#   ./saticode-build.sh          # Build
#   ./saticode-build.sh run      # Build and run
#   ./saticode-build.sh dev      # Development mode
#   ./saticode-build.sh clean    # Clean
#   ./saticode-build.sh install  # Install to system

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${BLUE}🔨 $1${NC}"
}

print_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

print_error() {
    echo -e "${RED}❌ $1${NC}"
}

print_info() {
    echo -e "${YELLOW}ℹ️  $1${NC}"
}

# Check if zig is installed
if ! command -v zig &> /dev/null; then
    print_error "Zig is not installed. Please install Zig first."
    echo "Visit: https://ziglang.org/download/"
    exit 1
fi

# Create output directory
mkdir -p zig-out/bin

# Build function
build_saticode() {
    local mode=${1:-"ReleaseFast"}

    print_status "Building SatiCode in $mode mode..."

    # Record start time
    local start_time=$(date +%s)
    
    # Use the main build system which handles modules correctly
    if [ "$mode" = "Debug" ]; then
        echo "Building in Debug mode..."
        zig build saticode -Doptimize=Debug
    else
        echo "Building in ReleaseFast mode..."
        zig build saticode -Doptimize=ReleaseFast
    fi
    echo "Build complete: zig-out/bin/saticode"
    local build_result=$?

    # Calculate and display build time
    local end_time=$(date +%s)
    local build_time=$((end_time - start_time))
    
    if [ $build_result -eq 0 ]; then
        print_success "Build complete: zig-out/bin/saticode (built in ${build_time}s)"
    else
        print_error "Build failed (after ${build_time}s)"
        exit 1
    fi
}

# Main script logic
case "${1:-build}" in
    "build"|"")
        build_saticode "ReleaseFast"
        ;;
    "dev")
        print_info "Building in development mode..."
        build_saticode "Debug"
        ./zig-out/bin/saticode
        ;;
    "run")
        build_saticode "ReleaseFast"
        print_status "Running SatiCode..."
        ./zig-out/bin/saticode
        ;;
    "test")
        print_status "Running tests..."
        zig test apps/code/src/main.zig
        ;;
    "clean")
        print_status "Cleaning build artifacts..."
        rm -rf zig-out zig-cache
        print_success "Clean complete"
        ;;
    "install")
        build_saticode "ReleaseFast"
        print_status "Installing SatiCode to /usr/local/bin..."
        if [ -w "/usr/local/bin" ]; then
            cp zig-out/bin/saticode /usr/local/bin/
        else
            sudo cp zig-out/bin/saticode /usr/local/bin/
        fi
        print_success "Installation complete"
        print_info "Run 'saticode' from anywhere"
        ;;
    "standalone")
        print_status "Using standalone build script..."
        if [ -f "build-saticode.zig" ]; then
            zig build --build-file build-saticode.zig
        else
            print_error "build-saticode.zig not found"
            exit 1
        fi
        ;;
    "help"|"-h"|"--help")
        echo "SatiCode Build Script"
        echo ""
        echo "Usage: $0 [COMMAND]"
        echo ""
        echo "Commands:"
        echo "  build (default)  Build saticode executable"
        echo "  dev              Build in debug mode and run"
        echo "  run              Build and run saticode"
        echo "  test             Run tests"
        echo "  clean            Clean build artifacts"
        echo "  install          Install to /usr/local/bin"
        echo "  standalone       Use standalone build script"
        echo "  help             Show this help"
        echo ""
        echo "Examples:"
        echo "  $0               # Build"
        echo "  $0 run           # Build and run"
        echo "  $0 dev           # Development mode"
        ;;
    *)
        print_error "Unknown command: $1"
        echo "Run '$0 help' for usage information"
        exit 1
        ;;
esac
