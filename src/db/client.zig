const std = @import("std");
const pg = @import("pg");
const Config = @import("../config.zig").Config;

pub const Client = struct {
    pool: *pg.Pool,
    allocator: std.mem.Allocator,

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
};
