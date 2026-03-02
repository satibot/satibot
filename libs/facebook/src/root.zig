//! Facebook Graph API client module
pub const facebook = @import("facebook.zig");
pub const Config = facebook.Config;
pub const Client = facebook.Client;
pub const Page = facebook.Page;
pub const Post = facebook.Post;
pub const Comment = facebook.Comment;
pub const Conversation = facebook.Conversation;
pub const Message = facebook.Message;
pub const Error = facebook.Error;

test {
    _ = facebook;
}
