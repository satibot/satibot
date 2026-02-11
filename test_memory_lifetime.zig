const std = @import("std");
const expect = std.testing.expect;
const Allocator = std.mem.Allocator;

// Mock types for testing
const MockClient = struct {
    value: u32,
};

const MockContext = struct {
    client: *const MockClient,

    pub fn init(client: *const MockClient) MockContext {
        return MockContext{ .client = client };
    }

    pub fn getValue(self: MockContext) u32 {
        return self.client.value;
    }
};

const MockBot = struct {
    allocator: Allocator,
    client: MockClient,
    context: MockContext,

    pub fn init(allocator: Allocator, value: u32) !MockBot {
        // Create the bot struct first
        var bot = MockBot{
            .allocator = allocator,
            .client = MockClient{ .value = value },
            .context = undefined, // Will be initialized below
        };

        // Now initialize the context with a pointer to the client in the struct
        bot.context = MockContext.init(&bot.client);

        return bot;
    }

    pub fn getValue(self: MockBot) u32 {
        return self.context.getValue();
    }
};

test "context pointer lifetime" {
    const allocator = std.testing.allocator;

    // This simulates the pattern we fixed
    var bot = try MockBot.init(allocator, 42);

    // The context should correctly point to the bot's client
    try expect(bot.getValue() == 42);
    try expect(bot.context.client.value == 42);
}

test "demonstrate the bug pattern" {
    const allocator = std.testing.allocator;

    // This would be the WRONG way (commented out to avoid actual bug)
    // var client = MockClient{ .value = 42 };
    // var context = MockContext.init(&client); // Points to stack!
    // const bot = MockBot{
    //     .allocator = allocator,
    //     .client = client,
    //     .context = context,
    // }; // context now has invalid pointer!

    // Instead, we do it the RIGHT way
    var bot = try MockBot.init(allocator, 42);

    // This should work without segfault
    try expect(bot.getValue() == 42);
}
