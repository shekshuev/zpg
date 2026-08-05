const std = @import("std");
const pg = @import("pg");
const builtin = @import("builtin");
const testing = std.testing;

const config = @import("../config.zig");
const Config = config.Config;
const QueryResult = @import("result.zig").QueryResult;
const Oid = @import("oids.zig").Oid;

pub const Client = struct {
    pool: *pg.Pool,
    allocator: std.mem.Allocator,
    io: std.Io,

    pub fn init(io: std.Io, allocator: std.mem.Allocator, cfg: Config) !Client {
        const pool = try pg.Pool.init(io, allocator, .{ .size = 5, .connect_on_init_count = 1, .connect = .{
            .port = cfg.db_port,
            .host = cfg.db_host,
        }, .auth = .{
            .username = cfg.db_user,
            .database = cfg.db_name,
            .password = cfg.db_pass,
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
                    cells[col_idx] = try cellToString(allocator, row, col_idx);
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

    fn cellToString(allocator: std.mem.Allocator, row: pg.Row, col_idx: usize) ![]const u8 {
        if (row.values[col_idx].is_null) {
            return "[NULL]";
        }

        const oid: Oid = @enumFromInt(row.oids[col_idx]);
        return switch (oid) {
            .char, .name, .text, .xml, .bpchar, .varchar, .json, .jsonb => {
                const str = try row.get([]const u8, col_idx);
                return try allocator.dupe(u8, str);
            },
            .bool => {
                const value = try row.get(bool, col_idx);
                return if (value) "true" else "false";
            },
            .int2 => try std.fmt.allocPrint(allocator, "{d}", .{try row.get(i16, col_idx)}),
            .int4 => try std.fmt.allocPrint(allocator, "{d}", .{try row.get(i32, col_idx)}),
            .int8 => try std.fmt.allocPrint(allocator, "{d}", .{try row.get(i64, col_idx)}),
            .float4 => {
                const value = try row.get(f32, col_idx);
                return formatFloat(f32, allocator, value);
            },
            .float8 => {
                const value = try row.get(f64, col_idx);
                return formatFloat(f64, allocator, value);
            },
            .numeric => {
                const value = try row.get(pg.Numeric, col_idx);
                const size = value.estimatedStringLen();
                const buf = try allocator.alloc(u8, size);
                return value.toString(buf);
            },
            .uuid => {
                const str = try row.get([]const u8, col_idx);
                const uuid = try pg.uuidToHex(str);
                return try allocator.dupe(u8, &uuid);
            },
            .inet, .cidr => {
                const addr = try row.get(pg.Cidr, col_idx);
                return formatCidr(allocator, addr);
            },
            _ => {
                return try std.fmt.allocPrint(allocator, "[OID {d}]", .{oid});
            },
        };
    }

    fn formatFloat(comptime T: type, allocator: std.mem.Allocator, value: T) ![]const u8 {
        const abs_val = @abs(value);

        if ((abs_val >= 1e15 or (abs_val > 0 and abs_val < 1e-4)) and
            !std.math.isInf(value) and !std.math.isNan(value))
        {
            return std.fmt.allocPrint(allocator, "{e}", .{value});
        }

        return std.fmt.allocPrint(allocator, "{d}", .{value});
    }

    fn formatCidr(allocator: std.mem.Allocator, cidr: pg.Cidr) ![]const u8 {
        if (cidr.family == .v4) {
            const a = cidr.address;
            return try std.fmt.allocPrint(allocator, "{d}.{d}.{d}.{d}/{d}", .{
                a[0], a[1], a[2], a[3], cidr.netmask,
            });
        } else {
            var g: [8]u16 = undefined;
            for (0..8) |i| {
                const first = @as(u16, cidr.address[i * 2]);
                const second = @as(u16, cidr.address[i * 2 + 1]);
                g[i] = (first << 8) | second;
            }
            return try std.fmt.allocPrint(
                allocator,
                "{x}:{x}:{x}:{x}:{x}:{x}:{x}:{x}/{d}",
                .{ g[0], g[1], g[2], g[3], g[4], g[5], g[6], g[7], cidr.netmask },
            );
        }
    }
};

pub fn setupTestClient(allocator: std.mem.Allocator, io: std.Io) !Client {
    const cfg = try config.getTestConfig(allocator);
    var client = try Client.init(io, allocator, cfg);
    errdefer client.deinit();

    const connected = try client.checkConnection();
    try testing.expect(connected);

    return client;
}

test "should avoid memory leak" {
    var client = try setupTestClient(testing.allocator, testing.io);
    defer client.deinit();

    var res = try client.execute("SELECT 'test'::text, 123::int4");
    res.deinit();
}

// bools

test "should return true on true value and false on false" {
    var client = try setupTestClient(testing.allocator, testing.io);
    defer client.deinit();

    var res = try client.execute("SELECT true, false");
    defer res.deinit();

    const sel = res.payload.select;

    try testing.expectEqualStrings("true", sel.rows[0][0]);
    try testing.expectEqualStrings("false", sel.rows[0][1]);
}

test "should correctly process casting null to bool" {
    var client = try setupTestClient(testing.allocator, testing.io);
    defer client.deinit();

    var res = try client.execute("SELECT null::bool");
    defer res.deinit();

    const sel = res.payload.select;

    try testing.expectEqualStrings("[NULL]", sel.rows[0][0]);
}

// integers

test "should return integers values as strings" {
    var client = try setupTestClient(testing.allocator, testing.io);
    defer client.deinit();

    var res = try client.execute(
        \\ SELECT
        \\ 123::int2, 65536::int4, 726361236123::int8,
        \\ 123::smallint, 65536::int, 726361236123::bigint
    );
    defer res.deinit();

    const sel = res.payload.select;

    try testing.expectEqualStrings("123", sel.rows[0][0]);
    try testing.expectEqualStrings("65536", sel.rows[0][1]);
    try testing.expectEqualStrings("726361236123", sel.rows[0][2]);
    try testing.expectEqualStrings("123", sel.rows[0][3]);
    try testing.expectEqualStrings("65536", sel.rows[0][4]);
    try testing.expectEqualStrings("726361236123", sel.rows[0][5]);
}

test "should correctly process integers borders values as strings" {
    var client = try setupTestClient(testing.allocator, testing.io);
    defer client.deinit();

    var res = try client.execute(
        \\ SELECT
        \\ (-32768)::int2, 32767::int2,
        \\ (-2147483648)::int4, 2147483647::int4,
        \\ (-9223372036854775808)::int8, 9223372036854775807::int8
    );
    defer res.deinit();

    const sel = res.payload.select;

    try testing.expectEqualStrings("-32768", sel.rows[0][0]);
    try testing.expectEqualStrings("32767", sel.rows[0][1]);
    try testing.expectEqualStrings("-2147483648", sel.rows[0][2]);
    try testing.expectEqualStrings("2147483647", sel.rows[0][3]);
    try testing.expectEqualStrings("-9223372036854775808", sel.rows[0][4]);
    try testing.expectEqualStrings("9223372036854775807", sel.rows[0][5]);
}

test "should correctly process casting null to int" {
    var client = try setupTestClient(testing.allocator, testing.io);
    defer client.deinit();

    var res = try client.execute("SELECT null::int");
    defer res.deinit();

    const sel = res.payload.select;

    try testing.expectEqualStrings("[NULL]", sel.rows[0][0]);
}

// floats

test "should return float values as strings" {
    var client = try setupTestClient(testing.allocator, testing.io);
    defer client.deinit();

    var res = try client.execute(
        \\ SELECT
        \\ 3.14159::float4,
        \\ 2.718281828459045::float8,
        \\ 3.14159::float,
        \\ 2.718281828459045::double precision
    );
    defer res.deinit();

    try testing.expectEqual(.select, std.meta.activeTag(res.payload));
    const sel = res.payload.select;

    try testing.expectEqualStrings("3.14159", sel.rows[0][0]);
    try testing.expectEqualStrings("2.718281828459045", sel.rows[0][1]);
    try testing.expectEqualStrings("3.14159", sel.rows[0][2]);
    try testing.expectEqualStrings("2.718281828459045", sel.rows[0][3]);
}

test "should correctly process float borders and special values as strings" {
    var client = try setupTestClient(testing.allocator, testing.io);
    defer client.deinit();

    var res = try client.execute(
        \\ SELECT
        \\    '3.4028235e38'::float4,
        \\    '-3.4028235e38'::float4,
        \\    '1.7976931348623157e308'::float8,
        \\    '-1.7976931348623157e308'::float8,
        \\    'Infinity'::float4,
        \\    '-Infinity'::float4,
        \\    'NaN'::float4
    );
    defer res.deinit();

    try testing.expectEqual(.select, std.meta.activeTag(res.payload));
    const sel = res.payload.select;

    try testing.expectEqualStrings("3.4028235e38", sel.rows[0][0]);
    try testing.expectEqualStrings("-3.4028235e38", sel.rows[0][1]);
    try testing.expectEqualStrings("1.7976931348623157e308", sel.rows[0][2]);
    try testing.expectEqualStrings("-1.7976931348623157e308", sel.rows[0][3]);
    try testing.expectEqualStrings("inf", sel.rows[0][4]);
    try testing.expectEqualStrings("-inf", sel.rows[0][5]);
    try testing.expectEqualStrings("nan", sel.rows[0][6]);
}

test "should switch between scientific and decimal notation based on thresholds" {
    var client = try setupTestClient(testing.allocator, testing.io);
    defer client.deinit();

    var res = try client.execute(
        \\ SELECT
        \\    0.0001::float8,
        \\    0.00001::float8,
        \\    100000000000000::float8,
        \\    1000000000000000::float8,
        \\    0.0::float8,
        \\    -0.00005::float4
    );
    defer res.deinit();

    try testing.expectEqual(.select, std.meta.activeTag(res.payload));
    const sel = res.payload.select;

    try testing.expectEqualStrings("0.0001", sel.rows[0][0]);
    try testing.expectEqualStrings("1e-5", sel.rows[0][1]);
    try testing.expectEqualStrings("100000000000000", sel.rows[0][2]);
    try testing.expectEqualStrings("1e15", sel.rows[0][3]);
    try testing.expectEqualStrings("0", sel.rows[0][4]);
    try testing.expectEqualStrings("-5e-5", sel.rows[0][5]);
}

test "should correctly process casting null to float" {
    var client = try setupTestClient(testing.allocator, testing.io);
    defer client.deinit();

    var res = try client.execute("SELECT null::float");
    defer res.deinit();

    const sel = res.payload.select;

    try testing.expectEqualStrings("[NULL]", sel.rows[0][0]);
}

// numeric

test "should return numeric values as strings" {
    var client = try setupTestClient(testing.allocator, testing.io);
    defer client.deinit();

    var res = try client.execute(
        \\ SELECT
        \\ 3.14159::numeric,
        \\ 2.718281828459045235360287471352::numeric,
        \\ 2.718281828459045235360287471352::numeric(21,20)
    );
    defer res.deinit();

    try testing.expectEqual(.select, std.meta.activeTag(res.payload));
    const sel = res.payload.select;

    try testing.expectEqualStrings("3.14159", sel.rows[0][0]);
    try testing.expectEqualStrings("2.718281828459045235360287471352", sel.rows[0][1]);
    try testing.expectEqualStrings("2.71828182845904523536", sel.rows[0][2]);
}

test "should handle complex numeric cases" {
    var client = try setupTestClient(testing.allocator, testing.io);
    defer client.deinit();

    var res = try client.execute(
        \\ SELECT
        \\    123456789012345678901234567890.12345678901234567890::numeric,
        \\    -98765432109876543210.98765432109876543210::numeric,
        // TODO: return after bug will be fixed https://github.com/karlseguin/pg.zig/pull/128
        // \\    0.00000000000000000000000000000000000000000000000001::numeric,
        \\    0.0001::numeric,
        \\    123.4567::numeric(10, 2),
        \\    'NaN'::numeric,
        \\    'Infinity'::numeric,
        \\    '-Infinity'::numeric,
        \\    -0.1234::numeric,
        // TODO: return after bug will be fixed https://github.com/karlseguin/pg.zig/pull/128
        // \\    0::numeric,
        // \\    1000000000000000000000000000::numeric
    );
    defer res.deinit();

    try testing.expectEqual(.select, std.meta.activeTag(res.payload));
    const sel = res.payload.select;

    try testing.expectEqualStrings("123456789012345678901234567890.12345678901234567890", sel.rows[0][0]);
    try testing.expectEqualStrings("-98765432109876543210.98765432109876543210", sel.rows[0][1]);
    // TODO: return after bug will be fixed https://github.com/karlseguin/pg.zig/pull/128
    // try testing.expectEqualStrings("0.00000000000000000000000000000000000000000000000001", sel.rows[0][2]);
    try testing.expectEqualStrings("0.0001", sel.rows[0][2]);
    try testing.expectEqualStrings("123.46", sel.rows[0][3]);
    try testing.expectEqualStrings("nan", sel.rows[0][4]);
    try testing.expectEqualStrings("inf", sel.rows[0][5]);
    try testing.expectEqualStrings("-inf", sel.rows[0][6]);
    try testing.expectEqualStrings("-0.1234", sel.rows[0][7]);
    // TODO: return after bug will be fixed https://github.com/karlseguin/pg.zig/pull/128
    // try testing.expectEqualStrings("0", sel.rows[0][8]);
    // try testing.expectEqualStrings("1000000000000000000000000000", sel.rows[0][9]);
}

test "should correctly process casting null to numeric" {
    var client = try setupTestClient(testing.allocator, testing.io);
    defer client.deinit();

    var res = try client.execute("SELECT null::numeric");
    defer res.deinit();

    const sel = res.payload.select;

    try testing.expectEqualStrings("[NULL]", sel.rows[0][0]);
}
