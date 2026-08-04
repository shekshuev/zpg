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

    // TODO: for testing purpose, remove later

    {
        var result = try client.execute("SELECT * FROM accounts");
        defer result.deinit();
        printQueryResult(result);
    }

    {
        var result = try client.execute("UPDATE accounts SET updated_at = NOW() WHERE id = 1");
        defer result.deinit();
        printQueryResult(result);
    }

    {
        var result = try client.execute("SELECT * FROM non_existing_table_xyz");
        defer result.deinit();
        printQueryResult(result);
    }

    std.debug.print("\nAll your {s} are belong to us.\n", .{"codebase"});
}

fn printQueryResult(result: QueryResult) void {
    switch (result.payload) {
        .select => |sel| {
            std.debug.print("\n--- SELECT ({d} ms, {d} rows) ---\n", .{ sel.execution_time_ms, sel.rows.len });

            for (sel.columns, 0..) |col, i| {
                if (i > 0) std.debug.print(" | ", .{});
                std.debug.print("{s}", .{col});
            }
            std.debug.print("\n", .{});

            for (sel.rows) |row| {
                for (row, 0..) |cell, i| {
                    if (i > 0) std.debug.print(" | ", .{});
                    std.debug.print("{s}", .{cell});
                }
                std.debug.print("\n", .{});
            }
        },

        .command => |cmd| {
            std.debug.print("\n--- COMMAND ({d} ms) ---\n", .{cmd.execution_time_ms});
            std.debug.print("Status: {s} | Rows affected: {d}\n", .{ cmd.status, cmd.rows_affected });
        },

        .err => |err_data| {
            std.debug.print("\n--- ERROR ({d} ms) ---\n", .{err_data.execution_time_ms});
            std.debug.print("Message: {s}\n", .{err_data.message});
        },
    }
}

test {
    _ = @import("config.zig");
}
