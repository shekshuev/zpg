const std = @import("std");
const testing = std.testing;

pub const Mode = enum {
    gui,
    tui,
};

pub const Theme = enum {
    light,
    dark,
    system,
};

pub const ConfigError = error{
    MissingArgument,
    InvalidArgument,
};

const Value = enum {
    mode,
    theme,
    db_host,
    db_port,
    db_name,
    db_user,
    db_pass,
};

const env_map = std.StaticStringMap(Value).initComptime(.{
    .{ "ZPG_MODE", .mode },
    .{ "ZPG_THEME", .theme },
    .{ "ZPG_DB_HOST", .db_host },
    .{ "ZPG_DB_PORT", .db_port },
    .{ "ZPG_DB_NAME", .db_name },
    .{ "ZPG_DB_USER", .db_user },
    .{ "ZPG_DB_PASS", .db_pass },
});

const flag_map = std.StaticStringMap(Value).initComptime(.{
    .{ "--mode", .mode },
    .{ "--theme", .theme },
    .{ "--host", .db_host },
    .{ "--port", .db_port },
    .{ "--name", .db_name },
    .{ "--user", .db_user },
    .{ "--pass", .db_pass },
});

const max_url_length = 253;
const max_db_name_length = 63;
const max_db_user_length = 63;

pub const Config = struct {
    pub const default_mode: Mode = .gui;
    pub const default_theme: Theme = .system;
    pub const default_db_host: []const u8 = "localhost";
    pub const default_db_port: u16 = 5432;
    pub const default_db_name: []const u8 = "postgres";
    pub const default_db_user: []const u8 = "postgres";
    pub const default_db_pass: []const u8 = "postgres";

    mode: Mode,
    theme: Theme,
    db_host: []const u8,
    db_port: u16,
    db_name: []const u8,
    db_user: []const u8,
    db_pass: []const u8,

    pub fn load(args: std.process.Args, environ: *const std.process.Environ.Map) !Config {
        var config = Config{
            .mode = default_mode,
            .theme = default_theme,
            .db_host = default_db_host,
            .db_port = default_db_port,
            .db_name = default_db_name,
            .db_user = default_db_user,
            .db_pass = default_db_pass,
        };

        for (env_map.keys(), env_map.values()) |key, map_value| {
            if (environ.get(key)) |value| {
                switch (map_value) {
                    .mode => {
                        config.mode = std.meta.stringToEnum(Mode, value) orelse default_mode;
                    },
                    .theme => {
                        config.theme = std.meta.stringToEnum(Theme, value) orelse default_theme;
                    },
                    .db_host => {
                        if (value.len > 0 and value.len <= max_url_length) {
                            config.db_host = value;
                        }
                    },
                    .db_port => {
                        config.db_port = std.fmt.parseInt(u16, value, 10) catch default_db_port;
                    },
                    .db_name => {
                        if (value.len > 0 and value.len <= max_db_name_length) {
                            config.db_name = value;
                        }
                    },
                    .db_user => {
                        if (value.len > 0 and value.len <= max_db_user_length) {
                            config.db_user = value;
                        }
                    },
                    .db_pass => {
                        if (value.len > 0) {
                            config.db_pass = value;
                        }
                    },
                }
            }
        }

        var iter = args.iterate();
        _ = iter.next(); // app name

        while (iter.next()) |key| {
            if (flag_map.get(key)) |flag| {
                const value = iter.next() orelse return error.MissingArgument;

                if (flag_map.has(value)) {
                    return error.MissingArgument;
                }

                switch (flag) {
                    .mode => {
                        config.mode = std.meta.stringToEnum(Mode, value) orelse return error.InvalidArgument;
                    },
                    .theme => {
                        config.theme = std.meta.stringToEnum(Theme, value) orelse return error.InvalidArgument;
                    },
                    .db_host => {
                        if (value.len > 0 and value.len <= max_url_length) {
                            config.db_host = value;
                        } else return error.InvalidArgument;
                    },
                    .db_port => {
                        config.db_port = std.fmt.parseInt(u16, value, 10) catch return error.InvalidArgument;
                    },
                    .db_name => {
                        if (value.len > 0 and value.len <= max_db_name_length) {
                            config.db_name = value;
                        } else return error.InvalidArgument;
                    },
                    .db_user => {
                        if (value.len > 0 and value.len <= max_db_user_length) {
                            config.db_user = value;
                        } else return error.InvalidArgument;
                    },
                    .db_pass => {
                        if (value.len > 0) {
                            config.db_pass = value;
                        } else return error.InvalidArgument;
                    },
                }
            } else return error.InvalidArgument;
        }
        return config;
    }
};

test "config loads default values" {
    const dummy_args = std.process.Args{
        .vector = &[_][*:0]const u8{"zpg"},
    };
    var dummy_env = std.process.Environ.Map.init(testing.allocator);
    defer dummy_env.deinit();

    const config = try Config.load(dummy_args, &dummy_env);

    try testing.expectEqual(Config.default_mode, config.mode);
    try testing.expectEqual(Config.default_theme, config.theme);
    try testing.expectEqual(Config.default_db_host, config.db_host);
    try testing.expectEqual(Config.default_db_port, config.db_port);
    try testing.expectEqual(Config.default_db_name, config.db_name);
    try testing.expectEqual(Config.default_db_user, config.db_user);
    try testing.expectEqual(Config.default_db_pass, config.db_pass);
}

test "config load env values and overrides defaults" {
    const dummy_args = std.process.Args{
        .vector = &[_][*:0]const u8{"zig_sysmon"},
    };
    var dummy_env = std.process.Environ.Map.init(testing.allocator);
    defer dummy_env.deinit();
    try dummy_env.put("ZPG_MODE", "tui");
    try dummy_env.put("ZPG_THEME", "light");
    try dummy_env.put("ZPG_DB_HOST", "127.0.0.1");
    try dummy_env.put("ZPG_DB_PORT", "5433");
    try dummy_env.put("ZPG_DB_NAME", "some_db_name");
    try dummy_env.put("ZPG_DB_USER", "some_db_user");
    try dummy_env.put("ZPG_DB_PASS", "some_db_pass");

    const config = try Config.load(dummy_args, &dummy_env);

    try testing.expectEqual(Mode.tui, config.mode);
    try testing.expectEqual(Theme.light, config.theme);
    try testing.expectEqualStrings("127.0.0.1", config.db_host);
    try testing.expectEqual(5433, config.db_port);
    try testing.expectEqualStrings("some_db_name", config.db_name);
    try testing.expectEqualStrings("some_db_user", config.db_user);
    try testing.expectEqualStrings("some_db_pass", config.db_pass);
}

test "config load args values and overrides defaults" {
    const dummy_args = std.process.Args{
        .vector = &[_][*:0]const u8{
            "zpg",
            "--mode",
            "tui",
            "--theme",
            "light",
            "--host",
            "127.0.0.1",
            "--port",
            "5433",
            "--name",
            "some_db_name",
            "--user",
            "some_db_user",
            "--pass",
            "some_db_pass",
        },
    };
    var dummy_env = std.process.Environ.Map.init(testing.allocator);
    defer dummy_env.deinit();

    const config = try Config.load(dummy_args, &dummy_env);

    try testing.expectEqual(Mode.tui, config.mode);
    try testing.expectEqual(Theme.light, config.theme);
    try testing.expectEqualStrings("127.0.0.1", config.db_host);
    try testing.expectEqual(5433, config.db_port);
    try testing.expectEqualStrings("some_db_name", config.db_name);
    try testing.expectEqualStrings("some_db_user", config.db_user);
    try testing.expectEqualStrings("some_db_pass", config.db_pass);
}

test "config returns missing argument error if arg value is missing " {
    const dummy_args = std.process.Args{
        .vector = &[_][*:0]const u8{
            "zpg",
            "--mode",
            "--theme",
            "light",
        },
    };
    var dummy_env = std.process.Environ.Map.init(testing.allocator);
    defer dummy_env.deinit();

    const config = Config.load(dummy_args, &dummy_env);

    try testing.expectError(error.MissingArgument, config);
}

test "config returns invalid argument error if arg value mismatch expected type" {
    const dummy_args = std.process.Args{
        .vector = &[_][*:0]const u8{
            "zig_sysmon",
            "--port",
            "eight_zero_zero_zero",
            "--host",
            "127.0.0.1",
        },
    };
    var dummy_env = std.process.Environ.Map.init(testing.allocator);
    defer dummy_env.deinit();

    const config = Config.load(dummy_args, &dummy_env);

    try testing.expectError(error.InvalidArgument, config);
}

test "config load args and env values and args overrides all" {
    const dummy_args = std.process.Args{
        .vector = &[_][*:0]const u8{
            "zpg",
            "--mode",
            "tui",
            "--theme",
            "light",
            "--host",
            "127.0.0.1",
            "--port",
            "5433",
            "--name",
            "some_db_name",
            "--user",
            "some_db_user",
            "--pass",
            "some_db_pass",
        },
    };

    var dummy_env = std.process.Environ.Map.init(testing.allocator);
    defer dummy_env.deinit();
    try dummy_env.put("ZPG_MODE", "gui");
    try dummy_env.put("ZPG_THEME", "dark");
    try dummy_env.put("ZPG_DB_HOST", "127.0.0.2");
    try dummy_env.put("ZPG_DB_PORT", "5434");
    try dummy_env.put("ZPG_DB_NAME", "some_db_name_2");
    try dummy_env.put("ZPG_DB_USER", "some_db_user_2");
    try dummy_env.put("ZPG_DB_PASS", "some_db_pass_2");

    const config = try Config.load(dummy_args, &dummy_env);

    try testing.expectEqual(Mode.tui, config.mode);
    try testing.expectEqual(Theme.light, config.theme);
    try testing.expectEqualStrings("127.0.0.1", config.db_host);
    try testing.expectEqual(5433, config.db_port);
    try testing.expectEqualStrings("some_db_name", config.db_name);
    try testing.expectEqualStrings("some_db_user", config.db_user);
    try testing.expectEqualStrings("some_db_pass", config.db_pass);
}

test "config load args and env values and use defaults if nothing passed" {
    const dummy_args = std.process.Args{
        .vector = &[_][*:0]const u8{
            "zpg",
            "--mode",
            "tui",
            "--port",
            "5433",
        },
    };

    var dummy_env = std.process.Environ.Map.init(testing.allocator);
    defer dummy_env.deinit();
    try dummy_env.put("ZPG_DB_HOST", "127.0.0.2");
    try dummy_env.put("ZPG_DB_PORT", "5434");
    try dummy_env.put("ZPG_DB_NAME", "some_db_name_2");
    const config = try Config.load(dummy_args, &dummy_env);

    try testing.expectEqual(Mode.tui, config.mode);
    try testing.expectEqual(Config.default_theme, config.theme);
    try testing.expectEqualStrings("127.0.0.2", config.db_host);
    try testing.expectEqual(5433, config.db_port);
    try testing.expectEqualStrings("some_db_name_2", config.db_name);
    try testing.expectEqualStrings(Config.default_db_user, config.db_user);
    try testing.expectEqualStrings(Config.default_db_pass, config.db_pass);
}
