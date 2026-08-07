const std = @import("std");
const Config = @import("config.zig").Config;
const Client = @import("db/client.zig").Client;
const QueryResult = @import("db/result.zig").QueryResult;

pub fn main(init: std.process.Init) !void {
    const config = try Config.load(init.minimal.args, init.environ_map);
    var client = try Client.init(init.io, init.gpa, config);
    defer client.deinit();

    if (try client.checkConnection()) {
        std.debug.print("Connected successfully.\n", .{});
    }

    try client.syncSessionContext();
    std.debug.print("Session synced.\n", .{});

    std.debug.print("\nAll your {s} are belong to us.\n", .{"codebase"});
}

test {
    _ = @import("config.zig");
    _ = @import("db/client.zig");
}
