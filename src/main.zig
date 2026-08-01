const std = @import("std");
const Config = @import("config.zig").Config;

pub fn main(init: std.process.Init) !void {
    _ = try Config.load(init.minimal.args, init.environ_map);
    std.debug.print("All your {s} are belong to us.\n", .{"codebase"});
}

test {
    _ = @import("config.zig");
}
