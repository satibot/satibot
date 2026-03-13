# SatiCode Build System

This directory contains multiple build options for SatiCode to make development and distribution easier.

## Quick Start

### Option 1: Shell Script (Recommended)

```bash
# Build
./saticode-build.sh

# Build and run
./saticode-build.sh run

# Development mode
./saticode-build.sh dev
```

### Option 2: Makefile

```bash
# Using the dedicated Makefile
make -f Makefile.saticode
make -f Makefile.saticode run
```

### Option 3: Standalone Build Script

```bash
zig build --build-file build-saticode.zig
zig build --build-file build-saticode.zig run
```

### Option 4: Main Build System

```bash
zig build saticode
zig build saticode-run
```

## Build Commands

| Command | Description |
|---------|-------------|
| `./saticode-build.sh` | Build SatiCode (default) |
| `./saticode-build.sh run` | Build and run SatiCode |
| `./saticode-build.sh dev` | Development build and run |
| `./saticode-build.sh test` | Run tests |
| `./saticode-build.sh clean` | Clean build artifacts |
| `./saticode-build.sh install` | Install to system |
| `./saticode-build.sh help` | Show help |

## Installation

### From Source

```bash
# Clone and build
git clone <repository>
cd satibot
./saticode-build.sh install

# Or manually
./saticode-build.sh
sudo cp zig-out/bin/saticode /usr/local/bin/
```

### System Requirements

- Zig 0.15.0 or later

## Configuration

After installation, create a configuration file:

```bash
# Create config in current directory
nano .saticode.jsonc
```

Example configuration:

```jsonc
{
  "model": "MiniMax-M2.5",
  "providers": {
    "minimax": {
      "apiKey": "${MINIMAX_API_KEY}"
    }
  }
}
```

## Development

### Development Workflow

```bash
# Development build with debug info
./saticode-build.sh dev

# Run tests
./saticode-build.sh test

# Clean and rebuild
./saticode-build.sh clean
./saticode-build.sh run
```

### Build Files Description

- `saticode-build.sh` - Main build script with error handling and colors
- `Makefile.saticode` - Traditional Makefile for Unix systems  
- `build-saticode.zig` - Standalone Zig build script (for advanced use)
- `build.zig` - Main project build script (handles complex module dependencies)

**Note**: The build scripts use the main `build.zig` system which properly handles module dependencies. The standalone `build-saticode.zig` is provided for reference but may require manual module setup.

## Troubleshooting

### Common Issues

1. **Zig not found**

   ```bash
   # Install Zig
   # macOS
   brew install zig
   # Ubuntu
   sudo apt-get install zig
   ```

2. **Config file parsing error**

   If you see "Failed to parse config file .saticode.jsonc", the build will still work with default settings. Check your JSONC syntax or temporarily rename the config file to use defaults.

3. **Permission denied on install**

   ```bash
   # Use sudo or install to user directory
   mkdir -p ~/.local/bin
   cp zig-out/bin/saticode ~/.local/bin/
   echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
   ```

### Verbose Build

For debugging build issues:

```bash
# Verbose output
zig build-exe apps/code/src/main.zig --verbose

# Check dependencies
# Note: No external dependencies required beyond Zig
```

## Performance

Build modes:

- `Debug` - Fast compilation, includes debug info
- `ReleaseFast` - Optimized for performance (default)
- `ReleaseSmall` - Optimized for size
- `ReleaseSafe` - Optimized with runtime safety

Use with: `./saticode-build.sh dev` (Debug) or default (ReleaseFast)
