const std = @import("std");
const rdb = @cImport(@cInclude("rocksdb.h"));
pub const Iter = @import("iter.zig").Iter;

pub fn init(allocator: std.mem.Allocator, dir: []const u8) !Self {
    const options: ?*rdb.rocksdb_options_t = rdb.rocksdb_options_create();
    rdb.rocksdb_options_set_create_if_missing(options, 1);

    var err: ?[*:0]u8 = null;
    const db = rdb.rocksdb_open(options, dir.ptr, &err);
    const r = Self{
        .db = db.?,
        .allocator = allocator,
        .dir = dir,
    };
    if (err) |errStr| {
        std.log.err("Failed to open RocksDB: {s}.\n", .{errStr});
        return RocksdbErrors.RocksDBOpenError;
    }
    return r;
}
pub fn deinit(self: Self) void {
    rdb.rocksdb_close(self.db);
}
pub fn set(self: Self, key: []const u8, value: []const u8) !void {
    const writeOptions = rdb.rocksdb_writeoptions_create();
    var err: ?[*:0]u8 = null;
    rdb.rocksdb_put(
        self.db,
        writeOptions,
        key.ptr,
        key.len,
        value.ptr,
        value.len,
        &err,
    );
    if (err) |errStr| {
        std.log.err("Failed to write RocksDB: {s}.\n", .{errStr});
        return RocksdbErrors.RocksDBWriteError;
    }
}
pub fn get(self: Self, key: []const u8, buf: *std.ArrayList(u8)) !void {
    const readOptions = rdb.rocksdb_readoptions_create();
    var value_length: usize = 0;
    var err: ?[*:0]u8 = null;
    const v = rdb.rocksdb_get(
        self.db,
        readOptions,
        key.ptr,
        key.len,
        &value_length,
        &err,
    );
    if (v == null) {
        return;
    }
    if (err) |errStr| {
        std.log.err("Failed to read RocksDB: {s}.\n", .{errStr});
        return RocksdbErrors.RocksDBReadError;
    }
    for (0..value_length) |i| {
        try buf.append(v[i]);
    }
}
pub fn getIter(self: Self, prefix: []const u8) !Iter {
    return Iter.init(self.db, prefix);
}
