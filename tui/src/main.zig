const std = @import("std");
const zpg = @import("core");
const Config = @import("config.zig").Config;
const Client = zpg.client.Client;
const ConnectOptions = zpg.options.ConnectOptions;

pub fn main(init: std.process.Init) !void {
    const config = try Config.load(init.minimal.args, init.environ_map);
    const opts = ConnectOptions{
        .host = config.db_host,
        .port = config.db_port,
        .user = config.db_user,
        .pass = config.db_pass,
        .database = config.db_name,
    };
    var client = try Client.init(init.io, init.gpa, opts);
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
}
