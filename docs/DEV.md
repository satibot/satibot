## Development

This project is built with Zig 0.15.2.

### Prerequisites

You can check your Zig version with:

```bash
zig version
# Should be 0.15.2
```

Simple way to buid:

```bash
zig build
```

Build and run tests:

```bash
zig build test
```

### Common Tasks (Makefile)

This project uses a `Makefile` to simplify common development commands.

To install system dependencies (Debian/Ubuntu):

```bash
make install-deps
```

For code coverage (`make coverage`), you will also need [kcov](https://github.com/SimonKagstrom/kcov) installed. See [kcov installation guide](https://github.com/SimonKagstrom/kcov/blob/master/INSTALL.md).

```bash
# Show all available commands
make help

# Build the project (Debug mode)
make build

# Build for Release
make release

# Run unit tests
make test

# Generate coverage report (requires kcov)
make coverage
# Reports are generated in coverage-out/index.html

# Format code
make format

# Check code style
make lint

# Clean build artifacts
make clean
```

### Running the Application

To run the agent with arguments, use `zig build run` or execute the binary directly:

```bash
# Build and run
zig build run -- agent -m "Hello world"

# Or run the binary directly after building
# (Binary location: ./zig-out/bin/satibot)
./zig-out/bin/satibot agent -m "Hello world"
```
