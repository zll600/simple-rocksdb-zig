const std = @import("std");
const lex = @import("lex.zig");
const ast = @import("ast.zig");

const Token = lex.Token;
const Kind = lex.Kind;

pub const ExpressionAST = union(enum) {
    literal: Token,
    binary_operation: BinaryOperationAST,

    fn print(self: ExpressionAST) void {
        switch (self) {
            .literal => |literal| switch (literal.kind) {
                .string => std.debug.print("'{s}'", .{literal.string()}),
                else => std.debug.print("{s}", .{literal.string()}),
            },
            .binary_operation => self.binary_operation.print(),
        }
    }
};

pub const BinaryOperationAST = struct {
    operator: Token,
    left: *ExpressionAST,
    right: *ExpressionAST,

    fn print(self: BinaryOperationAST) void {
        self.left.print();
        std.debug.print(" {s} ", .{self.operator.string()});
        self.right.print();
    }
};

pub const SelectAST = struct {
    columns: []ExpressionAST,
    from: Token,
    where: ?ExpressionAST,

    const Self = @This();

    fn print(self: Self) void {
        std.debug.print("SELECT\n", .{});

        for (self.columns, 0..) |column, i| {
            std.debug.print("  ", .{});

            column.print();
            if (i < self.columns.len - 1) {
                std.debug.print(",", .{});
            }

            std.debug.print("\n", .{});
        }

        std.debug.print("FROM\n  {s}", .{self.from.string()});

        if (self.where) |where| {
            std.debug.print("\nWHERE\n  ", .{});
            where.print();
        }

        std.debug.print("\n", .{});
    }
};

const CreateTableColumnAST = struct {
    name: Token,
    kind: Token,
};

pub const CreateTableAST = struct {
    table: Token,
    columns: []CreateTableColumnAST,

    fn print(self: CreateTableAST) void {
        std.debug.print("CREATE TABLE {s} (\n", .{self.table.string()});

        for (self.columns, 0..) |column, i| {
            std.debug.print(
                "  {s} {s}",
                .{ column.name.string(), column.kind.string() },
            );
            if (i < self.columns.len - 1) {
                std.debug.print(",", .{});
            }
            std.debug.print("\n", .{});
        }
        std.debug.print(")\n", .{});
    }
};

pub const InsertAST = struct {
    table: Token,
    values: []ExpressionAST,

    fn print(self: InsertAST) void {
        std.debug.print("INSERT INTO {s} VALUES (", .{self.table.string()});
        for (self.values, 0..) |value, i| {
            value.print();
            if (i < self.values.len - 1) {
                std.debug.print(", ", .{});
            }
        }
        std.debug.print(")\n", .{});
    }
};

pub const AST = union(enum) {
    select: SelectAST,
    create_table: CreateTableAST,
    insert: InsertAST,

    pub fn print(self: AST) void {
        switch (self) {
            .select => |select| select.print(),
        }
    }
};

pub const ParserError = error{
    InvalidSelectStatement,
    ExpectComma,
    ExpectIdentifier,
    ExpectSelectKeyword,
    ExpectFromKeyword,
    ExpectCreateKeyword,
    ExpectCreateTableName,
    ExpectInsertKeyword,
    ExpectLeftParenSyntax,
    ExpectRightParenSyntax,
    EmptyColumns,
    UnexpectedToken,
    ExpectValueKeyword,
    EmptyValues,
    NoExpression,
    FailAllocateColumns,
    FailAllocateToken,
};

pub const Parser = struct {
    allocator: std.mem.Allocator,
    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Parser {
        return Parser{ .allocator = allocator };
    }

    fn expectTokenKind(tokens: []Token, index: u64, kind: Kind) bool {
        if (index >= tokens.len) {
            return false;
        }

        return tokens[index].kind == kind;
    }

    fn parseExpression(self: Self, tokens: []Token, index: u64) !struct {
        ast: ExpressionAST,
        next_position: u64,
    } {
        var i = index;

        var e: ExpressionAST = undefined;

        if (expectTokenKind(tokens, i, Kind.integer) or
            expectTokenKind(tokens, i, Kind.identifier) or
            expectTokenKind(tokens, i, Kind.string))
        {
            e = ExpressionAST{ .literal = tokens[i] };
            i = i + 1;
        } else {
            return ParserError.NoExpression;
        }

        if (expectTokenKind(tokens, i, Token.Kind.equal_operator) or
            expectTokenKind(tokens, i, Token.Kind.lt_operator) or
            expectTokenKind(tokens, i, Token.Kind.plus_operator) or
            expectTokenKind(tokens, i, Token.Kind.concat_operator))
        {
            const new_expression = ExpressionAST{
                .binary_operation = BinaryOperationAST{
                    .operator = tokens[i],
                    .left = self.allocator.create(ExpressionAST) catch return .{
                        .err = "Could not allocate for left expression.",
                    },
                    .right = self.allocator.create(ExpressionAST) catch return .{
                        .err = "Could not allocate for right expression.",
                    },
                },
            };
            new_expression.binary_operation.left.* = e;
            e = new_expression;

            const res = try self.parseExpression(tokens, i + 1);
            e.binary_operation.right.* = res.ast;
            i = res.next_position;
        }

        return .{ .ast = e, .next_position = i };
    }

    fn parseSelect(self: Self, tokens: []Token) !AST {
        var i: u64 = 0;
        if (!expectTokenKind(tokens, i, Token.Kind.select_keyword)) {
            return ParserError.ExpectSelectKeyword;
        }
        i = i + 1;

        var columns = std.ArrayList(ExpressionAST).init(self.allocator);
        var select = SelectAST{
            .columns = undefined,
            .from = undefined,
            .where = null,
        };

        // Parse columns
        while (!expectTokenKind(tokens, i, Kind.from_keyword)) {
            if (columns.items.len > 0) {
                if (!expectTokenKind(tokens, i, Token.Kind.comma_syntax)) {
                    lex.debug(tokens, i, "Expected comma.\n");
                    return ParserError.ExpectComma;
                }

                i = i + 1;
            }

            const res = try self.parseExpression(tokens, i);
            i = res.next_position;
            columns.append(res.ast) catch return ParserError.FailAllocateColumns;
        }

        if (!expectTokenKind(tokens, i, Kind.from_keyword)) {
            lex.debug(tokens, i, "Expected FROM keyword after this.\n");
            return ParserError.ExpectFromKeyword;
        }
        i = i + 1;

        if (!expectTokenKind(tokens, i, Kind.identifier)) {
            lex.debug(tokens, i, "Expected FROM table name after this.\n");
            return ParserError.ExpectFromKeyword;
        }

        select.from = tokens[i];
        i = i + 1;

        if (expectTokenKind(tokens, i, Token.Kind.where_keyword)) {
            // i + 1, skip past the where
            const where_expression = try self.parseExpression(tokens, i + 1);
            select.where = where_expression.ast;
            i = where_expression.next_position;
        }

        if (i < tokens.len) {
            lex.debug(tokens, i, "Unexpected token.");
            return ParserError.UnexpectedToken;
        }

        select.columns = columns.items;
        return AST{ .select = select };
    }

    fn parseCreateTable(self: Self, tokens: []Token) !AST {
        var i: u64 = 0;
        if (!expectTokenKind(tokens, i, Kind.create_table_keyword)) {
            return ParserError.ExpectCreateKeyword;
        }
        i = i + 1;

        if (!expectTokenKind(tokens, i, Kind.identifier)) {
            lex.debug(tokens, i, "Expected table name after CREATE TABLE keyword.\n");
            return ParserError.ExpectCreateTableName;
        }

        var columns = std.ArrayList(CreateTableColumnAST).init(self.allocator);
        var create_table = CreateTableAST{
            .columns = undefined,
            .table = tokens[i],
        };
        i = i + 1;

        if (!expectTokenKind(tokens, i, Kind.left_paren_syntax)) {
            lex.debug(tokens, i, "Expected opening paren after CREATE TABLE name.\n");
            return ParserError.ExpectLeftParenSyntax;
        }
        i = i + 1;

        while (!expectTokenKind(tokens, i, Kind.right_paren_syntax)) {
            if (columns.items.len > 0) {
                if (!expectTokenKind(tokens, i, Kind.comma_syntax)) {
                    lex.debug(tokens, i, "Expected comma.\n");
                    return ParserError.ExpectComma;
                }

                i = i + 1;
            }

            var column = CreateTableColumnAST{ .name = undefined, .kind = undefined };
            if (!expectTokenKind(tokens, i, Kind.identifier)) {
                lex.debug(tokens, i, "Expected column name after comma.\n");
                return ParserError.ExpectIdentifier;
            }

            column.name = tokens[i];
            i = i + 1;

            if (!expectTokenKind(tokens, i, Kind.identifier)) {
                lex.debug(tokens, i, "Expected column type after column name.\n");
                return ParserError.ExpectIdentifier;
            }

            column.kind = tokens[i];
            i = i + 1;

            columns.append(column) catch return ParserError.FailAllocateColumns;
        }

        // Skip past final paren.
        i = i + 1;

        if (i < tokens.len) {
            lex.debug(tokens, i, "Unexpected token.");
            return ParserError.UnexpectedToken;
        }

        create_table.columns = columns.items;
        return AST{ .create_table = create_table };
    }

    fn parseInsert(self: Self, tokens: []Token) !AST {
        var i: u64 = 0;
        if (!expectTokenKind(tokens, i, Token.Kind.insert_keyword)) {
            return .{ .err = "Expected INSERT INTO keyword" };
        }
        i = i + 1;

        if (!expectTokenKind(tokens, i, Token.Kind.identifier)) {
            lex.debug(tokens, i, "Expected table name after INSERT INTO keyword.\n");
            return .{ .err = "Expected INSERT INTO table name" };
        }

        var values = std.ArrayList(ExpressionAST).init(self.allocator);
        var insert = InsertAST{
            .values = undefined,
            .table = tokens[i],
        };
        i = i + 1;

        if (!expectTokenKind(tokens, i, Token.Kind.values_keyword)) {
            lex.debug(tokens, i, "Expected VALUES keyword.\n");
            return .{ .err = "Expected VALUES keyword" };
        }
        i = i + 1;

        if (!expectTokenKind(tokens, i, Token.Kind.left_paren_syntax)) {
            lex.debug(tokens, i, "Expected opening paren after CREATE TABLE name.\n");
            return .{ .err = "Expected opening paren" };
        }
        i = i + 1;

        while (!expectTokenKind(tokens, i, Token.Kind.right_paren_syntax)) {
            if (values.items.len > 0) {
                if (!expectTokenKind(tokens, i, Token.Kind.comma_syntax)) {
                    lex.debug(tokens, i, "Expected comma.\n");
                    return .{ .err = "Expected comma." };
                }

                i = i + 1;
            }

            switch (self.parseExpression(tokens, i)) {
                .err => |err| return .{ .err = err },
                .val => |val| {
                    values.append(val.ast) catch return .{
                        .err = "Could not allocate for expression.",
                    };
                    i = val.nextPosition;
                },
            }
        }

        // Skip past final paren.
        i = i + 1;

        if (i < tokens.len) {
            lex.debug(tokens, i, "Unexpected token.");
            return .{ .err = "Did not complete parsing INSERT INTO" };
        }

        insert.values = values.items;
        return .{ .val = AST{ .insert = insert } };
    }

    pub fn parse(self: Self, tokens: []Token) !ast.AST {
        if (expectTokenKind(tokens, 0, Kind.select_keyword)) {
            const select_ast = try self.parseSelect(tokens);
            return .{ .select_ast = select_ast };
        } else if (expectTokenKind(tokens, 0, Kind.create_table_keyword)) {
            const create_table_ast = try self.parseCreateTable(tokens);
            return .{ .create_table_ast = create_table_ast };
        } else if (expectTokenKind(tokens, 0, Kind.insert_keyword)) {
            const insert_ast = try self.parseInsert(tokens);
            return .{ .insert_ast = insert_ast };
        }

        return ParserError.InvalidStatement;
    }
};
