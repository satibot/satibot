# web_fetch Tool Documentation

WARNING: this feature is developing, so it may not work as expected.

The `web_fetch` tool allows the AI agent to fetch content from any URL and extract readable text from HTML.

## Usage Examples

```bash
# Ask the agent to fetch a webpage
sati console-sync
> What's on https://example.com?

# Fetch and summarize a news article
> Get the main content from https://news.example.com/article

# Get raw HTML (format: "raw")
> Fetch the raw HTML from https://example.com
```

## Arguments

- `url` (required): The URL to fetch
- `format` (optional): Output format - `"markdown"` (default, extracts readable text) or `"raw"` (raw HTML)

## Example JSON

```json
{
  "url": "https://example.com",
  "format": "markdown"
}
```

## Features

- ✅ Fetches content via HTTPS with TLS support
- ✅ Automatically extracts readable text from HTML
- ✅ Strips scripts, styles, and other non-content elements
- ✅ Converts HTML entities to readable characters (`&lt;` → `<`, `&amp;` → `&`, etc.)
- ✅ Preserves document structure (paragraphs, lists, headings)
- ✅ Content size limit: 5MB (returns error for larger content)
- ✅ Configurable timeouts (connect: 30s, request: 2min)
