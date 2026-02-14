# Generic Makefile for Zig projects

# Load environment variables from .env file
# ifneq (,$(wildcard ./.env))
#     include .env
#     export $(shell sed 's/=.*//' .env)
# else
#     $(warning .env file not found. Environment variables not loaded.)
# endif

################################################################################
# Configuration and Variables
################################################################################
ZIG           ?= zig
ZIG_VERSION   := $(shell $(ZIG) version)
BUILD_TYPE    ?= ReleaseFast
BUILD_OPTS      = -Doptimize=$(BUILD_TYPE)
JOBS          ?= $(shell nproc || echo 2)
SRC_DIR       := src
TEST_DIR      := tests
BUILD_DIR     := zig-out
CACHE_DIR     := .zig-cache
DOC_SRC       := src/root.zig
DOC_OUT       := docs/api/
COVERAGE_DIR  := coverage
BINARY_NAME   := sati
BINARY_PATH   := $(BUILD_DIR)/bin/$(BINARY_NAME)
TEST_EXECUTABLE := $(BUILD_DIR)/bin/test
PREFIX        ?= /usr/local
RELEASE_MODE := ReleaseSmall

SHELL         := /usr/bin/env bash
.SHELLFLAGS   := -eu -o pipefail -c

################################################################################
# Targets
################################################################################

.PHONY: all build rebuild run test cov lint format doc clean install-deps release help coverage
.DEFAULT_GOAL := help

help: ## Show the help messages for all targets
	@grep -E '^[a-zA-Z0-9_-]+:.*?## ' Makefile | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-10s %s\n", $$1, $$2}'

all: build test lint format doc  ## build, test, lint, format, and doc

build: ## Build project (Mode=$(BUILD_TYPE))
	@echo "Building project in $(BUILD_TYPE) mode with $(JOBS) concurrent jobs..."
	$(ZIG) build $(BUILD_OPTS) -j$(JOBS)

prod: ## Build project in production mode (only telegram bot)
	@echo "Building telegram bot in ReleaseFast mode with $(JOBS) concurrent jobs..."
	$(ZIG) build -Doptimize=ReleaseFast -j$(JOBS) xev-telegram-bot -Dtelegram-bot-only=true

prod-sync: ## Build synchronous telegram bot in production mode
	@echo "Building synchronous telegram bot in ReleaseFast mode with $(JOBS) concurrent jobs..."
	$(ZIG) build -Doptimize=ReleaseFast -j$(JOBS) telegram-sync

rebuild: clean build  ## clean and build

run: build  ## Run the main application
	@echo "Running $(BINARY_NAME)..."
	$(ZIG) build run $(BUILD_OPTS) --

test: ## Run tests and generate coverage data
	@echo "Running tests with coverage enabled..."
	$(ZIG) build test $(BUILD_OPTS) -Denable-coverage=true -j$(JOBS)

release: ## Build in Release mode
	@echo "Building the project in Release mode..."
	@$(MAKE) BUILD_TYPE=$(RELEASE_MODE) build

clean: ## Remove docs, build artifacts, and cache directories
	@echo "Removing build artifacts, cache, generated docs, and coverage files..."
	rm -rf $(BUILD_DIR) $(CACHE_DIR) $(DOC_OUT) *.profraw $(COVERAGE_DIR)

lint: ## Check code style and formatting of Zig files
	@echo "Running code style checks..."
	@ziglint
	$(ZIG) fmt --check $(SRC_DIR)

format: ## Format Zig files
	@echo "Formatting Zig files..."
	$(ZIG) fmt .

install-deps: ## Install system dependencies (for Debian-based systems)
	@echo "Installing system dependencies..."
	sudo apt-get update
	sudo apt-get install -y make llvm snapd
	sudo snap install zig  --beta --classic # Use `--edge --classic` to install the latest version

coverage: ## Generate code coverage report
	@echo "Building tests with coverage instrumentation..."
	@zig build test -Denable-coverage=true
	@echo "Generating coverage report..."
	@kcov --include-pattern=src --verify coverage-out zig-out/bin/test-root

################################################################################
# Cross-compilation targets
################################################################################

.PHONY: build-all build-macos build-linux build-windows

# Build for all platforms
build-all: ## Build for all supported platforms
	@echo "Building for all platforms..."
	@./scripts/build-release.sh

# Build for macOS (Intel and Apple Silicon)
build-macos: ## Build for macOS (Intel and Apple Silicon)
	@echo "Building for macOS..."
	@mkdir -p releases
	@zig build -Doptimize=$(RELEASE_MODE) -Dtarget=x86_64-macos -p releases/x86_64-macos
	@mv releases/x86_64-macos/bin/sati releases/sati-x86_64-macos
	@rmdir releases/x86_64-macos/bin 2>/dev/null || true
	@rmdir releases/x86_64-macos 2>/dev/null || true
	@zig build -Doptimize=$(RELEASE_MODE) -Dtarget=aarch64-macos -p releases/aarch64-macos
	@mv releases/aarch64-macos/bin/sati releases/sati-arm64-macos
	@rmdir releases/aarch64-macos/bin 2>/dev/null || true
	@rmdir releases/aarch64-macos 2>/dev/null || true

# Build for Linux (x86_64 and ARM64)
build-linux: ## Build for Linux (x86_64 and ARM64)
	@echo "Building for Linux..."
	@mkdir -p releases
	@zig build -Doptimize=$(RELEASE_MODE) -Dtarget=x86_64-linux -p releases/x86_64-linux
	@mv releases/x86_64-linux/bin/sati releases/sati-x86_64-linux
	@rmdir releases/x86_64-linux/bin 2>/dev/null || true
	@rmdir releases/x86_64-linux 2>/dev/null || true
	@zig build -Doptimize=$(RELEASE_MODE) -Dtarget=aarch64-linux -p releases/aarch64-linux
	@mv releases/aarch64-linux/bin/sati releases/sati-arm64-linux
	@rmdir releases/aarch64-linux/bin 2>/dev/null || true
	@rmdir releases/aarch64-linux 2>/dev/null || true

# Build for Windows (x86_64)
build-windows: ## Build for Windows (x86_64)
	@echo "Building for Windows..."
	@mkdir -p releases
	@zig build -Doptimize=$(RELEASE_MODE) -Dtarget=x86_64-windows -p releases/x86_64-windows
	@mv releases/x86_64-windows/bin/sati.exe releases/sati-x86_64-windows.exe
	@rmdir releases/x86_64-windows/bin 2>/dev/null || true
	@rmdir releases/x86_64-windows 2>/dev/null || true

# Create checksums for release artifacts
checksums: ## Create SHA256 checksums for release artifacts
	@echo "Creating checksums..."
	@cd releases && \
	if command -v sha256sum &> /dev/null; then \
		sha256sum * > SHA256SUMS; \
	elif command -v shasum &> /dev/null; then \
		shasum -a 256 * > SHA256SUMS; \
	else \
		echo "Could not find sha256sum or shasum command"; \
	fi
