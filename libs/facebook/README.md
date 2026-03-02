# Facebook Graph API Library

A Zig library for interacting with the Facebook Graph API. Provides client functionality for reading pages, groups, threads, and comments via the Facebook Marketing API / Graph API endpoints.

## Features

- **Page Operations**: Get page info and posts
- **Group Operations**: Read group feed
- **Messaging**: Access conversations and messages
- **Comments**: Retrieve post comments
- **Connection Testing**: Verify API credentials

## Installation

Add to your `build.zig`:

```zig
const facebook = @import("libs/facebook/src/root.zig");
```

## Quick Start

```zig
const facebook = @import("libs/facebook");
const std = std.testing;

const allocator = std.heap.page_allocator;

const config = facebook.Config{
    .access_token = "your-facebook-access-token",
    .page_id = "your-page-id",
};

var client = try facebook.Client.init(allocator, config);
defer client.deinit();

// Test connection
const connected = try client.testConnection();
std.debug.print("Connected: {}\n", .{connected});

// Get current user
const me = try client.getMe();
std.debug.print("User: {s}\n", .{me.name});

// Get page posts
const posts = try client.getPagePosts("page-id", 10);
defer {
    for (posts) |post| allocator.free(post.message);
    allocator.free(posts);
}
```

## API Reference

### Configuration

```zig
pub const Config = struct {
    access_token: []const u8,
    app_secret: ?[]const u8 = null,
    page_id: ?[]const u8 = null,
};
```

### Client Methods

| Method | Description |
|--------|-------------|
| `testConnection()` | Verify API credentials |
| `getMe()` | Get current user info |
| `getPage(page_id)` | Get page details |
| `getPagePosts(page_id, limit)` | Get page posts |
| `getPostComments(post_id, limit)` | Get comments on a post |
| `getConversations(page_id, limit)` | Get page conversations |
| `getConversationMessages(conversation_id, limit)` | Get messages in a conversation |
| `getGroupFeed(group_id, limit)` | Get group feed |

### Data Types

- `User` - User account info (id, name)
- `Page` - Page info (id, name, category)
- `Post` - Post data (id, message, created_time)
- `Comment` - Comment data (id, message, from_name, created_time)
- `Conversation` - Conversation data (id, updated_time, snippet)
- `Message` - Message data (id, message, from_name, created_time)

### Error Types

```zig
pub const Error = error{
    InvalidToken,
    NetworkError,
    ParseError,
    ApiError,
    RateLimited,
};
```

## Documentation

See [docs/facebook.md](./docs/facebook.md) for detailed architecture diagrams and API documentation.

## Requirements

- Zig 0.15+
- Facebook Graph API access token with appropriate permissions:
  - `pages_read_engagement` - Read page posts and comments
  - `pages_manage_metadata` - Page metadata access
  - `pages_read_user_content` - Read user content
  - `read_page_mailboxes` - Read page conversations
  - `groups_access_member_info` - Group content access

## Testing

```bash
zig build test
```
