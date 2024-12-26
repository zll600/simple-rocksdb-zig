const std = @import("std");
const Token = @import("lex.zig").Token;
const Kind = @import("lex.zig").Kind;
const ast = @import("ast.zig");

pub const ParserError = error{
    InvalidStatement,
    ExpectCommaSyntax,
    ExpectIdentifier,
    ExpectSelectKeyword,
    ExpectCreateKeyword,
    ExpectInsertKeyword,
    ExpectLeftParenSyntax,
    ExpectRightParenSyntax,
    EmptyColumns,
    UnexpectedToken,
    ExpectValueKeyword,
    EmptyValues,
};

pub const Parser = struct {
    allocator: std.mem.Allocator,
    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Parser {
        return Parser{ .allocator = allocator };
    }

    fn expectTokenKind(tokens: []Token, index: usize, kind: Kind) bool {
        if (index >= tokens.len) {
            return false;
        }

        return tokens[index].kind == kind;
    }

    fn parseExpression(
        self: Self,
        tokens: []Token,
        index: *usize,
    ) !ast.ExpressionAST {
        var i = index.*;
        var e: ast.ExpressionAST = undefined;

        // 字符串、整型和普通标识符
        if (ast.isExpectTokenKind(
            tokens,
            i,
            Kind.string,
        ) or ast.isExpectTokenKind(
            tokens,
            i,
            Kind.integer,
        ) or ast.isExpectTokenKind(
            tokens,
            i,
            Kind.identifier,
        )) {
            e = .{ .literal = tokens[i] };
            index.* += 1;
        } else {
            return ParserError.InvalidStatement;
        }
        i += 1;

        // 计算符号
        if (ast.isExpectTokenKind(
            tokens,
            i,
            Kind.equal_operator,
        ) or ast.isExpectTokenKind(
            tokens,
            i,
            Kind.lt_operator,
        ) or ast.isExpectTokenKind(
            tokens,
            i,
            Kind.gt_operator,
        ) or ast.isExpectTokenKind(
            tokens,
            i,
            Kind.plus_operator,
        ) or ast.isExpectTokenKind(
            tokens,
            i,
            Kind.concat_operator,
        )) {
            const new_expression = ast.ExpressionAST{
                .binary_operation = try ast.BinaryOperationAST.init(
                    self.allocator,
                    tokens[i],
                ),
            };
            new_expression.binary_operation.left.* = e;
            e = new_expression;
            index.* += 1;
            const parsed_expression = try self.parseExpression(tokens, index); // 递归分析
            e.binary_operation.right.* = parsed_expression;
        }
        return e;
    }

    fn parseSelect(
        self: Self,
        tokens: []Token,
    ) !ast.SelectAST {
        var i: usize = 0;
        // expect select keyword
        if (!ast.isExpectTokenKind(tokens, i, Kind.select_keyword)) {
            return ParserError.ExpectSelectKeyword;
        }
        i += 1;

        var select = ast.SelectAST.init(self.allocator);

        // analyze columns
        var columns = std.ArrayList(ast.ExpressionAST).init(self.allocator);
        while (!ast.isExpectTokenKind(tokens, i, Kind.from_keyword)) {
            if (columns.items.len > 0) {
                // 不止一个字段时，expect逗号分隔符
                if (!ast.isExpectTokenKind(tokens, i, Kind.comma_syntax)) {
                    return ParserError.ExpectCommaSyntax;
                }
                i += 1;
            }

            // 分析columns表达式
            const parsed_expression = try self.parseExpression(
                tokens,
                &i,
            );
            defer parsed_expression.deinit();

            try columns.append(parsed_expression);
        }

        select.columns = try columns.toOwnedSlice();
        if (select.columns.len == 0) {
            // columns不能为空
            return ParserError.ExpectIdentifier;
        }
        i += 1;

        // table name
        if (!ast.isExpectTokenKind(tokens, i, Kind.identifier)) {
            return ParserError.ExpectIdentifier;
        }
        select.from = tokens[i];
        i += 1;

        // 分析where条件
        if (ast.isExpectTokenKind(tokens, i, Kind.where_keyword)) {
            i += 1;
            const parsed_expression = try self.parseExpression(
                tokens,
                &i,
            );
            select.where = parsed_expression;
        }
        return select;
    }

    fn parseCreateTable(self: Self, tokens: []Token) !ast.CreateTableAST {
        var i: usize = 0;

        // create table
        if (!ast.isExpectTokenKind(tokens, i, Kind.create_table_keyword)) {
            return ParserError.ExpectCreateKeyword;
        }
        i += 1;

        // table name
        if (!ast.isExpectTokenKind(tokens, i, Kind.identifier)) {
            return ParserError.ExpectIdentifier;
        }
        var create_table_ast = ast.CreateTableAST.init(self.allocator);
        create_table_ast.table = tokens[i];
        i += 1;

        // columns: (field1 type, field2 type,...)
        var columns = std.ArrayList(ast.CreateTableColumnAST).init(self.allocator);
        if (!ast.isExpectTokenKind(tokens, i, Kind.left_paren_syntax)) {
            return ParserError.ExpectLeftParenSyntax;
        }
        i += 1;
        while (!ast.isExpectTokenKind(tokens, i, Kind.right_paren_syntax)) {
            if (columns.items.len > 0) {
                if (!ast.isExpectTokenKind(tokens, i, Kind.comma_syntax)) {
                    return ParserError.ExpectCommaSyntax;
                }
                i += 1;
            }
            var column = ast.CreateTableColumnAST.init();
            if (!ast.isExpectTokenKind(tokens, i, Kind.identifier)) {
                return ParserError.ExpectIdentifier;
            }
            column.name = tokens[i];
            i += 1;
            if (!ast.isExpectTokenKind(tokens, i, Kind.identifier)) {
                return ParserError.ExpectIdentifier;
            }
            column.kind = tokens[i];
            i += 1;
            try columns.append(column);
        }
        if (columns.items.len == 0) {
            return ParserError.EmptyColumns;
        }

        // )
        i += 1;
        if (i < tokens.len) {
            return ParserError.UnexpectedToken;
        }

        create_table_ast.columns = try columns.toOwnedSlice();
        return create_table_ast;
    }

    fn parseInsert(self: Self, tokens: []Token) !ast.InsertAST {
        var i: usize = 0;

        // insert into
        if (!ast.isExpectTokenKind(tokens, i, Kind.insert_keyword)) {
            return ParserError.ExpectInsertKeyword;
        }
        i += 1;

        // table name
        if (!ast.isExpectTokenKind(tokens, i, Kind.identifier)) {
            return ParserError.ExpectIdentifier;
        }
        var insert_ast = ast.InsertAST.init(self.allocator);
        insert_ast.table = tokens[i];
        i += 1;

        // values (val1, val2,...)
        var values = std.ArrayList(ast.ExpressionAST).init(self.allocator);
        if (!ast.isExpectTokenKind(tokens, i, Kind.values_keyword)) {
            return ParserError.ExpectValueKeyword;
        }
        i += 1;
        if (!ast.isExpectTokenKind(tokens, i, Kind.left_paren_syntax)) {
            return ParserError.ExpectLeftParenSyntax;
        }
        i += 1;
        while (!ast.isExpectTokenKind(tokens, i, Kind.right_paren_syntax)) {
            if (values.items.len > 0) {
                if (!ast.isExpectTokenKind(tokens, i, Kind.comma_syntax)) {
                    return ParserError.ExpectCommaSyntax;
                }
                i += 1;
            }
            const exp = try self.parseExpression(tokens, &i);
            defer exp.deinit();
            try values.append(exp);
        }
        if (values.items.len == 0) {
            return ParserError.EmptyValues;
        }

        // )
        i += 1;
        if (i < tokens.len) {
            return ParserError.UnexpectedToken;
        }

        insert_ast.values = try values.toOwnedSlice();
        return insert_ast;
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
