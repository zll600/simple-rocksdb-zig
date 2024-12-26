const std = @import("std");
const rdb = @cImport(@cInclude("rocksdb/c.h"));

pub const KVError = error{
    OpenError,
    WriteError,
    ReadError,
};

pub const KV = struct {
    allocator: std.mem.Allocator,
    dir: []const u8,
    db: ?*rdb.rocksdb_t,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, dir: []const u8) !Self {
        const options: ?*rdb.rocksdb_options_t = rdb.rocksdb_options_create();
        rdb.rocksdb_options_set_create_if_missing(options, 1);

        var err: ?[*:0]u8 = null;
        const db = rdb.rocksdb_open(options, dir.ptr, &err);

        const kv = Self{
            .db = db.?,
            .allocator = allocator,
            .dir = dir,
        };

        if (err) |errStr| {
            std.log.err("Failed to open RocksDB: {s}.\n", .{errStr});
            return KVError.OpenError;
        }
        return kv;
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
            return KVError.WriteError;
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
            return KVError.ReadError;
        }
        for (0..value_length) |i| {
            try buf.append(v[i]);
        }
    }

    pub fn getIter(self: Self, prefix: []const u8) !Iter {
        return Iter.init(self.db, prefix);
    }

    pub fn iter(self: Self, prefix: []const u8) union(enum) { val: Iter, err: []u8 } {
        const readOptions = rdb.rocksdb_readoptions_create();
        var it = Iter{
            .iter = undefined,
            .first = true,
            .prefix = prefix,
        };
        it.iter = rdb.rocksdb_create_iterator(self.db, readOptions).?;

        var err: ?[*:0]u8 = null;
        rdb.rocksdb_iter_get_error(it.iter, &err);
        if (err) |errStr| {
            return .{ .err = std.mem.span(errStr) };
        }

        if (prefix.len > 0) {
            rdb.rocksdb_iter_seek(
                it.iter,
                prefix.ptr,
                prefix.len,
            );
        } else {
            rdb.rocksdb_iter_seek_to_first(it.iter);
        }

        return .{ .val = it };
    }
};

pub const IterEntry = struct {
    key: []const u8,
    value: []const u8,
};

pub const Iter = struct {
    iter: *rdb.rocksdb_iterator_t,
    first: bool,
    prefix: []const u8,

    pub fn next(self: *Iter) ?IterEntry {
        if (!self.first) {
            rdb.rocksdb_iter_next(self.iter);
        }

        self.first = false;
        if (rdb.rocksdb_iter_valid(self.iter) != 1) {
            return null;
        }

        var keySize: usize = 0;
        var key = rdb.rocksdb_iter_key(self.iter, &keySize);

        // Make sure key is still within the prefix
        if (self.prefix.len > 0) {
            if (self.prefix.len > keySize or
                !std.mem.eql(u8, key[0..self.prefix.len], self.prefix))
            {
                return null;
            }
        }

        var valueSize: usize = 0;
        var value = rdb.rocksdb_iter_value(self.iter, &valueSize);

        return IterEntry{
            .key = key[0..keySize],
            .value = value[0..valueSize],
        };
    }

    pub fn close(self: Iter) void {
        rdb.rocksdb_iter_destroy(self.iter);
    }
};
