const std = @import("std");
const rocksdb = @import("rocksdb");

pub const Table = struct {
    name: []const u8,
    columns: []const []const u8,
    types: []const []const u8,
    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        name: []const u8,
        columns: []const []const u8,
        types: []const []const u8,
    ) Table {
        return Table{
            .name = name,
            .columns = columns,
            .types = types,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: Table) void {
        for (self.columns, 0..) |_, i| {
            self.allocator.free(self.columns[i]);
        }
        self.allocator.free(self.columns);
        for (self.types, 0..) |_, i| {
            self.allocator.free(self.types[i]);
        }
        self.allocator.free(self.types);
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
    iter: rocksdb.Iter,
    row_prefix: []const u8,
    allocator: std.mem.Allocator,
    table: Table,

    fn init(
        allocator: std.mem.Allocator,
        db: Rocksdb,
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
            offset += value.deserializeBytes(b[offset..], &buf);
            try row.append(Value.deserialize(buf));
        }
        return row;
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
