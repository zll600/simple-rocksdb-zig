const std = @import("std");
const kv = @import("kv.zig");
const KV = @import("kv.zig").KV;

pub const Value = union(enum) {
    bool_value: bool,
    null_value: bool,
    string_value: []const u8,
    integer_value: i64,

    pub const TRUE = Value{ .bool_value = true };
    pub const FALSE = Value{ .bool_value = false };
    pub const NULL = Value{ .null_value = true };

    pub fn fromIntegerString(iBytes: []const u8) Value {
        const i = std.fmt.parseInt(i64, iBytes, 10) catch return Value{
            .integer_value = 0,
        };
        return Value{ .integer_value = i };
    }

    pub fn asBool(self: Value) bool {
        return switch (self) {
            .null_value => false,
            .bool_value => |value| value,
            .string_value => |value| value.len > 0,
            .integer_value => |value| value != 0,
        };
    }

    pub fn asString(self: Value, buf: *std.ArrayList(u8)) !void {
        try switch (self) {
            .null_value => _ = 1, // Do nothing
            .bool_value => |value| buf.appendSlice(if (value) "true" else "false"),
            .string_value => |value| buf.appendSlice(value),
            .integer_value => |value| buf.writer().print("{d}", .{value}),
        };
    }

    pub fn asInteger(self: Value) i64 {
        return switch (self) {
            .null_value => 0,
            .bool_value => |value| if (value) 1 else 0,
            .string_value => |value| fromIntegerString(value).integer_value,
            .integer_value => |value| value,
        };
    }

    pub fn serialize(self: Value, buf: *std.ArrayList(u8)) !void {
        switch (self) {
            .null_value => return buf.append('0'),
            .bool_value => |v| {
                try buf.append('1');
                return buf.append(if (v) '1' else '0');
            },
            .string_value => |v| {
                try buf.append('2');
                return buf.appendSlice(v);
            },
            .integer_value => |v| {
                try buf.append('3');
                var b2: [8]u8 = undefined;
                serializeInteger(i64, v, &b2);
                return buf.appendSlice(b2[0..]);
            },
        }
    }

    pub fn deserialize(buf: []const u8) Value {
        if (buf.len == 0) {
            unreachable;
        }
        switch (buf[0]) {
            '0' => return Value{ .null_value = true },
            '1' => {
                if (buf[1] == '1') {
                    return Value{ .bool_value = true };
                } else {
                    return Value{ .bool_value = false };
                }
            },
            '2' => return .{ .string_value = buf[1..] },
            '3' => {
                return Value{ .integer_value = deserializeInteger(i64, buf[1..]) };
            },
            else => unreachable,
        }
    }
};

fn serializeInteger(comptime T: type, i: T, buf: *[@sizeOf(T)]u8) void {
    std.mem.writeInt(T, buf, i, .big);
}
fn deserializeInteger(comptime T: type, buf: []const u8) T {
    return std.mem.readInt(T, buf[0..@sizeOf(T)], .big);
}

// [length: 4bytes][bytes]
pub fn serializeBytes(allocator: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    var h: [4]u8 = undefined;
    serializeInteger(u32, @intCast(bytes.len), &h);
    const parts = [_][]const u8{ &h, bytes };
    return std.mem.concat(allocator, u8, &parts);
}

pub fn deserializeBytes(bytes: []const u8, buf: *[]const u8) usize {
    const length = deserializeInteger(u32, bytes);
    const offset = length + 4;
    buf.* = bytes[4..offset];
    return offset;
}

pub const StorageError = enum {
    TableNotFound,
    WriteTableKeyError,
};

pub const Storage = struct {
    db: KV,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, db: KV) Storage {
        return Storage{
            .db = db,
            .allocator = allocator,
        };
    }

    pub fn writeTable(self: Self, table: Table) ?StorageError {
        // Table name prefix
        var key = std.ArrayList(u8).init(self.allocator);
        switch (key.writer().print("tbl_{s}_", .{table.name})){
            .err => {
                std.log.info("Could not allocate key for table", .{});
            }
        }

        var value = std.ArrayList(u8).init(self.allocator);
        for (table.columns) |column, i| {
            serializeBytes(&value, column) catch return "Could not allocate for column";
            serializeBytes(&value, table.types[i]) catch return "Could not allocate for column type";
        }

        return self.db.set(key.items, value.items);
    }

};

pub const Table = struct {
    name: []const u8,
    columns: []const []const u8,
    types: []const []const u8,

    const Self = @This();

    pub fn init(
        name: []const u8,
        columns: []const []const u8,
        types: []const []const u8,
    ) Self {
        return Self{
            .name = name,
            .columns = columns,
            .types = types,
        };
    }

};

pub const Row = struct {
    const Self = @This();
    allocator: std.mem.Allocator,
    cells: std.ArrayList(Value),
    table: Table,

    pub fn init(allocator: std.mem.Allocator, table: Table) Self {
        return Self{
            .allocator = allocator,
            .cells = std.ArrayList(Value).init(allocator),
            .table = table,
        };
    }

    pub fn deinit(self: Self) void {
        for (self.cells.items) |c| {
            c.deinit(self.allocator);
        }
        self.cells.deinit();
    }

    pub fn append(self: *Self, cell: Value) !void {
        return self.cells.append(try cell.clone(self.allocator));
    }

    // 取出对应field的值
    pub fn get(self: Self, field: []const u8, val: *Value) bool {
        if (field.len == 0) {
            return false;
        }
        for (self.table.columns, 0..) |f, i| {
            if (std.mem.eql(u8, f, field)) {
                val.* = self.cells.items[i];
                return true;
            }
        }
        return false;
    }

    pub fn reset(self: *Self) void {
        for (self.cells.items) |c| {
            c.deinit(self.allocator);
        }
        self.cells.clearRetainingCapacity();
    }
};

const RowIter = struct {
    const Self = @This();
    iter: kv.Iter,
    row_prefix: []const u8,
    allocator: std.mem.Allocator,
    table: Table,

    fn init(
        allocator: std.mem.Allocator,
        db: KV,
        row_prefix: []const u8,
        table: Table,
    ) !Self {
        const rp = try allocator.dupe(u8, row_prefix);
        return .{
            .iter = try db.getIter(rp),
            .row_prefix = rp,
            .allocator = allocator,
            .table = table,
        };
    }

    pub fn deinit(self: Self) void {
        self.allocator.free(self.row_prefix);
        self.iter.deinit();
    }

    pub fn next(self: *Self) !?Row {
        var b: []const u8 = undefined;
        if (self.iter.next()) |m| {
            // 对rocksdb执行前缀搜索
            b = m.value;
        } else {
            return null;
        }
        var row = Row.init(self.allocator, self.table);
        var offset: usize = 0;
        while (offset < b.len) {
            var buf: []const u8 = undefined;
            offset += deserializeBytes(b[offset..], &buf);
            try row.append(Value.deserialize(buf));
        }
        return row;
    }
};
