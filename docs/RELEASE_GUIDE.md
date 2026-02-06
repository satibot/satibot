# Cross-Platform Build and Release Guide

This guide explains how to build Satibot for multiple platforms and create GitHub releases.

## Prerequisites

- Zig compiler (0.15.2 or later)
- For manual releases: [GitHub CLI](https://cli.github.com/) installed and authenticated

## Building for Multiple Platforms

### Option 1: Using the Build Script

The easiest way to build for all platforms is using the build script:

```bash
# Build for all platforms with auto-detected version
./scripts/build-release.sh

# Build with specific version
./scripts/build-release.sh v1.0.0
```

This will create the following binaries in the `releases/` directory:

- `satibot-arm64-macos` - macOS Apple Silicon
- `satibot-x86_64-macos` - macOS Intel
- `satibot-x86_64-linux` - Linux x86_64
- `satibot-arm64-linux` - Linux ARM64
- `satibot-x86_64-windows.exe` - Windows x86_64
- `SHA256SUMS` - Checksums for all binaries

### Option 2: Using Make Targets

You can also use the Makefile targets:

```bash
# Build for all platforms
make build-all

# Build for specific platforms
make build-macos    # macOS (Intel + Apple Silicon)
make build-linux    # Linux (x86_64 + ARM64)
make build-windows  # Windows (x86_64)

# Generate checksums after building
make checksums
```

### Option 3: Manual Zig Commands

For full control, you can use zig build directly:

```bash
# macOS Intel
zig build -Doptimize=ReleaseSmall -Dtarget=x86_64-macos -p release-macos

# macOS Apple Silicon
zig build -Doptimize=ReleaseSmall -Dtarget=aarch64-macos -p release-macos-arm64

# Linux x86_64
zig build -Doptimize=ReleaseSmall -Dtarget=x86_64-linux -p release-linux

# Linux ARM64
zig build -Doptimize=ReleaseSmall -Dtarget=aarch64-linux -p release-linux-arm64

# Windows x86_64
zig build -Doptimize=ReleaseSmall -Dtarget=x86_64-windows -p release-windows
```

## Creating GitHub Releases

### Automated Releases (Recommended)

The project includes a GitHub Actions workflow that automatically creates releases when you push a tag:

```bash
# Create and push a tag (triggers automated release)
git tag v1.0.0
git push origin v1.0.0
```

The workflow will:

1. Build for all supported platforms
2. Create a GitHub release
3. Upload all binaries as assets
4. Generate checksums

### Manual Releases

If you prefer to create releases manually:

- First, build all binaries:

   ```bash
   ./scripts/build-release.sh v1.0.0
   ```

- Create the release using the script:

   ```bash
   # Create a full release
   ./scripts/create-github-release.sh v1.0.0
   
   # Create as draft
   ./scripts/create-github-release.sh v1.0.0 true false
   
   # Create as prerelease
   ./scripts/create-github-release.sh v1.0.0 false true
   ```

- Or use GitHub CLI directly:

   ```bash
   gh release create v1.0.0 releases/* --title "Release v1.0.0" --generate-notes
   ```

## Supported Platforms

| Platform     | Architecture               | Binary Name                  |
|--------------|----------------------------|------------------------------|
| macOS        | Intel (x86_64)             | `satibot-x86_64-macos`       |
| macOS        | Apple Silicon (ARM64)      | `satibot-arm64-macos`        |
| Linux        | x86_64                     | `satibot-x86_64-linux`       |
| Linux        | ARM64                      | `satibot-arm64-linux`        |
| Windows      | x86_64                     | `satibot-x86_64-windows.exe` |

## Verifying Downloads

Always verify the integrity of downloaded binaries using the provided SHA256 checksums:

```bash
# On macOS/Linux
sha256sum -c SHA256SUMS

# On macOS with shasum
shasum -a 256 -c SHA256SUMS

# On Windows
certutil -hashfile satibot.exe SHA256
```

## CI/CD Workflow

The GitHub Actions workflow (`.github/workflows/release.yml`) handles:

1. **Cross-compilation** for all supported platforms
2. **Artifact collection** and organization
3. **Release creation** with proper metadata
4. **Checksum generation** for security
5. **Release notes** with installation instructions

The workflow triggers on:

- Push to tags matching `v*` (e.g., `v1.0.0`, `v1.2.3-beta`)
- Manual dispatch via GitHub Actions UI

## Tips

1. **Version Format**: Use semantic versioning (e.g., `v1.0.0`, `v1.0.0-beta`)
2. **Release Mode**: Binaries are built with `ReleaseSmall` optimization for minimal size
3. **Clean Builds**: Always clean before building releases to avoid artifacts
4. **Test Before Release**: Test binaries on target platforms before publishing

## Troubleshooting

### Build Issues

- Ensure Zig 0.15.2 or later is installed
- Check that all dependencies are available in `build.zig.zon`
- For Windows builds from macOS/Linux, cross-compilation should work automatically

### Release Issues

- Verify GitHub CLI is authenticated: `gh auth status`
- Check repository permissions for creating releases
- Ensure tag format is correct (starts with `v`)

### Cross-Compilation Issues

- Zig handles most cross-compilation automatically
- Some platform-specific code might need conditional compilation
- Test on actual target platforms when possible
