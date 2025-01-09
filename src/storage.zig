const std = @import("std");
const kv = @import("kv.zig");
const KV = @import("kv.zig").KV;

pub fn serializeInteger(comptime T: type, buf: *std.ArrayList(u8), i: T) !void {
    var data: [@sizeOf(T)]u8 = undefined;
    std.mem.writeIntBig(T, &data, i);
    try buf.appendSlice(data[0..8]);
}

pub fn deserializeInteger(comptime T: type, buf: []const u8) T {
    return std.mem.readIntBig(T, buf[0..@sizeOf(T)]);
}

pub fn serializeBytes(buf: *std.ArrayList(u8), bytes: []const u8) !void {
    try serializeInteger(u64, buf, bytes.len);
    try buf.appendSlice(bytes);
}

pub fn deserializeBytes(bytes: []const u8) struct {
    offset: u64,
    bytes: []const u8,
} {
    const length = deserializeInteger(u64, bytes);
    const offset = length + 8;
    return .{ .offset = offset, .bytes = bytes[8..offset] };
}

pub const Value = union(enum) {
    bool_value: bool,
    null_value: bool,
    string_value: []const u8,
    integer_value: i64,

    const Self = @This();

    pub const TRUE = Value{ .bool_value = true };
    pub const FALSE = Value{ .bool_value = false };
    pub const NULL = Value{ .null_value = true };

    pub fn asBool(self: Self) bool {
        return switch (self) {
            .null_value => false,
            .bool_value => |value| value,
            .string_value => |value| value.len > 0,
            .integer_value => |value| value != 0,
        };
    }

    pub fn asString(self: Self, buf: *std.ArrayList(u8)) !void {
        try switch (self) {
            .null_value => _ = 1, // Do nothing
            .bool_value => |value| buf.appendSlice(if (value) "true" else "false"),
            .string_value => |value| buf.appendSlice(value),
            .integer_value => |value| buf.writer().print("{d}", .{value}),
        };
    }

    pub fn asInteger(self: Self) i64 {
        return switch (self) {
            .null_value => 0,
            .bool_value => |value| if (value) 1 else 0,
            .string_value => |value| fromIntegerString(value).integer_value,
            .integer_value => |value| value,
        };
    }

    pub fn serialize(self: Self, buf: *std.ArrayList(u8)) []const u8 {
        switch (self) {
            .null_value => buf.append('0') catch return "",

            .bool_value => |value| {
                buf.append('1') catch return "";
                buf.append(if (value) '1' else '0') catch return "";
            },

            .string_value => |value| {
                buf.append('2') catch return "";
                buf.appendSlice(value) catch return "";
            },

            .integer_value => |value| {
                buf.append('3') catch return "";
                serializeInteger(i64, buf, value) catch return "";
            },
        }

        return buf.items;
    }

    pub fn deserialize(data: []const u8) Self {
        return switch (data[0]) {
            '0' => Self.NULL,
            '1' => Self{ .bool_value = data[1] == '1' },
            '2' => Self{ .string_value = data[1..] },
            '3' => Self{ .integer_value = deserializeInteger(i64, data[1..]) },
            else => unreachable,
        };
    }

    pub fn fromIntegerString(iBytes: []const u8) Self {
        const i = std.fmt.parseInt(i64, iBytes, 10) catch return Self{
            .integer_value = 0,
        };
        return Self{ .integer_value = i };
    }
};

pub const Row = struct {
    allocator: std.mem.Allocator,
    cells: std.ArrayList([]const u8),
    fields: [][]const u8,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, fields: [][]const u8) Row {
        return Row{
            .allocator = allocator,
            .cells = std.ArrayList([]const u8).init(allocator),
            .fields = fields,
        };
    }

    pub fn append(self: *Self, cell: Value) !void {
        var cellBuffer = std.ArrayList(u8).init(self.allocator);
        try self.cells.append(cell.serialize(&cellBuffer));
    }

    pub fn appendBytes(self: *Self, cell: []const u8) !void {
        try self.cells.append(cell);
    }

    pub fn get(self: Self, field: []const u8) Value {
        for (self.fields, 0..) |f, i| {
            if (std.mem.eql(u8, field, f)) {
                // Results are internal buffer views. So make a copy.
                var copy = std.ArrayList(u8).init(self.allocator);
                copy.appendSlice(self.cells.items[i]) catch return Value.NULL;
                return Value.deserialize(copy.items);
            }
        }

        return Value.NULL;
    }

    pub fn items(self: Self) [][]const u8 {
        return self.cells.items;
    }

    fn reset(self: *Self) void {
        self.cells.clearRetainingCapacity();
    }
};

pub const RowIter = struct {
    row: Row,
    iter: kv.Iter,

    const Self = @This();

    fn init(allocator: std.mem.Allocator, iter: kv.Iter, fields: [][]const u8) Self {
        return Self{
            .iter = iter,
            .row = Row.init(allocator, fields),
        };
    }

    pub fn next(self: *Self) ?Row {
        var rowBytes: []const u8 = undefined;
        if (self.iter.next()) |b| {
            rowBytes = b.value;
        } else {
            return null;
        }

        self.row.reset();
        var offset: u64 = 0;
        while (offset < rowBytes.len) {
            const d = deserializeBytes(rowBytes[offset..]);
            offset += d.offset;
            self.row.appendBytes(d.bytes) catch return null;
        }

        return self.row;
    }

    pub fn close(self: RowIter) void {
        self.iter.close();
    }
};

pub const StorageError = error{
    TableNotFound,
    WriteTableKeyError,
    FailAllocateRowKey,
    FailGenerateId,
    FailAllocateId,
    FailAllocateCell,
    FailAllocateRowPrefix,
    FailAllocateKeyForTable,
    FailAllocateTableColumn,
    FailAllocateColumnType,
};

pub const Storage = struct {
    db: KV,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, db: KV) Storage {
        return Storage{
            .db = db,
            .allocator = allocator,
        };
    }

    fn generateId() ![]u8 {
        const file = try std.fs.cwd().openFileZ("/dev/random", .{});
        defer file.close();

        var buf: [16]u8 = .{};
        _ = try file.read(&buf);
        return buf[0..];
    }

    pub fn writeRow(self: Self, table: []const u8, row: Row) ?void {
        // Table name prefix
        var key = std.ArrayList(u8).init(self.allocator);
        key.writer().print("row_{s}_", .{table}) catch return StorageError.FailAllocateRowKey;

        // Unique row id
        const id = generateId() catch return StorageError.FailGenerateId;
        key.appendSlice(id) catch return StorageError.FailGenerateId;

        var value = std.ArrayList(u8).init(self.allocator);
        for (row.cells.items) |cell| {
            serializeBytes(&value, cell) catch return StorageError.FailAllocateCell;
        }

        return self.db.set(key.items, value.items);
    }

    pub fn getRowIter(self: Self, table: []const u8) !RowIter {
        var rowPrefix = std.ArrayList(u8).init(self.allocator);
        rowPrefix.writer().print("row_{s}_", .{table}) catch return StorageError.FailAllocateRowPrefix;

        const iter = switch (self.db.iter(rowPrefix.items)) {
            .err => |err| return .{ .err = err },
            .val => |it| it,
        };

        const tableInfo = switch (self.getTable(table)) {
            .err => |err| return .{ .err = err },
            .val => |t| t,
        };

        return RowIter.init(self.allocator, iter, tableInfo.columns);
    }

    pub fn writeTable(self: Self, table: Table) ?StorageError {
        // Table name prefix
        var key = std.ArrayList(u8).init(self.allocator);
        key.writer().print("tbl_{s}_", .{table.name}) catch return StorageError.FailAllocateKeyForTable;

        var value = std.ArrayList(u8).init(self.allocator);
        for (table.columns, 0..) |column, i| {
            serializeBytes(&value, column) catch return StorageError.FailAllocateTableColumn;
            serializeBytes(&value, table.types[i]) catch return StorageError.FailAllocateColumnType;
        }

        return self.db.set(key.items, value.items);
    }

    pub fn getTable(self: Self, name: []const u8) !Table {
        var tableKey = std.ArrayList(u8).init(self.allocator);
        tableKey.writer().print("tbl_{s}_", .{name}) catch return StorageError.FailAllocateTablePrefix;

        var columns = std.ArrayList([]const u8).init(self.allocator);
        var types = std.ArrayList([]const u8).init(self.allocator);
        var table = Table{
            .name = name,
            .columns = undefined,
            .types = undefined,
        };

        // First grab table info
        var columnInfo = switch (self.db.get(tableKey.items)) {
            .err => |err| return .{ .err = err },
            .val => |val| val,
            .not_found => return StorageError.NoSuchTable,
        };

        var columnOffset: u64 = 0;
        while (columnOffset < columnInfo.len) {
            const column = deserializeBytes(columnInfo[columnOffset..]);
            columnOffset += column.offset;
            columns.append(column.bytes) catch return StorageError.FailAllocateColumnName;
            const kind = deserializeBytes(columnInfo[columnOffset..]);
            columnOffset += kind.offset;
            types.append(kind.bytes) catch return StorageError.FailAllocateColumnKind;
        }

        table.columns = columns.items;
        table.types = types.items;

        return table;
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
