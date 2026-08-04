const std = @import("std");

pub const SelectData = struct {
    columns: []const []const u8,
    rows: []const []const []const u8,
    execution_time_ms: u64,
};

pub const CommandData = struct {
    status: []const u8,
    rows_affected: u64,
    execution_time_ms: u64,
};

pub const ErrorData = struct {
    message: []const u8,
    code: ?[]const u8,
    detail: ?[]const u8,
    hint: ?[]const u8,
    position: ?u32,
    execution_time_ms: u64,
};

pub const Payload = union(enum) {
    select: SelectData,
    command: CommandData,
    err: ErrorData,
};

pub const QueryResult = struct {
    arena: std.heap.ArenaAllocator,
    payload: Payload,

    pub fn deinit(self: *QueryResult) void {
        self.arena.deinit();
    }
};
