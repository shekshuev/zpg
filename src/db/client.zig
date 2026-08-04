const std = @import("std");
const pg = @import("pg");
const Config = @import("../config.zig").Config;
const QueryResult = @import("result.zig").QueryResult;

pub const Client = struct {
    pool: *pg.Pool,
    allocator: std.mem.Allocator,
    io: std.Io,

    pub fn init(io: std.Io, allocator: std.mem.Allocator, config: Config) !Client {
        const pool = try pg.Pool.init(io, allocator, .{ .size = 5, .connect_on_init_count = 1, .connect = .{
            .port = config.db_port,
            .host = config.db_host,
        }, .auth = .{
            .username = config.db_user,
            .database = config.db_name,
            .password = config.db_pass,
            .timeout = 10_000,
        } });

        return .{
            .pool = pool,
            .allocator = allocator,
            .io = io,
        };
    }

    pub fn deinit(self: *Client) void {
        self.pool.deinit();
    }

    pub fn checkConnection(self: *Client) !bool {
        var result = try self.pool.query("select 1", .{});
        defer result.deinit();
        while (try result.next()) |row| {
            const one = try row.get(i32, 0);
            return one == 1;
        }
        return false;
    }

    pub fn execute(self: *Client, sql: []const u8) !QueryResult {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        var allocator = arena.allocator();
        errdefer arena.deinit();

        const start_time = std.Io.Clock.real.now(self.io).toMilliseconds();

        var result = self.pool.queryOpts(sql, .{}, .{ .column_names = true }) catch |err| {
            const end_time = std.Io.Clock.real.now(self.io).toMilliseconds();
            const elapsed: u64 = @intCast(@max(0, end_time - start_time));

            return QueryResult{
                .arena = arena,
                .payload = .{ .err = .{
                    .message = @errorName(err),
                    .code = null,
                    .detail = null,
                    .hint = null,
                    .position = null,
                    .execution_time_ms = elapsed,
                } },
            };
        };
        defer result.deinit();

        const end_time = std.Io.Clock.real.now(self.io).toMilliseconds();
        const elapsed: u64 = @intCast(@max(0, end_time - start_time));

        if (result.column_names.len > 0) {
            var cols = try allocator.alloc([]const u8, result.column_names.len);
            for (result.column_names, 0..) |name, i| {
                cols[i] = try allocator.dupe(u8, name);
            }

            var rows = std.ArrayList([]const []const u8).empty;
            while (try result.next()) |row| {
                var cells = try allocator.alloc([]const u8, cols.len);
                for (0..cols.len) |col_idx| {
                    if (row.get([]const u8, col_idx) catch null) |value| {
                        cells[col_idx] = try allocator.dupe(u8, value);
                    } else {
                        cells[col_idx] = "[NULL]";
                    }
                }
                try rows.append(allocator, cells);
            }

            return QueryResult{
                .arena = arena,
                .payload = .{
                    .select = .{
                        .columns = cols,
                        .rows = try rows.toOwnedSlice(allocator),
                        .execution_time_ms = elapsed,
                    },
                },
            };
        }

        return QueryResult{
            .arena = arena,
            .payload = .{
                .command = .{
                    .status = "OK",
                    .rows_affected = 0,
                    .execution_time_ms = elapsed,
                },
            },
        };
    }
};
