## Development

This project is built with Zig 0.15.2. To build and run:

```bash
zig -v
# should be 0.15.2

zig build run -- agent -m "Your message"

# Build
zig build

# Run
./zig-out/bin/minbot agent -m "Hello"

zig build test
```
