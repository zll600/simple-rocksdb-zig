const std = @import("std");
const parser = @import("parser.zig");
const storage = @import("storage.zig");
const StorageError = @import("storage.zig").StorageError;

pub const QueryResponse = struct {
    rows: []const []const u8,
    fields: []const []const u8,
    allocator: std.mem.Allocator,
};

pub const ExecuteError = error{
    TableAlreadyExists,
    TableNotFound,
};

pub const Executor = struct {
    allocator: std.mem.Allocator,
    storage: storage.Storage,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, var_storage: storage.Storage) Self {
        return Self{ .allocator = allocator, .storage = var_storage };
    }

    fn executeExpression(self: Self, expr: parser.ExpressionAST, row: storage.Row) !storage.Value {
        return switch (expr) {
            .literal => |literal| switch (literal.getKind()) {
                .string => return storage.Value{ .string_value = literal.string() },
                .integer => return storage.Value{ .integer_value = try std.fmt.parseInt(i64, literal.string(), 10) },
                .identifier => return row.get(literal.string()),
                else => unreachable,
            },
            .binary_operation => |bin_op| {
                const left = try self.executeExpression(bin_op.left.*, row);
                const right = try self.executeExpression(bin_op.right.*, row);

                if (bin_op.operator.kind == .equal_operator) {
                    // Cast dissimilar types to serde
                    if (@intFromEnum(left) != @intFromEnum(right)) {
                        var leftBuf = std.ArrayList(u8).init(self.allocator);
                        left.asString(&leftBuf) catch unreachable;
                        left = storage.Value{ .string_value = leftBuf.items };

                        var rightBuf = std.ArrayList(u8).init(self.allocator);
                        right.asString(&rightBuf) catch unreachable;
                        right = storage.Value{ .string_value = rightBuf.items };
                    }

                    return storage.Value{
                        .bool_value = switch (left) {
                            .null_value => true,
                            .bool_value => |v| v == right.asBool(),
                            .string_value => blk: {
                                var leftBuf = std.ArrayList(u8).init(self.allocator);
                                left.asString(&leftBuf) catch unreachable;

                                var rightBuf = std.ArrayList(u8).init(self.allocator);
                                right.asString(&rightBuf) catch unreachable;

                                break :blk std.mem.eql(u8, leftBuf.items, rightBuf.items);
                            },
                            .integer_value => left.asInteger() == right.asInteger(),
                        },
                    };
                }

                if (bin_op.operator.kind == .concat_operator) {
                    var copy = std.ArrayList(u8).init(self.allocator);
                    left.asString(&copy) catch unreachable;
                    right.asString(&copy) catch unreachable;
                    return storage.Value{ .string_value = copy.items };
                }

                return switch (bin_op.operator.kind) {
                    .lt_operator => if (left.asInteger() < right.asInteger()) storage.Value.TRUE else storage.Value.FALSE,
                    .plus_operator => storage.Value{ .integer_value = left.asInteger() + right.asInteger() },
                    else => storage.Value.NULL,
                };
            },
        };
    }

    fn executeSelect(self: Self, s: parser.SelectAST) !QueryResponse {
        switch (self.storage.getTable(s.from.string())) {
            .err => |err| return .{ .err = err },
            else => _ = 1,
        }

        // Now validate and store requested fields
        var requestedFields = std.ArrayList([]const u8).init(self.allocator);
        for (s.columns) |requestedColumn| {
            const fieldName = switch (requestedColumn) {
                .literal => |lit| switch (lit.kind) {
                    .identifier => lit.string(),
                    // TODO: give reasonable names
                    else => "unknown",
                },
                // TODO: give reasonable names
                else => "unknown",
            };
            requestedFields.append(fieldName) catch return .{
                .err = "Could not allocate for requested field.",
            };
        }
        var rows = std.ArrayList([][]const u8).init(self.allocator);
        var response = QueryResponse{
            .fields = requestedFields.items,
            .rows = undefined,
            .empty = false,
        };

        var iter = switch (self.storage.getRowIter(s.from.string())) {
            .err => |err| return .{ .err = err },
            .val => |it| it,
        };
        defer iter.close();

        while (iter.next()) |row| {
            var add = false;
            if (s.where) |where| {
                if (self.executeExpression(where, row).asBool()) {
                    add = true;
                }
            } else {
                add = true;
            }

            if (add) {
                var requested = std.ArrayList([]const u8).init(self.allocator);
                for (s.columns) |exp| {
                    var val = self.executeExpression(exp, row);
                    var valBuf = std.ArrayList(u8).init(self.allocator);
                    val.asString(&valBuf) catch unreachable;
                    requested.append(valBuf.items) catch return .{
                        .err = "Could not allocate for requested cell",
                    };
                }
                rows.append(requested.items) catch return .{
                    .err = "Could not allocate for row",
                };
            }
        }

        response.rows = rows.items;
        return .{ .val = response };
    }

    fn executeInsert(self: Executor, i: parser.InsertAST) !QueryResponse {
        const emptyRow = storage.Row.init(self.allocator, undefined);
        var row = storage.Row.init(self.allocator, undefined);
        for (i.values) |v| {
            const exp = self.executeExpression(v, emptyRow);
            row.append(exp) catch return .{ .err = "Could not allocate for cell" };
        }

        if (self.storage.writeRow(i.table.string(), row)) |err| {
            return .{ .err = err };
        }

        return .{
            .val = .{ .fields = undefined, .rows = undefined, .empty = true },
        };
    }

    fn executeCreateTable(self: Self, c: parser.CreateTableAST) !QueryResponse {
        var columns = std.ArrayList([]const u8).init(self.allocator);
        var types = std.ArrayList([]const u8).init(self.allocator);

        for (c.columns) |column| {
            columns.append(column.name.string()) catch return .{
                .err = "Could not allocate for column name",
            };
            types.append(column.kind.string()) catch return .{
                .err = "Could not allocate for column kind",
            };
        }

        const table = storage.Table{
            .name = c.table.string(),
            .columns = columns.items,
            .types = types.items,
        };

        if (self.storage.writeTable(table)) |err| {
            return .{ .err = err };
        }
        return .{
            .val = .{ .fields = undefined, .rows = undefined, .empty = true },
        };
    }

    pub fn execute(self: Self, ast: parser.AST) !QueryResponse {
        return switch (ast) {
            .select => |select| switch (self.executeSelect(select)) {
                .val => |val| .{ .val = val },
                .err => |err| .{ .err = err },
            },
            .insert => |insert| switch (self.executeInsert(insert)) {
                .val => |val| .{ .val = val },
                .err => |err| .{ .err = err },
            },
            .create_table => |createTable| switch (self.executeCreateTable(createTable)) {
                .val => |val| .{ .val = val },
                .err => |err| .{ .err = err },
            },
        };
    }
};
