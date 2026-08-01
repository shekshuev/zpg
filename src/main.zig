const std = @import("std");
const Config = @import("config.zig").Config;
const Client = @import("db/client.zig").Client;

pub fn main(init: std.process.Init) !void {
    const config = try Config.load(init.minimal.args, init.environ_map);
    var client = try Client.init(init.io, init.gpa, config);
    defer client.deinit();
    if (try client.checkConnection()) {
        std.debug.print("Connected.\n", .{});
    }
    std.debug.print("All your {s} are belong to us.\n", .{"codebase"});
}

test {
    _ = @import("config.zig");
}
