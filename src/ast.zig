const std = @import("std");
const Token = @import("lex.zig");

pub const AST = union(enum) {
    select: SelectAST,
    insert: InsertAST,
    create_table: CreateTableAST,

    pub fn print(self: AST) void {
        switch (self) {
            .select => |select| select.print(),
            .insert => |insert| insert.print(),
            .create_table => |create_table| create_table.print(),
        }
    }
};

pub const ExpressionAST = union(enum) {
    literal: Token, // 字面逻辑
    binary_operation: BinaryOperationAST, // 计算逻辑

    pub fn deinit(self: ExpressionAST) void {
        switch (self) {
            .binary_operation => |m| {
                var bin = m;
                bin.deinit();
            },
            else => {},
        }
    }
};

pub const BinaryOperationAST = struct {
    operator: Token,
    allocator: std.mem.Allocator,
    left: *ExpressionAST,
    right: *ExpressionAST,

    pub fn init(
        allocator: std.mem.Allocator,
        operator: Token,
    ) !BinaryOperationAST {
        return .{
            .operator = operator,
            .allocator = allocator,
            .left = try allocator.create(ExpressionAST),
            .right = try allocator.create(ExpressionAST),
        };
    }

    pub fn deinit(self: BinaryOperationAST) void {
        self.left.deinit();
        self.allocator.destroy(self.left);
        self.right.deinit();
        self.allocator.destroy(self.right);
    }
};

pub const SelectAST = struct {
    columns: []ExpressionAST, // 选择字段
    from: Token, // 数据表
    where: ?ExpressionAST, // where条件 ?表示可以为null
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) SelectAST {
        return .{
            .columns = undefined,
            .from = undefined,
            .where = null,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SelectAST) void {
        for (self.columns) |m| {
            var col = m;
            col.deinit();
        }
        self.allocator.free(self.columns);
        if (self.where) |m| {
            var where = m;
            where.deinit();
        }
    }
};

pub const CreateTableColumnAST = struct {
    name: Token, // 字段名
    kind: Token, // 字段类型，目前只支持string和int
    pub fn init() CreateTableColumnAST {
        return .{
            .name = undefined,
            .kind = undefined,
        };
    }
};
pub const CreateTableAST = struct {
    table: Token, // 数据表
    columns: []CreateTableColumnAST, // 表字段定义
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) CreateTableAST {
        return .{
            .table = undefined,
            .columns = undefined,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *CreateTableAST) void {
        self.allocator.free(self.columns);
    }
};

pub const InsertAST = struct {
    table: Token, // 数据表
    values: []ExpressionAST, // 插入赋值
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) InsertAST {
        return .{
            .table = undefined,
            .values = undefined,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *InsertAST) void {
        for (self.values) |m| {
            var value = m;
            value.deinit();
        }
        self.allocator.free(self.values);
    }
};

pub fn isExpectTokenKind(tokens: []Token, index: usize, kind: Token.Kind) bool {
    if (index >= tokens.len) {
        return false;
    }
    return tokens[index].kind == kind;
}
