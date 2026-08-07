const std = @import("std");
const pg = @import("pg");
const builtin = @import("builtin");
const testing = std.testing;

const config = @import("../config.zig");
const Config = config.Config;
const QueryResult = @import("result.zig").QueryResult;
const Oid = @import("oids.zig").Oid;

pub const SessionContext = struct {
    timezone_name: [64]u8,
    timezone_offset_min: i16,
    server_version: [64]u8,

    pub fn getTimezone(self: *const SessionContext) []const u8 {
        return std.mem.sliceTo(&self.timezone_name, 0);
    }

    pub fn getServerVersion(self: *const SessionContext) []const u8 {
        return std.mem.sliceTo(&self.server_version, 0);
    }
};

pub const Client = struct {
    pool: *pg.Pool,
    allocator: std.mem.Allocator,
    io: std.Io,
    session_context: SessionContext,

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

        var tz_buf: [64]u8 = [_]u8{0} ** 64;
        var ver_buf: [64]u8 = [_]u8{0} ** 64;

        @memcpy(tz_buf[0..3], "UTC");
        @memcpy(ver_buf[0..7], "unknown");

        return .{
            .pool = pool,
            .allocator = allocator,
            .io = io,
            .session_context = .{
                .timezone_name = tz_buf,
                .timezone_offset_min = 0,
                .server_version = ver_buf,
            },
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
                    cells[col_idx] = try self.cellToString(allocator, row, col_idx);
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

    pub fn syncSessionContext(self: *Client) !void {
        const query =
            \\ SELECT
            \\   current_setting('TimeZone'),
            \\   (EXTRACT(timezone FROM now())::int4 / 60)::int2,
            \\   current_setting('server_version')
        ;

        var result = try self.pool.query(query, .{});
        defer result.deinit();

        while (try result.next()) |row| {
            const tz_name = try row.get([]const u8, 0);
            const offset_min = try row.get(i16, 1);
            const ver = try row.get([]const u8, 2);

            var tz_buf: [64]u8 = [_]u8{0} ** 64;
            var ver_buf: [64]u8 = [_]u8{0} ** 64;

            const min_tz_len = @min(63, tz_name.len);
            const min_ver_len = @min(63, ver.len);

            @memcpy(tz_buf[0..min_tz_len], tz_name[0..min_tz_len]);
            @memcpy(ver_buf[0..min_ver_len], ver[0..min_ver_len]);

            self.session_context = .{
                .timezone_name = tz_buf,
                .timezone_offset_min = offset_min,
                .server_version = ver_buf,
            };
        }
    }

    fn cellToString(self: *Client, allocator: std.mem.Allocator, row: pg.Row, col_idx: usize) ![]const u8 {
        if (row.values[col_idx].is_null) {
            return "[NULL]";
        }

        const oid: Oid = @enumFromInt(row.oids[col_idx]);
        return switch (oid) {
            .name, .text, .xml, .bpchar, .varchar, .json, .jsonb, .unknown, .char => {
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
                return formatCidr(allocator, addr, oid);
            },
            .bytea => {
                const bytes = try row.get([]const u8, col_idx);
                return formatBytea(allocator, bytes.len);
            },
            .timestamp => {
                const ts = try row.get(i64, col_idx);
                return formatTimestamp(allocator, ts, null);
            },
            .timestamptz => {
                const ts = try row.get(i64, col_idx);
                const offset = self.session_context.timezone_offset_min;
                return formatTimestamp(allocator, ts, offset);
            },
            .date => {
                const bytes = try row.get([]const u8, col_idx);
                return formatDate(allocator, bytes);
            },
            .time => {
                const bytes = try row.get([]const u8, col_idx);
                return formatTime(allocator, bytes);
            },
            .interval => {
                const bytes = try row.get([]const u8, col_idx);
                return formatInterval(allocator, bytes);
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

    fn formatCidr(allocator: std.mem.Allocator, cidr: pg.Cidr, oid: Oid) ![]const u8 {
        var buf: [64]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);

        const max_mask: u8 = if (cidr.family == .v4) 32 else 128;
        const show_mask = (oid == .cidr) or (cidr.netmask != max_mask);

        if (cidr.family == .v4) {
            const a = cidr.address;
            if (show_mask) {
                try writer.print("{d}.{d}.{d}.{d}/{d}", .{ a[0], a[1], a[2], a[3], cidr.netmask });
            } else {
                try writer.print("{d}.{d}.{d}.{d}", .{ a[0], a[1], a[2], a[3] });
            }
        } else {
            var words: [8]u16 = undefined;
            for (0..8) |i| {
                const first = @as(u16, cidr.address[i * 2]);
                const second = @as(u16, cidr.address[i * 2 + 1]);
                words[i] = (first << 8) | second;
            }

            var best_start: usize = 0;
            var best_len: usize = 0;
            var cur_start: usize = 0;
            var cur_len: usize = 0;

            for (words, 0..) |w, i| {
                if (w == 0) {
                    if (cur_len == 0) cur_start = i;
                    cur_len += 1;
                    if (cur_len > best_len) {
                        best_start = cur_start;
                        best_len = cur_len;
                    }
                } else {
                    cur_len = 0;
                }
            }

            if (best_len < 2) best_len = 0;

            var i: usize = 0;
            var needs_colon = false;
            while (i < 8) : (i += 1) {
                if (best_len > 0 and i == best_start) {
                    try writer.writeAll("::");
                    i += best_len - 1;
                    needs_colon = false;
                } else {
                    if (needs_colon) try writer.writeByte(':');
                    try writer.print("{x}", .{words[i]});
                    needs_colon = true;
                }
            }

            if (show_mask) {
                try writer.print("/{d}", .{cidr.netmask});
            }
        }

        return allocator.dupe(u8, writer.buffered());
    }

    fn formatBytea(allocator: std.mem.Allocator, len: usize) ![]const u8 {
        if (len < 1024) {
            return std.fmt.allocPrint(allocator, "[BYTEA {d} B]", .{len});
        }
        const f_len = @as(f64, @floatFromInt(len));
        if (len < 1024 * 1024) {
            return std.fmt.allocPrint(allocator, "[BYTEA {d:.1} KiB]", .{f_len / 1024.0});
        }
        if (len < 1024 * 1024 * 1024) {
            return std.fmt.allocPrint(allocator, "[BYTEA {d:.1} MiB]", .{f_len / (1024.0 * 1024.0)});
        }
        return std.fmt.allocPrint(allocator, "[BYTEA {d:.2} GiB]", .{f_len / (1024.0 * 1024.0 * 1024.0)});
    }

    fn formatTimestamp(allocator: std.mem.Allocator, usec: i64, tz_offset_minutes: ?i16) ![]const u8 {
        var actual_usec = usec;
        if (tz_offset_minutes) |offset| {
            actual_usec += @as(i64, offset) * 60 * 1_000_000;
        }

        const total_sec = @divFloor(actual_usec, 1_000_000);
        const rem_us = @mod(actual_usec, 1_000_000);

        const cycle_secs: i64 = 12622780800;
        const cycles = @divFloor(-total_sec, cycle_secs) + 1;
        const pos_sec: u64 = @intCast(total_sec + cycles * cycle_secs);

        const epoch_sec = std.time.epoch.EpochSeconds{ .secs = pos_sec };
        const year_day = epoch_sec.getEpochDay().calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        const day_sec = epoch_sec.getDaySeconds();

        const year = year_day.year - @as(i32, @intCast(cycles * 400));

        var buf: [40]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);

        if (year <= 0) {
            try writer.print("{d:0>4}-", .{
                @as(u32, @intCast(1 - year)),
            });
        } else {
            try writer.print("{d:0>4}-", .{
                @as(u32, @intCast(year)),
            });
        }

        try writer.print("{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
            month_day.month.numeric(),
            month_day.day_index + 1,
            day_sec.getHoursIntoDay(),
            day_sec.getMinutesIntoHour(),
            day_sec.getSecondsIntoMinute(),
        });

        if (rem_us != 0) {
            try writer.print(".{d:0>6}", .{@as(u32, @intCast(rem_us))});
        }

        if (tz_offset_minutes) |offset| {
            if (offset == 0) {
                try writer.writeAll("+00");
            } else {
                const abs_offset: u15 = @intCast(@abs(offset));
                const hours = @divTrunc(abs_offset, 60);
                const mins = @mod(abs_offset, 60);
                const sign: u8 = if (offset >= 0) '+' else '-';

                if (mins == 0) {
                    try writer.print("{c}{d:0>2}", .{ sign, hours });
                } else {
                    try writer.print("{c}{d:0>2}:{d:0>2}", .{ sign, hours, mins });
                }
            }
        }

        if (year <= 0) {
            try writer.writeAll(" BC");
        }
        return allocator.dupe(u8, writer.buffered());
    }

    fn formatDate(allocator: std.mem.Allocator, bytes: []const u8) ![]const u8 {
        const days_2000 = std.mem.readInt(i32, bytes[0..4], .big);
        const days_from_1970_to_2000 = 10957;
        const days_1970: i64 = @as(i64, days_2000) + days_from_1970_to_2000;

        const cycle_days: i64 = 146097;
        const cycles = @divFloor(-days_1970, cycle_days) + 1;
        const pos_days: u64 = @intCast(days_1970 + cycles * cycle_days);

        const epoch_day = std.time.epoch.EpochDay{ .day = @intCast(pos_days) };
        const year_day = epoch_day.calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        const year = year_day.year - @as(i32, @intCast(cycles * 400));

        var buf: [14]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);

        if (year <= 0) {
            try writer.print("{d:0>4}-", .{@as(u32, @intCast(1 - year))});
        } else {
            try writer.print("{d:0>4}-", .{@as(u32, @intCast(year))});
        }

        try writer.print("{d:0>2}-{d:0>2}", .{
            month_day.month.numeric(),
            month_day.day_index + 1,
        });

        if (year <= 0) {
            try writer.writeAll(" BC");
        }
        return allocator.dupe(u8, writer.buffered());
    }

    fn formatTime(allocator: std.mem.Allocator, bytes: []const u8) ![]const u8 {
        const usec = std.mem.readInt(u64, bytes[0..8], .big);
        const total_sec = @divFloor(usec, 1_000_000);
        const rem_us = @mod(usec, 1_000_000);

        const hours = @divFloor(total_sec, 3600);
        const mins = @divFloor(@mod(total_sec, 3600), 60);
        const secs = @mod(total_sec, 60);

        var buf: [16]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);

        try writer.print("{d:0>2}:{d:0>2}:{d:0>2}", .{ hours, mins, secs });

        if (rem_us != 0) {
            try writer.print(".{d:0>6}", .{rem_us});
        }
        return allocator.dupe(u8, writer.buffered());
    }

    fn formatInterval(allocator: std.mem.Allocator, bytes: []const u8) ![]const u8 {
        const usec = std.mem.readInt(i64, bytes[0..8], .big);
        const days = std.mem.readInt(i32, bytes[8..12], .big);
        const months = std.mem.readInt(i32, bytes[12..16], .big);

        var buf: [128]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);

        var has_prev = false;

        if (months != 0) {
            try writer.print("{d} mon{s}", .{ months, if (months != 1 and months != -1) "s" else "" });
            has_prev = true;
        }

        if (days != 0) {
            if (has_prev) try writer.writeByte(' ');
            try writer.print("{d} day{s}", .{ days, if (days != 1 and days != -1) "s" else "" });
            has_prev = true;
        }

        if (usec != 0 or !has_prev) {
            if (has_prev) try writer.writeByte(' ');

            if (usec < 0) {
                try writer.writeByte('-');
            }

            const abs_us: u64 = @intCast(@abs(usec));
            const total_sec = abs_us / 1_000_000;
            const rem_us: u32 = @intCast(abs_us % 1_000_000);

            const hours = total_sec / 3600;
            const mins = (total_sec % 3600) / 60;
            const secs = total_sec % 60;

            try writer.print("{d:0>2}:{d:0>2}:{d:0>2}", .{ hours, mins, secs });
            if (rem_us != 0) {
                try writer.print(".{d:0>6}", .{rem_us});
            }
        }

        return allocator.dupe(u8, writer.buffered());
    }
};

pub fn setupTestClient(allocator: std.mem.Allocator, io: std.Io) !Client {
    comptime {
        if (!builtin.is_test) {
            @compileError("setupTestClient is test-only and cannot be used in production code!");
        }
    }

    const cfg = try config.getTestConfig(allocator);
    var client = try Client.init(io, allocator, cfg);
    errdefer client.deinit();

    const connected = try client.checkConnection();
    try testing.expect(connected);

    return client;
}

fn isValidUuid(str: []const u8) bool {
    comptime {
        if (!builtin.is_test) {
            @compileError("isValidUuid is test-only and cannot be used in production code!");
        }
    }

    if (str.len != 36) return false;

    for (str, 0..) |c, i| {
        switch (i) {
            8, 13, 18, 23 => if (c != '-') return false,
            else => if (!std.ascii.isHex(c)) return false,
        }
    }
    return true;
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
        \\    0.00000000000000000000000000000000000000000000000001::numeric,
        \\    123.4567::numeric(10, 2),
        \\    'NaN'::numeric,
        \\    'Infinity'::numeric,
        \\    '-Infinity'::numeric,
        \\    -0.1234::numeric,
        \\    0::numeric,
        \\    1000000000000000000000000000::numeric
    );
    defer res.deinit();

    try testing.expectEqual(.select, std.meta.activeTag(res.payload));
    const sel = res.payload.select;

    try testing.expectEqualStrings("123456789012345678901234567890.12345678901234567890", sel.rows[0][0]);
    try testing.expectEqualStrings("-98765432109876543210.98765432109876543210", sel.rows[0][1]);
    try testing.expectEqualStrings("0.00000000000000000000000000000000000000000000000001", sel.rows[0][2]);
    try testing.expectEqualStrings("123.46", sel.rows[0][3]);
    try testing.expectEqualStrings("nan", sel.rows[0][4]);
    try testing.expectEqualStrings("inf", sel.rows[0][5]);
    try testing.expectEqualStrings("-inf", sel.rows[0][6]);
    try testing.expectEqualStrings("-0.1234", sel.rows[0][7]);
    try testing.expectEqualStrings("0", sel.rows[0][8]);
    try testing.expectEqualStrings("1000000000000000000000000000", sel.rows[0][9]);
}

test "should correctly process casting null to numeric" {
    var client = try setupTestClient(testing.allocator, testing.io);
    defer client.deinit();

    var res = try client.execute("SELECT null::numeric");
    defer res.deinit();

    const sel = res.payload.select;

    try testing.expectEqualStrings("[NULL]", sel.rows[0][0]);
}

// uuid

test "should return uuid value as string" {
    var client = try setupTestClient(testing.allocator, testing.io);
    defer client.deinit();

    var res = try client.execute(
        \\ SELECT 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11'::uuid
    );
    defer res.deinit();

    try testing.expectEqual(.select, std.meta.activeTag(res.payload));
    const sel = res.payload.select;

    try testing.expectEqualStrings("a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11", sel.rows[0][0]);
}

test "should handle complex uuid cases" {
    var client = try setupTestClient(testing.allocator, testing.io);
    defer client.deinit();

    var res = try client.execute(
        \\ SELECT
        \\    '00000000-0000-0000-0000-000000000000'::uuid,
        \\    'ffffffff-ffff-ffff-ffff-ffffffffffff'::uuid,
        \\    'A0EEBC99-9C0B-4EF8-BB6D-6BB9BD380A11'::uuid,
        \\    'a0eebc999c0b4ef8bb6d6bb9bd380a11'::uuid,
        \\    '{a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11}'::uuid,
        \\    gen_random_uuid()
    );
    defer res.deinit();

    try testing.expectEqual(.select, std.meta.activeTag(res.payload));
    const sel = res.payload.select;

    try testing.expectEqualStrings("00000000-0000-0000-0000-000000000000", sel.rows[0][0]);
    try testing.expectEqualStrings("ffffffff-ffff-ffff-ffff-ffffffffffff", sel.rows[0][1]);
    try testing.expectEqualStrings("a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11", sel.rows[0][2]);
    try testing.expectEqualStrings("a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11", sel.rows[0][3]);
    try testing.expectEqualStrings("a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11", sel.rows[0][4]);
    try testing.expect(isValidUuid(sel.rows[0][5]));
}

test "should correctly process casting null to uuid" {
    var client = try setupTestClient(testing.allocator, testing.io);
    defer client.deinit();

    var res = try client.execute("SELECT null::uuid");
    defer res.deinit();

    const sel = res.payload.select;

    try testing.expectEqualStrings("[NULL]", sel.rows[0][0]);
}

// cidr and inet

test "should return cidr and inet values as string" {
    var client = try setupTestClient(testing.allocator, testing.io);
    defer client.deinit();

    var res = try client.execute(
        \\ SELECT '192.168.1.1/24'::inet, '192.168.1.0/24'::cidr
    );
    defer res.deinit();

    try testing.expectEqual(.select, std.meta.activeTag(res.payload));
    const sel = res.payload.select;

    try testing.expectEqualStrings("192.168.1.1/24", sel.rows[0][0]);
    try testing.expectEqualStrings("192.168.1.0/24", sel.rows[0][1]);
}

test "should handle complex cird and inet cases" {
    var client = try setupTestClient(testing.allocator, testing.io);
    defer client.deinit();

    var res = try client.execute(
        \\ SELECT
        \\    '192.168.1.0/24'::cidr,
        \\    '10.0.0.0/8'::inet,
        \\    '192.168.1.1'::inet,
        \\    '192.168.1.0'::cidr,
        \\    '2001:db8::1/64'::inet,
        \\    '::1/128'::inet,
        \\    '0.0.0.0/0'::cidr,
        \\    '::/0'::cidr,
        \\    '255.255.255.255/32'::inet
    );
    defer res.deinit();

    try testing.expectEqual(.select, std.meta.activeTag(res.payload));
    const sel = res.payload.select;

    try testing.expectEqualStrings("192.168.1.0/24", sel.rows[0][0]);
    try testing.expectEqualStrings("10.0.0.0/8", sel.rows[0][1]);
    try testing.expectEqualStrings("192.168.1.1", sel.rows[0][2]);
    try testing.expectEqualStrings("192.168.1.0/32", sel.rows[0][3]);
    try testing.expectEqualStrings("2001:db8::1/64", sel.rows[0][4]);
    try testing.expectEqualStrings("::1", sel.rows[0][5]);
    try testing.expectEqualStrings("0.0.0.0/0", sel.rows[0][6]);
    try testing.expectEqualStrings("::/0", sel.rows[0][7]);
    try testing.expectEqualStrings("255.255.255.255", sel.rows[0][8]);
}

test "should correctly process casting null to cidr and inet" {
    var client = try setupTestClient(testing.allocator, testing.io);
    defer client.deinit();

    var res = try client.execute("SELECT null::cidr, null::inet");
    defer res.deinit();

    const sel = res.payload.select;

    try testing.expectEqualStrings("[NULL]", sel.rows[0][0]);
    try testing.expectEqualStrings("[NULL]", sel.rows[0][1]);
}

// "char" (OID 18)

test "should return \"char\" value as string" {
    var client = try setupTestClient(testing.allocator, testing.io);
    defer client.deinit();

    var res = try client.execute(
        \\ SELECT 'c'::"char"
    );
    defer res.deinit();

    try testing.expectEqual(.select, std.meta.activeTag(res.payload));
    const sel = res.payload.select;

    try testing.expectEqualStrings("c", sel.rows[0][0]);
}

test "should handle complex \"char\" cases" {
    var client = try setupTestClient(testing.allocator, testing.io);
    defer client.deinit();

    var res = try client.execute(
        \\ SELECT
        \\    ''::"char",
        \\    'qwerty'::"char",
        \\    '7'::"char"
    );
    defer res.deinit();

    try testing.expectEqual(.select, std.meta.activeTag(res.payload));
    const sel = res.payload.select;

    try testing.expectEqualStrings("\x00", sel.rows[0][0]);
    try testing.expectEqualStrings("q", sel.rows[0][1]);
    try testing.expectEqualStrings("7", sel.rows[0][2]);
}

test "should correctly process casting null to \"char\"" {
    var client = try setupTestClient(testing.allocator, testing.io);
    defer client.deinit();

    var res = try client.execute("SELECT null::\"char\"");
    defer res.deinit();

    const sel = res.payload.select;

    try testing.expectEqualStrings("[NULL]", sel.rows[0][0]);
}

// bpchar

test "should return bpchar value as string" {
    var client = try setupTestClient(testing.allocator, testing.io);
    defer client.deinit();

    var res = try client.execute(
        \\ SELECT 'hello'::char(10)
    );
    defer res.deinit();

    try testing.expectEqual(.select, std.meta.activeTag(res.payload));
    const sel = res.payload.select;

    try testing.expectEqualStrings("hello     ", sel.rows[0][0]);
}

test "should handle complex bpchar cases" {
    var client = try setupTestClient(testing.allocator, testing.io);
    defer client.deinit();

    var res = try client.execute(
        \\ SELECT
        \\    ''::char(5),
        \\    'qwerty'::char(3),
        \\    'тест'::char(6),
        \\    'hello'::bpchar,
        \\    '😃 Emoji 💁👌🎍😍'::bpchar(10)
    );
    defer res.deinit();

    try testing.expectEqual(.select, std.meta.activeTag(res.payload));
    const sel = res.payload.select;

    try testing.expectEqualStrings("     ", sel.rows[0][0]);
    try testing.expectEqualStrings("qwe", sel.rows[0][1]);
    try testing.expectEqualStrings("тест  ", sel.rows[0][2]);
    try testing.expectEqualStrings("hello", sel.rows[0][3]);
    try testing.expectEqualStrings("😃 Emoji 💁👌", sel.rows[0][4]);
}

test "should correctly process casting null to bpchar" {
    var client = try setupTestClient(testing.allocator, testing.io);
    defer client.deinit();

    var res = try client.execute("SELECT null::char(10)");
    defer res.deinit();

    const sel = res.payload.select;

    try testing.expectEqualStrings("[NULL]", sel.rows[0][0]);
}

// varchar

test "should return varchar value as string" {
    var client = try setupTestClient(testing.allocator, testing.io);
    defer client.deinit();

    var res = try client.execute(
        \\ SELECT 'hello'::varchar(10)
    );
    defer res.deinit();

    try testing.expectEqual(.select, std.meta.activeTag(res.payload));
    const sel = res.payload.select;

    try testing.expectEqualStrings("hello", sel.rows[0][0]);
}

test "should handle complex varchar cases" {
    var client = try setupTestClient(testing.allocator, testing.io);
    defer client.deinit();

    var res = try client.execute(
        \\ SELECT
        \\    ''::varchar(5),
        \\    'qwerty'::varchar(3),
        \\    'тест'::varchar(6),
        \\    'hello'::varchar,
        \\    '😃 Emoji 💁👌🎍😍'::varchar(10)
    );
    defer res.deinit();

    try testing.expectEqual(.select, std.meta.activeTag(res.payload));
    const sel = res.payload.select;

    try testing.expectEqualStrings("", sel.rows[0][0]);
    try testing.expectEqualStrings("qwe", sel.rows[0][1]);
    try testing.expectEqualStrings("тест", sel.rows[0][2]);
    try testing.expectEqualStrings("hello", sel.rows[0][3]);
    try testing.expectEqualStrings("😃 Emoji 💁👌", sel.rows[0][4]);
}

test "should correctly process casting null to varchar" {
    var client = try setupTestClient(testing.allocator, testing.io);
    defer client.deinit();

    var res = try client.execute("SELECT null::varchar(10)");
    defer res.deinit();

    const sel = res.payload.select;

    try testing.expectEqualStrings("[NULL]", sel.rows[0][0]);
}

// text

test "should return text value as string" {
    var client = try setupTestClient(testing.allocator, testing.io);
    defer client.deinit();

    var res = try client.execute(
        \\ SELECT 'hello'::text
    );
    defer res.deinit();

    try testing.expectEqual(.select, std.meta.activeTag(res.payload));
    const sel = res.payload.select;

    try testing.expectEqualStrings("hello", sel.rows[0][0]);
}

test "should handle complex text cases" {
    var client = try setupTestClient(testing.allocator, testing.io);
    defer client.deinit();

    var res = try client.execute(
        \\ SELECT
        \\    ''::text,
        \\    'тест'::text,
        \\    '😃 Emoji 💁👌'::text,
        \\    E'line1\nline2\ttab'::text
    );
    defer res.deinit();

    try testing.expectEqual(.select, std.meta.activeTag(res.payload));
    const sel = res.payload.select;

    try testing.expectEqualStrings("", sel.rows[0][0]);
    try testing.expectEqualStrings("тест", sel.rows[0][1]);
    try testing.expectEqualStrings("😃 Emoji 💁👌", sel.rows[0][2]);
    try testing.expectEqualStrings("line1\nline2\ttab", sel.rows[0][3]);
}

test "should correctly process casting null to text" {
    var client = try setupTestClient(testing.allocator, testing.io);
    defer client.deinit();

    var res = try client.execute("SELECT null::text");
    defer res.deinit();

    const sel = res.payload.select;

    try testing.expectEqualStrings("[NULL]", sel.rows[0][0]);
}

// name

test "should return name value as string" {
    var client = try setupTestClient(testing.allocator, testing.io);
    defer client.deinit();

    var res = try client.execute(
        \\ SELECT 'hello'::name
    );
    defer res.deinit();

    try testing.expectEqual(.select, std.meta.activeTag(res.payload));
    const sel = res.payload.select;

    try testing.expectEqualStrings("hello", sel.rows[0][0]);
}

test "should handle complex name cases and truncation at 63 bytes" {
    var client = try setupTestClient(testing.allocator, testing.io);
    defer client.deinit();

    var res = try client.execute(
        \\ SELECT
        \\    ''::name,
        \\    'тест'::name,
        \\    'a123456789b123456789c123456789d123456789e123456789f123456789123456789'::name
    );
    defer res.deinit();

    try testing.expectEqual(.select, std.meta.activeTag(res.payload));
    const sel = res.payload.select;

    try testing.expectEqualStrings("", sel.rows[0][0]);
    try testing.expectEqualStrings("тест", sel.rows[0][1]);
    try testing.expectEqualStrings("a123456789b123456789c123456789d123456789e123456789f123456789123", sel.rows[0][2]);
}

test "should correctly process casting null to name" {
    var client = try setupTestClient(testing.allocator, testing.io);
    defer client.deinit();

    var res = try client.execute("SELECT null::name");
    defer res.deinit();

    const sel = res.payload.select;

    try testing.expectEqualStrings("[NULL]", sel.rows[0][0]);
}

// unknown

test "should return unknown value as string" {
    var client = try setupTestClient(testing.allocator, testing.io);
    defer client.deinit();

    var res = try client.execute(
        \\ SELECT 'hello'
    );
    defer res.deinit();

    try testing.expectEqual(.select, std.meta.activeTag(res.payload));
    const sel = res.payload.select;

    try testing.expectEqualStrings("hello", sel.rows[0][0]);
}

test "should handle complex unknown cases" {
    var client = try setupTestClient(testing.allocator, testing.io);
    defer client.deinit();

    var res = try client.execute(
        \\ SELECT
        \\    '',
        \\    'тест'::unknown,
        \\    '😃 Emoji 💁👌',
        \\    E'line1\nline2'
    );
    defer res.deinit();

    try testing.expectEqual(.select, std.meta.activeTag(res.payload));
    const sel = res.payload.select;

    try testing.expectEqualStrings("", sel.rows[0][0]);
    try testing.expectEqualStrings("тест", sel.rows[0][1]);
    try testing.expectEqualStrings("😃 Emoji 💁👌", sel.rows[0][2]);
    try testing.expectEqualStrings("line1\nline2", sel.rows[0][3]);
}

test "should correctly process casting null to unknown" {
    var client = try setupTestClient(testing.allocator, testing.io);
    defer client.deinit();

    var res = try client.execute("SELECT null::unknown");
    defer res.deinit();

    const sel = res.payload.select;

    try testing.expectEqualStrings("[NULL]", sel.rows[0][0]);
}

// xml

test "should return xml value as string" {
    var client = try setupTestClient(testing.allocator, testing.io);
    defer client.deinit();

    var res = try client.execute(
        \\ SELECT '<foo>bar</foo>'::xml
    );
    defer res.deinit();

    try testing.expectEqual(.select, std.meta.activeTag(res.payload));
    const sel = res.payload.select;

    try testing.expectEqualStrings("<foo>bar</foo>", sel.rows[0][0]);
}

test "should handle complex xml cases" {
    var client = try setupTestClient(testing.allocator, testing.io);
    defer client.deinit();

    var res = try client.execute(
        \\ SELECT
        \\    '<root attr="123"/>'::xml,
        \\    '<user><name>Тест</name><status>active</status></user>'::xml,
        \\    '<data>😃 Emoji 💁👌</data>'::xml,
        \\    '<?xml version="1.0"?><note><!-- comment --><to>Tove</to></note>'::xml
    );
    defer res.deinit();

    try testing.expectEqual(.select, std.meta.activeTag(res.payload));
    const sel = res.payload.select;

    try testing.expectEqualStrings("<root attr=\"123\"/>", sel.rows[0][0]);
    try testing.expectEqualStrings("<user><name>Тест</name><status>active</status></user>", sel.rows[0][1]);
    try testing.expectEqualStrings("<data>😃 Emoji 💁👌</data>", sel.rows[0][2]);
    try testing.expectEqualStrings("<note><!-- comment --><to>Tove</to></note>", sel.rows[0][3]);
}

test "should correctly process casting null to xml" {
    var client = try setupTestClient(testing.allocator, testing.io);
    defer client.deinit();

    var res = try client.execute("SELECT null::xml");
    defer res.deinit();

    const sel = res.payload.select;

    try testing.expectEqualStrings("[NULL]", sel.rows[0][0]);
}

test "should return error payload on invalid xml syntax" {
    var client = try setupTestClient(testing.allocator, testing.io);
    defer client.deinit();

    var res = try client.execute("SELECT '<unclosed>'::xml");
    defer res.deinit();

    try testing.expectEqual(.err, std.meta.activeTag(res.payload));

    const err_data = res.payload.err;
    try testing.expect(err_data.message.len > 0);
}

// json and jsonb

test "should return json and jsonb values as strings" {
    var client = try setupTestClient(testing.allocator, testing.io);
    defer client.deinit();

    var res = try client.execute(
        \\ SELECT '{"name": "John", "age": 30}'::json, '{"name": "John", "age": 30}'::jsonb
    );
    defer res.deinit();

    try testing.expectEqual(.select, std.meta.activeTag(res.payload));
    const sel = res.payload.select;

    try testing.expectEqualStrings("{\"name\": \"John\", \"age\": 30}", sel.rows[0][0]);
    try testing.expectEqualStrings("{\"age\": 30, \"name\": \"John\"}", sel.rows[0][1]);
}

test "should handle complex json and jsonb edge cases" {
    var client = try setupTestClient(testing.allocator, testing.io);
    defer client.deinit();

    var res = try client.execute(
        \\ SELECT
        \\    '[1, "two", true, null]'::json,
        \\    '{"user": {"name": "Тест", "emoji": "😃"}}'::jsonb,
        \\    '  {"spaces":   true}  '::json,
        \\    '  {"spaces":   true}  '::jsonb,
        \\    '{"a": 1, "a": 2}'::json,
        \\    '{"a": 1, "a": 2}'::jsonb,
        \\    '{}'::jsonb,
        \\    '[]'::jsonb,
        \\    '123.45'::jsonb,
        \\    '"hello"'::jsonb,
        \\    '"\u0422\u0435\u0441\u0442"'::jsonb
    );
    defer res.deinit();

    try testing.expectEqual(.select, std.meta.activeTag(res.payload));
    const sel = res.payload.select;

    try testing.expectEqualStrings("[1, \"two\", true, null]", sel.rows[0][0]);
    try testing.expectEqualStrings("{\"user\": {\"name\": \"Тест\", \"emoji\": \"😃\"}}", sel.rows[0][1]);
    try testing.expectEqualStrings("  {\"spaces\":   true}  ", sel.rows[0][2]);
    try testing.expectEqualStrings("{\"spaces\": true}", sel.rows[0][3]);
    try testing.expectEqualStrings("{\"a\": 1, \"a\": 2}", sel.rows[0][4]);
    try testing.expectEqualStrings("{\"a\": 2}", sel.rows[0][5]);
    try testing.expectEqualStrings("{}", sel.rows[0][6]);
    try testing.expectEqualStrings("[]", sel.rows[0][7]);
    try testing.expectEqualStrings("123.45", sel.rows[0][8]);
    try testing.expectEqualStrings("\"hello\"", sel.rows[0][9]);
    try testing.expectEqualStrings("\"Тест\"", sel.rows[0][10]);
}

test "should correctly process casting null to json and jsonb" {
    var client = try setupTestClient(testing.allocator, testing.io);
    defer client.deinit();

    var res = try client.execute("SELECT null::json, null::jsonb");
    defer res.deinit();

    const sel = res.payload.select;

    try testing.expectEqualStrings("[NULL]", sel.rows[0][0]);
    try testing.expectEqualStrings("[NULL]", sel.rows[0][1]);
}

test "should return error payload on invalid json syntax" {
    var client = try setupTestClient(testing.allocator, testing.io);
    defer client.deinit();

    var res = try client.execute("SELECT '{bad_json: 123}'::json");
    defer res.deinit();

    try testing.expectEqual(.err, std.meta.activeTag(res.payload));

    const err_data = res.payload.err;
    try testing.expect(err_data.message.len > 0);
}

// bytea

test "should return bytea value formatted with byte size" {
    var client = try setupTestClient(testing.allocator, testing.io);
    defer client.deinit();

    var res = try client.execute(
        \\ SELECT
        \\    '\xdeadbeef'::bytea,
        \\    '\x0102030405'::bytea
    );
    defer res.deinit();

    try testing.expectEqual(.select, std.meta.activeTag(res.payload));
    const sel = res.payload.select;

    try testing.expectEqualStrings("[BYTEA 4 B]", sel.rows[0][0]);
    try testing.expectEqualStrings("[BYTEA 5 B]", sel.rows[0][1]);
}

test "should handle complex bytea cases" {
    var client = try setupTestClient(testing.allocator, testing.io);
    defer client.deinit();

    var res = try client.execute(
        \\ SELECT
        \\    '\x'::bytea,
        \\    '\x00'::bytea,
        \\    decode(repeat('ff', 1023), 'hex'),
        \\    decode(repeat('ff', 1024), 'hex'),
        \\    decode(repeat('ff', 1536), 'hex'),
        \\    decode(repeat('ff', 1048576), 'hex'),
        \\    convert_to('тест', 'UTF8'),
        \\    convert_to('😃 Emoji 💁👌', 'UTF8')
    );
    defer res.deinit();

    try testing.expectEqual(.select, std.meta.activeTag(res.payload));
    const sel = res.payload.select;

    try testing.expectEqualStrings("[BYTEA 0 B]", sel.rows[0][0]);
    try testing.expectEqualStrings("[BYTEA 1 B]", sel.rows[0][1]);
    try testing.expectEqualStrings("[BYTEA 1023 B]", sel.rows[0][2]);
    try testing.expectEqualStrings("[BYTEA 1.0 KiB]", sel.rows[0][3]);
    try testing.expectEqualStrings("[BYTEA 1.5 KiB]", sel.rows[0][4]);
    try testing.expectEqualStrings("[BYTEA 1.0 MiB]", sel.rows[0][5]);
    try testing.expectEqualStrings("[BYTEA 8 B]", sel.rows[0][6]);
    try testing.expectEqualStrings("[BYTEA 19 B]", sel.rows[0][7]);
}

test "should correctly process casting null to bytea" {
    var client = try setupTestClient(testing.allocator, testing.io);
    defer client.deinit();

    var res = try client.execute("SELECT null::bytea");
    defer res.deinit();

    const sel = res.payload.select;

    try testing.expectEqualStrings("[NULL]", sel.rows[0][0]);
}

// timestamp

test "should return timestamp value as string" {
    var client = try setupTestClient(testing.allocator, testing.io);
    defer client.deinit();

    var res = try client.execute(
        \\ SELECT '2026-08-07 14:30:15'::timestamp
    );
    defer res.deinit();

    try testing.expectEqual(.select, std.meta.activeTag(res.payload));
    const sel = res.payload.select;

    try testing.expectEqualStrings("2026-08-07 14:30:15", sel.rows[0][0]);
}

test "should handle complex timestamp cases" {
    var client = try setupTestClient(testing.allocator, testing.io);
    defer client.deinit();

    var res = try client.execute(
        \\ SELECT
        \\    '1970-01-01 00:00:00'::timestamp,
        \\    '1969-12-31 23:59:59.999999'::timestamp,
        \\    '1950-05-15 08:30:00'::timestamp,
        \\    '2024-02-29 23:59:59.000001'::timestamp,
        \\    '2026-12-31 23:59:59'::timestamp,
        \\    '0001-01-01 00:00:00'::timestamp,
        \\    '0045-03-15 00:00:00 BC'::timestamp,
        \\    '0001-01-01 00:00:00 BC'::timestamp
    );
    defer res.deinit();

    try testing.expectEqual(.select, std.meta.activeTag(res.payload));
    const sel = res.payload.select;

    try testing.expectEqualStrings("1970-01-01 00:00:00", sel.rows[0][0]);
    try testing.expectEqualStrings("1969-12-31 23:59:59.999999", sel.rows[0][1]);
    try testing.expectEqualStrings("1950-05-15 08:30:00", sel.rows[0][2]);
    try testing.expectEqualStrings("2024-02-29 23:59:59.000001", sel.rows[0][3]);
    try testing.expectEqualStrings("2026-12-31 23:59:59", sel.rows[0][4]);
    try testing.expectEqualStrings("0001-01-01 00:00:00", sel.rows[0][5]);
    try testing.expectEqualStrings("0045-03-15 00:00:00 BC", sel.rows[0][6]);
    try testing.expectEqualStrings("0001-01-01 00:00:00 BC", sel.rows[0][7]);
}

test "should correctly process casting null to timestamp" {
    var client = try setupTestClient(testing.allocator, testing.io);
    defer client.deinit();

    var res = try client.execute("SELECT null::timestamp");
    defer res.deinit();

    const sel = res.payload.select;

    try testing.expectEqualStrings("[NULL]", sel.rows[0][0]);
}

// timestamptz

test "should return timestamptz value as string" {
    var client = try setupTestClient(testing.allocator, testing.io);
    defer client.deinit();

    var res = try client.execute(
        \\ SELECT '2026-08-07 14:30:15Z'::timestamptz
    );
    defer res.deinit();

    try testing.expectEqual(.select, std.meta.activeTag(res.payload));
    const sel = res.payload.select;

    try testing.expectEqualStrings("2026-08-07 14:30:15+00", sel.rows[0][0]);
}

test "should handle complex timestamptz edge cases and timezone offsets" {
    var client = try setupTestClient(testing.allocator, testing.io);
    defer client.deinit();

    {
        var res = try client.execute(
            \\ SELECT
            \\    '1970-01-01 00:00:00Z'::timestamptz,
            \\    '1969-12-31 23:59:59.999999Z'::timestamptz,
            \\    '2024-02-29 12:00:00.123456Z'::timestamptz,
            \\    '0045-03-15 00:00:00+00 BC'::timestamptz,
            \\    '0001-01-01 00:00:00+00 BC'::timestamptz
        );
        defer res.deinit();

        const sel = res.payload.select;
        try testing.expectEqualStrings("1970-01-01 00:00:00+00", sel.rows[0][0]);
        try testing.expectEqualStrings("1969-12-31 23:59:59.999999+00", sel.rows[0][1]);
        try testing.expectEqualStrings("2024-02-29 12:00:00.123456+00", sel.rows[0][2]);
        try testing.expectEqualStrings("0045-03-15 00:00:00+00 BC", sel.rows[0][3]);
        try testing.expectEqualStrings("0001-01-01 00:00:00+00 BC", sel.rows[0][4]);
    }

    client.session_context.timezone_offset_min = 180;
    {
        var res = try client.execute(
            \\ SELECT
            \\    '2026-08-07 12:00:00+00'::timestamptz,
            \\    '0045-03-15 00:00:00+00 BC'::timestamptz
        );
        defer res.deinit();

        const sel = res.payload.select;
        try testing.expectEqualStrings("2026-08-07 15:00:00+03", sel.rows[0][0]);
        try testing.expectEqualStrings("0045-03-15 03:00:00+03 BC", sel.rows[0][1]);
    }

    client.session_context.timezone_offset_min = -300;
    {
        var res = try client.execute("SELECT '2026-08-07 02:00:00+00'::timestamptz");
        defer res.deinit();

        const sel = res.payload.select;
        try testing.expectEqualStrings("2026-08-06 21:00:00-05", sel.rows[0][0]);
    }

    client.session_context.timezone_offset_min = 330;
    {
        var res = try client.execute("SELECT '2026-08-07 00:00:00.500000+00'::timestamptz");
        defer res.deinit();

        const sel = res.payload.select;
        try testing.expectEqualStrings("2026-08-07 05:30:00.500000+05:30", sel.rows[0][0]);
    }
}

test "should correctly process casting null to timestamptz" {
    var client = try setupTestClient(testing.allocator, testing.io);
    defer client.deinit();

    var res = try client.execute("SELECT null::timestamptz");
    defer res.deinit();

    const sel = res.payload.select;

    try testing.expectEqualStrings("[NULL]", sel.rows[0][0]);
}

// date

test "should return date value as string" {
    var client = try setupTestClient(testing.allocator, testing.io);
    defer client.deinit();

    var res = try client.execute(
        \\ SELECT '2026-08-07'::date
    );
    defer res.deinit();

    try testing.expectEqual(.select, std.meta.activeTag(res.payload));
    const sel = res.payload.select;

    try testing.expectEqualStrings("2026-08-07", sel.rows[0][0]);
}

test "should handle complex date cases including BC and leap years" {
    var client = try setupTestClient(testing.allocator, testing.io);
    defer client.deinit();

    var res = try client.execute(
        \\ SELECT
        \\    '2000-01-01'::date,
        \\    '1970-01-01'::date,
        \\    '1969-12-31'::date,
        \\    '1950-05-15'::date,
        \\    '2024-02-29'::date,
        \\    '0001-01-01'::date,
        \\    '0045-03-15 BC'::date,
        \\    '0001-01-01 BC'::date
    );
    defer res.deinit();

    try testing.expectEqual(.select, std.meta.activeTag(res.payload));
    const sel = res.payload.select;

    try testing.expectEqualStrings("2000-01-01", sel.rows[0][0]);
    try testing.expectEqualStrings("1970-01-01", sel.rows[0][1]);
    try testing.expectEqualStrings("1969-12-31", sel.rows[0][2]);
    try testing.expectEqualStrings("1950-05-15", sel.rows[0][3]);
    try testing.expectEqualStrings("2024-02-29", sel.rows[0][4]);
    try testing.expectEqualStrings("0001-01-01", sel.rows[0][5]);
    try testing.expectEqualStrings("0045-03-15 BC", sel.rows[0][6]);
    try testing.expectEqualStrings("0001-01-01 BC", sel.rows[0][7]);
}

test "should correctly process casting null to date" {
    var client = try setupTestClient(testing.allocator, testing.io);
    defer client.deinit();

    var res = try client.execute("SELECT null::date");
    defer res.deinit();

    const sel = res.payload.select;

    try testing.expectEqualStrings("[NULL]", sel.rows[0][0]);
}

// time

test "should return time value as string" {
    var client = try setupTestClient(testing.allocator, testing.io);
    defer client.deinit();

    var res = try client.execute(
        \\ SELECT '14:30:15'::time
    );
    defer res.deinit();

    try testing.expectEqual(.select, std.meta.activeTag(res.payload));
    const sel = res.payload.select;

    try testing.expectEqualStrings("14:30:15", sel.rows[0][0]);
}

test "should handle complex time cases including precision and 24:00:00" {
    var client = try setupTestClient(testing.allocator, testing.io);
    defer client.deinit();

    var res = try client.execute(
        \\ SELECT
        \\    '00:00:00'::time,
        \\    '00:00:00.000001'::time,
        \\    '12:34:56.789123'::time,
        \\    '23:59:59.999999'::time,
        \\    '24:00:00'::time
    );
    defer res.deinit();

    try testing.expectEqual(.select, std.meta.activeTag(res.payload));
    const sel = res.payload.select;

    try testing.expectEqualStrings("00:00:00", sel.rows[0][0]);
    try testing.expectEqualStrings("00:00:00.000001", sel.rows[0][1]);
    try testing.expectEqualStrings("12:34:56.789123", sel.rows[0][2]);
    try testing.expectEqualStrings("23:59:59.999999", sel.rows[0][3]);
    try testing.expectEqualStrings("24:00:00", sel.rows[0][4]);
}

test "should correctly process casting null to time" {
    var client = try setupTestClient(testing.allocator, testing.io);
    defer client.deinit();

    var res = try client.execute("SELECT null::time");
    defer res.deinit();

    const sel = res.payload.select;

    try testing.expectEqualStrings("[NULL]", sel.rows[0][0]);
}

// interval

test "should return interval value as string" {
    var client = try setupTestClient(testing.allocator, testing.io);
    defer client.deinit();

    var res = try client.execute(
        \\ SELECT '01:02:03'::interval
    );
    defer res.deinit();

    try testing.expectEqual(.select, std.meta.activeTag(res.payload));
    const sel = res.payload.select;

    try testing.expectEqualStrings("01:02:03", sel.rows[0][0]);
}

test "should handle complex interval cases including negatives, mixed signs and sub-second precision" {
    var client = try setupTestClient(testing.allocator, testing.io);
    defer client.deinit();

    var res = try client.execute(
        \\ SELECT
        \\    '00:00:00'::interval,
        \\    '10 seconds'::interval,
        \\    '1 day'::interval,
        \\    '1 month 1 day 01:00:00'::interval,
        \\    '1 year 2 months 3 days 04:05:06.789123'::interval,
        \\    '2 years 5 days'::interval,
        \\    '-1 day'::interval,
        \\    '-1 month'::interval,
        \\    '-01:30:00'::interval,
        \\    '-2 days -05:15:00'::interval,
        \\    '-1 month -3 days -04:05:06.123456'::interval,
        \\    '1 month -5 days -02:00:00'::interval,
        \\    '-00:00:00.500000'::interval,
        \\    '1000 hours'::interval
    );
    defer res.deinit();

    try testing.expectEqual(.select, std.meta.activeTag(res.payload));
    const sel = res.payload.select;

    try testing.expectEqualStrings("00:00:00", sel.rows[0][0]);
    try testing.expectEqualStrings("00:00:10", sel.rows[0][1]);
    try testing.expectEqualStrings("1 day", sel.rows[0][2]);
    try testing.expectEqualStrings("1 mon 1 day 01:00:00", sel.rows[0][3]);
    try testing.expectEqualStrings("14 mons 3 days 04:05:06.789123", sel.rows[0][4]);
    try testing.expectEqualStrings("24 mons 5 days", sel.rows[0][5]);
    try testing.expectEqualStrings("-1 day", sel.rows[0][6]);
    try testing.expectEqualStrings("-1 mon", sel.rows[0][7]);
    try testing.expectEqualStrings("-01:30:00", sel.rows[0][8]);
    try testing.expectEqualStrings("-2 days -05:15:00", sel.rows[0][9]);
    try testing.expectEqualStrings("-1 mon -3 days -04:05:06.123456", sel.rows[0][10]);
    try testing.expectEqualStrings("1 mon -5 days -02:00:00", sel.rows[0][11]);
    try testing.expectEqualStrings("-00:00:00.500000", sel.rows[0][12]);
    try testing.expectEqualStrings("1000:00:00", sel.rows[0][13]);
}

test "should correctly process casting null to interval" {
    var client = try setupTestClient(testing.allocator, testing.io);
    defer client.deinit();

    var res = try client.execute("SELECT null::interval");
    defer res.deinit();

    const sel = res.payload.select;

    try testing.expectEqualStrings("[NULL]", sel.rows[0][0]);
}
