pub const ExpressionAST = union(enum) {
    literal: Token, // 字面逻辑    binary_operation: BinaryOperationAST, // 计算逻辑
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
    columns: []ExpressionAST, // 选择字段    from: Token, // 数据表    where: ?ExpressionAST, // where条件 ?表示可以为null    allocator: std.mem.Allocator,
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
    name: Token, // 字段名    kind: Token, // 字段类型，目前只支持string和int
    pub fn init() CreateTableColumnAST {
        return .{
            .name = undefined,
            .kind = undefined,
        };
    }
};
pub const CreateTableAST = struct {
    table: Token, // 数据表    columns: []CreateTableColumnAST, // 表字段定义    allocator: std.mem.Allocator,
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
    table: Token, // 数据表    values: []ExpressionAST, // 插入赋值    allocator: std.mem.Allocator,
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

fn isExpectTokenKind(tokens: []Token, index: usize, kind: Token.Kind) bool {
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
    // 字符串、整型和普通标识符    if (isExpectTokenKind(        tokens,        i,        Token.Kind.string,    ) or isExpectTokenKind(        tokens,        i,        Token.Kind.integer,    ) or isExpectTokenKind(        tokens,        i,        Token.Kind.identifier,    )) {        e = .{ .literal = tokens[i] };        index.* += 1;    } else {        return ParserError.InvalidStatement;    }
    i += 1;
    // 计算符号    if (isExpectTokenKind(        tokens,        i,        Token.Kind.equal_operator,    ) or isExpectTokenKind(        tokens,        i,        Token.Kind.lt_operator,    ) or isExpectTokenKind(        tokens,        i,        Token.Kind.gt_operator,    ) or isExpectTokenKind(        tokens,        i,        Token.Kind.plus_operator,    ) or isExpectTokenKind(        tokens,        i,        Token.Kind.concat_operator,    )) {        const new_expression = ast.ExpressionAST{            .binary_operation = try ast.BinaryOperationAST.init(                self.allocator,                tokens[i],            ),        };        new_expression.binary_operation.left.* = e;        e = new_expression;        index.* += 1;        const parsed_expression = try self.parseExpression(tokens, index); // 递归分析        e.binary_operation.right.* = parsed_expression;    }
    return e;
}

fn parseSelect(
    self: Self,
    tokens: []Token,
) !ast.SelectAST {
    var i: usize = 0; // expect select keyword    if (!isExpectTokenKind(tokens, i, Token.Kind.select_keyword)) {        return ParserError.ExpectSelectKeyword;    }    i += 1;    var columns = std.ArrayList(ast.ExpressionAST).init(self.allocator);    var select = ast.SelectAST.init(self.allocator);
    // 分析columns    while (!isExpectTokenKind(tokens, i, Token.Kind.from_keyword)) {        if (columns.items.len > 0) { // 不止一个字段时，expect逗号分隔符            if (!isExpectTokenKind(tokens, i, Token.Kind.comma_syntax)) {                return ParserError.ExpectCommaSyntax;            }            i += 1;        }        // 分析columns表达式        const parsed_expression = try self.parseExpression(            tokens,            &i,        );        defer parsed_expression.deinit();        try columns.append(parsed_expression);    }    select.columns = try columns.toOwnedSlice();    if (select.columns.len == 0) { // columns不能为空        return ParserError.ExpectIdentifier;    }    i += 1;
    // table name    if (!isExpectTokenKind(tokens, i, Token.Kind.identifier)) {        return ParserError.ExpectIdentifier;    }    select.from = tokens[i];    i += 1;
    // 分析where条件    if (isExpectTokenKind(tokens, i, Token.Kind.where_keyword)) {        i += 1;        const parsed_expression = try self.parseExpression(            tokens,            &i,        );        select.where = parsed_expression;    }
    return select;
}

fn parseCreateTable(self: Self, tokens: []Token) !ast.CreateTableAST {
    var i: usize = 0; // create table    if (!isExpectTokenKind(tokens, i, Token.Kind.create_table_keyword)) {        return ParserError.ExpectCreateKeyword;    }
    i += 1; // table name    if (!isExpectTokenKind(tokens, i, Token.Kind.identifier)) {        return ParserError.ExpectIdentifier;    }    var create_table_ast = ast.CreateTableAST.init(self.allocator);    create_table_ast.table = tokens[i];
    i += 1; // columns: (field1 type, field2 type,...)    var columns = std.ArrayList(ast.CreateTableColumnAST).init(self.allocator);
    if (!isExpectTokenKind(tokens, i, Token.Kind.left_paren_syntax)) {
        return ParserError.ExpectLeftParenSyntax;
    }
    i += 1;
    while (!isExpectTokenKind(tokens, i, Token.Kind.right_paren_syntax)) {
        if (columns.items.len > 0) {
            if (!isExpectTokenKind(tokens, i, Token.Kind.comma_syntax)) {
                return ParserError.ExpectCommaSyntax;
            }
            i += 1;
        }
        var column = ast.CreateTableColumnAST.init();
        if (!isExpectTokenKind(tokens, i, Token.Kind.identifier)) {
            return ParserError.ExpectIdentifier;
        }
        column.name = tokens[i];
        i += 1;
        if (!isExpectTokenKind(tokens, i, Token.Kind.identifier)) {
            return ParserError.ExpectIdentifier;
        }
        column.kind = tokens[i];
        i += 1;
        try columns.append(column);
    }
    if (columns.items.len == 0) {
        return ParserError.EmptyColumns;
    } // )    i += 1;
    if (i < tokens.len) {
        return ParserError.UnexpectedToken;
    }
    create_table_ast.columns = try columns.toOwnedSlice();
    return create_table_ast;
}

fn parseInsert(self: Self, tokens: []Token) !ast.InsertAST {
    var i: usize = 0; // insert into
    if (!isExpectTokenKind(tokens, i, Token.Kind.insert_keyword)) {
        return ParserError.ExpectInsertKeyword;
    }
    i += 1; // table name
    if (!isExpectTokenKind(tokens, i, Token.Kind.identifier)) {
        return ParserError.ExpectIdentifier;
    }
    var insert_ast = ast.InsertAST.init(self.allocator);
    insert_ast.table = tokens[i];
    i += 1;
    // values (val1, val2,...)
    var values = std.ArrayList(ast.ExpressionAST).init(self.allocator);
    if (!isExpectTokenKind(tokens, i, Token.Kind.values_keyword)) {
        return ParserError.ExpectValueKeyword;
    }
    i += 1;
    if (!isExpectTokenKind(tokens, i, Token.Kind.left_paren_syntax)) {
        return ParserError.ExpectLeftParenSyntax;
    }
    i += 1;
    while (!isExpectTokenKind(tokens, i, Token.Kind.right_paren_syntax)) {
        if (values.items.len > 0) {
            if (!isExpectTokenKind(tokens, i, Token.Kind.comma_syntax)) {
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
