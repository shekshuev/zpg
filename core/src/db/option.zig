pub const ConnectOptions = struct {
    host: []const u8 = "localhost",
    port: u16 = 5432,
    user: []const u8 = "postgres",
    pass: []const u8 = "postgres",
    database: []const u8 = "postgres",
};
