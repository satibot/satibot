---
name: pinchtab-cli
description: Provides comprehensive PinchTab CLI commands for browser automation, instance management, and web scraping workflows. Use when needing to control browsers programmatically or automate web interactions.
---

# PinchTab CLI Skill

PinchTab is a browser automation tool that provides CLI commands for controlling browser instances, navigating pages, interacting with elements, and extracting data.

##

Quick Start

###

Basic Workflow

```bash
# 1. Start the orchestrator
pinchtab

# 2. Launch a browser instance
INST=$(pinchtab instance launch --mode headed | jq -r .id)

# 3. Navigate to a website
pinchtab --instance $INST nav https://example.com

# 4. Take a snapshot to see page structure
pinchtab --instance $INST snap -i -c

# 5. Interact with elements
pinchtab --instance $INST click e5

# 6. Extract data
pinchtab --instance $INST text --raw

# 7. Cleanup
pinchtab instance $INST stop
```

##

Instance Management

###

Launch Instances

```bash
# Headless (default)
pinchtab instance launch

# Headed (with visible window)
pinchtab instance launch --mode headed

# On specific port
pinchtab instance launch --port 9868

# Store instance ID
INST=$(pinchtab instance launch --mode headed | jq -r .id)
echo $INST  # inst_abc123
```

###

List Instances

```bash
# List all running instances
pinchtab instances

# Get just instance IDs
pinchtab instances | jq -r '.[] | .id'

# Get specific instance details
pinchtab instances | jq '.[] | select(.id == "inst_abc123")'
```

###

Instance Logs

```bash
# View instance logs
pinchtab instance inst_abc123 logs

# Follow logs continuously
pinchtab instance inst_abc123 logs | tail -f

# Get last 100 lines
pinchtab instance inst_abc123 logs | tail -100
```

###

Stop Instances

```bash
# Stop specific instance
pinchtab instance inst_abc123 stop

# Stop all instances (loop)
for inst in $(pinchtab instances | jq -r '.[] | .id'); do
    pinchtab instance $inst stop
done
```

##

Browser Control

###

Navigation

```bash
# Navigate to URL (default instance)
pinchtab nav https://example.com

# Navigate with specific instance
pinchtab --instance inst_abc123 nav https://example.com

# Open in new tab
pinchtab --instance inst_abc123 nav https://example.com --new-tab

# Block images for faster loading
pinchtab --instance inst_abc123 nav https://example.com --block-images
```

###

Page Snapshots

```bash
# Full page snapshot
pinchtab --instance inst_abc123 snap

# Interactive elements only
pinchtab --instance inst_abc123 snap -i

# Compact format (token-efficient for AI)
pinchtab --instance inst_abc123 snap -c

# Interactive + compact (best for AI analysis)
pinchtab --instance inst_abc123 snap -i -c

# Only changes since last snapshot
pinchtab --instance inst_abc123 snap -d

# Save snapshot to file
pinchtab --instance inst_abc123 snap > page.json

# Extract element references
pinchtab --instance inst_abc123 snap -c | jq '.elements[] | .ref' | head -5
```

###

Element Interaction

```bash
# Click element by reference
pinchtab --instance inst_abc123 click e5

# Type text (triggers events)
pinchtab --instance inst_abc123 type e12 "hello world"

# Fill input directly (no events)
pinchtab --instance inst_abc123 fill e12 "value"

# Press keys
pinchtab --instance inst_abc123 press Enter
pinchtab --instance inst_abc123 press Tab
pinchtab --instance inst_abc123 press Escape
```

###

Page Navigation

```bash
# Scroll down/up
pinchtab --instance inst_abc123 scroll down
pinchtab --instance inst_abc123 scroll up

# Scroll specific pixels
pinchtab --instance inst_abc123 scroll 500
```

##

Data Extraction

###

Text Content

```bash
# Get all visible text (JSON format)
pinchtab --instance inst_abc123 text

# Get raw text (no JSON wrapper)
pinchtab --instance inst_abc123 text --raw
```

###

Screenshots

```bash
# Save screenshot to stdout (PNG)
pinchtab --instance inst_abc123 ss > screenshot.png

# Save directly to file
pinchtab --instance inst_abc123 ss -o out.png

# JPEG with quality setting
pinchtab --instance inst_abc123 ss -o out.jpg -q 85
```

###

PDF Export

```bash
# Default PDF (A4 portrait)
pinchtab --instance inst_abc123 pdf -o out.pdf

# Landscape orientation
pinchtab --instance inst_abc123 pdf -o out.pdf --landscape

# Custom paper size (Letter)
pinchtab --instance inst_abc123 pdf -o out.pdf --paper-width 8.5 --paper-height 11

# Specific pages only
pinchtab --instance inst_abc123 pdf -o out.pdf --page-ranges "1-3,5"
```

###

JavaScript Execution

```bash
# Get page title
pinchtab --instance inst_abc123 eval "document.title"

# Count elements
pinchtab --instance inst_abc123 eval "document.querySelectorAll('a').length"

# Complex data extraction
pinchtab --instance inst_abc123 eval 'JSON.stringify({
    title: document.title,
    url: location.href,
    links: document.querySelectorAll("a").length
})'
```

##

Tab Management

###

List Tabs

```bash
# List all tabs in instance
pinchtab --instance inst_abc123 tabs
```

###

Create Tabs

```bash
# Create new tab
pinchtab --instance inst_abc123 tab create

# Create tab and navigate
pinchtab --instance inst_abc123 tab create --url https://example.com
```

###

Tab Navigation

```bash
# Navigate specific tab
pinchtab --instance inst_abc123 tab tab_123 nav https://example.com

# Close tab
pinchtab --instance inst_abc123 tab tab_123 close

# Lock tab (prevent concurrent access)
pinchtab --instance inst_abc123 tab tab_123 lock
```

##

Complex Workflows

###

Multi-step Workflows

```bash
# Using JSON stdin for complex workflows
cat <<EOF | pinchtab --instance inst_abc123 workflow
[
  {"nav": "https://example.com"},
  {"snap": "-i -c"},
  {"click": "e5"},
  {"wait": 2},
  {"ss": "-o result.png"}
]
EOF
```

###

Batch Operations

```bash
# Launch multiple instances
for i in {1..3}; do
    pinchtab instance launch --mode headed &
done
wait

# Navigate in parallel
for inst in $(pinchtab instances | jq -r '.[] | .id'); do
    pinchtab --instance $inst nav https://example.com &
done
wait
```

##

Common Patterns

###

Wait and Interact

```bash
# Navigate and wait for page load
pinchtab --instance inst_abc123 nav https://example.com
sleep 2  # Wait for page to load
pinchtab --instance inst_abc123 snap -i
```

###

Click-Wait-Screenshot Pattern

```bash
# Click element, wait, then capture result
pinchtab --instance inst_abc123 click e5
sleep 1
pinchtab --instance inst_abc123 ss -o result.png
```

###

Form Filling

```bash
# Fill form and submit
pinchtab --instance inst_abc123 fill e1 "John Doe"
pinchtab --instance inst_abc123 fill e2 "john@example.com"
pinchtab --instance inst_abc123 click e3  # Submit button
sleep 2
pinchtab --instance inst_abc123 snap
```

###

Search and Verify

```bash
# Perform search and verify results
pinchtab --instance inst_abc123 nav https://google.com
pinchtab --instance inst_abc123 fill e1 "golang"
pinchtab --instance inst_abc123 press Enter
sleep 2
pinchtab --instance inst_abc123 text | grep -q "golang" && echo "Results found"
```

##

Environment Variables

```bash
# Set custom server address
export PINCHTAB_SERVER=http://localhost:9867

# Set default instance mode
export PINCHTAB_MODE=headed

# Set default timeout
export PINCHTAB_TIMEOUT=30
```

##

Troubleshooting

###

Check Server Status

```bash
# Check if orchestrator is running
curl http://localhost:9867/health

# View server logs
pinchtab server logs
```

###

Common Issues

**Instance not starting:**

```bash
# Check system resources
pinchtab instance launch --mode headed
pinchtab instance inst_abc123 logs
```

**Can't connect to instance:**

```bash
# Verify instance is running
pinchtab instances

# Check network connectivity
curl http://localhost:9867/instances
```

**Need to specify server address:**

```bash
# Custom server address
pinchtab --server http://remote-host:9867 instance launch
```

##

Exit Codes

- `0`: Success
- `1`: General error
- `2`: Instance not found
- `3`: Connection failed
- `4`: Invalid command
- `5`: Timeout

##

Best Practices

1. **Always cleanup instances**: Stop instances when done to free resources
2. **Use snapshots before interaction**: Get current page state before clicking/typing
3. **Wait for page loads**: Add sleep delays after navigation and form submissions
4. **Use compact snapshots**: `-i -c` flags provide AI-friendly element information
5. **Handle errors gracefully**: Check exit codes and instance status
6. **Batch operations**: Use parallel processing for multiple instances when possible
7. **Lock tabs for concurrent access**: Prevent race conditions when multiple processes access same tab

##

Integration Examples

###

Shell Script Automation

```bash
#!/bin/bash
# Automated web scraping script

INST=$(pinchtab instance launch --mode headed | jq -r .id)
trap "pinchtab instance $INST stop" EXIT

pinchtab --instance $INST nav https://example.com
sleep 2

# Extract all links
pinchtab --instance $INST eval '
  Array.from(document.querySelectorAll("a"))
    .map(a => ({text: a.textContent, href: a.href}))
' > links.json

echo "Scraping complete. Results saved to links.json"
```

###

Python Integration

```python
import subprocess
import json

def launch_instance():
    result = subprocess.run(['pinchtab', 'instance', 'launch'], 
                          capture_output=True, text=True)
    return json.loads(result.stdout)['id']

def navigate_and_extract(inst_id, url):
    subprocess.run(['pinchtab', '--instance', inst_id, 'nav', url])
    subprocess.run(['sleep', '2'])  # Wait for load
    
    result = subprocess.run(['pinchtab', '--instance', inst_id, 'text', '--raw'],
                          capture_output=True, text=True)
    return result.stdout

# Usage
inst = launch_instance()
try:
    content = navigate_and_extract(inst, 'https://example.com')
    print(content)
finally:
    subprocess.run(['pinchtab', 'instance', inst, 'stop'])
```

This skill provides comprehensive coverage of PinchTab CLI functionality for browser automation tasks.
