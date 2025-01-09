const std = @import("std");

pub const Kind = enum {
    unknown,

    // ----------- 保留关键字 ------------
    select_keyword, // select
    create_table_keyword, // create table
    insert_keyword, // insert into
    values_keyword, // values
    from_keyword, // from
    where_keyword, // where

    // ----------- 运算符关键字 -------------
    plus_operator, // +
    equal_operator, // =
    lt_operator, // <
    gt_operator, // >
    concat_operator, // ||

    // ---------- 符号关键字 -------------
    left_paren_syntax, // (
    right_paren_syntax, // )
    comma_syntax, // ,
    identifier, // 普通标识符
    integer, // 整型
    string, // 字符串

    pub fn toString(self: Kind) []const u8 {
        return @tagName(self);
    }
};

pub const Builtin = struct {
    name: []const u8,
    kind: Kind,
};

// sorting by length of keyword.
const BUILTINS = [_]Builtin{
    .{ .name = "CREATE TABLE", .kind = Kind.create_table_keyword },
    .{ .name = "INSERT INTO", .kind = Kind.insert_keyword },
    .{ .name = "SELECT", .kind = Kind.select_keyword },
    .{ .name = "VALUES", .kind = Kind.values_keyword },
    .{ .name = "WHERE", .kind = Kind.where_keyword },
    .{ .name = "FROM", .kind = Kind.from_keyword },
    .{ .name = "||", .kind = Kind.concat_operator },
    .{ .name = "=", .kind = Kind.equal_operator },
    .{ .name = "+", .kind = Kind.plus_operator },
    .{ .name = "<", .kind = Kind.lt_operator },
    .{ .name = ">", .kind = Kind.gt_operator },
    .{ .name = "(", .kind = Kind.left_paren_syntax },
    .{ .name = ")", .kind = Kind.right_paren_syntax },
    .{ .name = ",", .kind = Kind.comma_syntax },
};

pub const Token = struct {
    start: u64,
    end: u64,
    kind: Kind,
    source: []const u8,

    const Self = @This();

    pub fn init(start: u64, end: u64, kind: Kind, source: []const u8) Self {
        return Self{
            .start = start,
            .end = end,
            .kind = kind,
            .source = source,
        };
    }

    pub fn getKind(self: Self) Kind {
        return self.kind;
    }

    pub fn string(self: Self) []const u8 {
        return self.source[self.start..self.end];
    }

    fn debug(self: Self, msg: []const u8) void {
        var line: usize = 0;
        var column: usize = 0;
        var lineStartIndex: usize = 0;
        var lineEndIndex: usize = 0;
        var i: usize = 0;

        var source = self.source;
        while (i < source.len) {
            if (source[i] == '\n') {
                line = line + 1;
                column = 0;
                lineStartIndex = i;
            } else {
                column = column + 1;
            }

            if (i == self.start) {
                // Find the end of the line
                lineEndIndex = i;
                while (source[lineEndIndex] != '\n') {
                    lineEndIndex = lineEndIndex + 1;
                }
                break;
            }

            i = i + 1;
        }

        std.debug.print(
            "{s}\nNear line {}, column {}.\n{s}\n",
            .{ msg, line + 1, column, source[lineStartIndex..lineEndIndex] },
        );
        while (column - 1 > 0) {
            std.debug.print(" ", .{});
            column = column - 1;
        }
        std.debug.print("^ Near here\n\n", .{});
    }
};

pub fn debug(tokens: []Token, preferredIndex: usize, msg: []const u8) void {
    var i = preferredIndex;
    while (i >= tokens.len) {
        i = i - 1;
    }

    tokens[i].debug(msg);
}

pub const Lex = struct {
    index: u64,
    source: []const u8,

    const Self = @This();

    fn nextKeyword(self: *Self) ?Token {
        var longest_len: usize = 0;
        var kind = Token.Kind.unknown;
        for (BUILTINS) |builtin| {
            if (self.index + builtin.name.len > self.source.len) continue;

            // 大小写不敏感
            if (asciiCaseInsensitiveEqual(self.source[self.index .. self.index + builtin.name.len], builtin.name)) {
                longest_len = builtin.name.len;
                kind = builtin.Kind;
                break;
            }
        }

        // 由于我们关键字是按长度倒排序的，所以匹配到的一定是最长的keyword
        if (longest_len == 0) return null;
        defer self.index += longest_len;

        return Token.init(self.index, self.index + longest_len, kind, self.source);
    }

    fn nextInteger(self: *Self) ?Token {
        var end = self.index;
        var i = self.index;
        while (i < self.source.len and self.source[i] >= '0' and self.source[i] <= '9') {
            end += 1;
            i += 1;
        }
        if (self.index == end) return null;
        defer self.index = end;

        return Token.init(self.index, end, Token.Kind.integer, self.source);
    }
    fn nextString(self: *Self) ?Token {
        var i = self.index;
        if (self.source[i] != '\'') return null;
        i += 1;

        const start = i;
        var end = i;
        while (i < self.source.len and self.source[i] != '\'') {
            end += 1;
            i += 1;
        }
        if (self.source[i] == '\'') i += 1;
        if (start == end) return null;
        defer self.index = i;

        return Token.init(start, end, Token.Kind.string, self.source);
    }

    fn nextIdentifier(self: *Self) ?Token {
        var i = self.index;
        var end = self.index;
        while (i < self.source.len and ((self.source[i] >= 'a' and self.source[i] <= 'z') or (self.source[i] >= 'A' and self.source[i] <= 'Z') or self.source[i] == '*')) {
            i += 1;
            end += 1;
        }
        if (self.index == end) return null;
        defer self.index = end;

        return Token.init(self.index, end, Token.Kind.identifier, self.source);
    }

    pub fn hasNext(self: *Self) bool {
        self.index = eatWhitespace(self.source, self.index);
        return self.index < self.source.len;
    }
    pub fn next(self: Self) Token {
        std.debug.print("index: {d}, len: {d}, src: {s}\n", .{ self.index, self.source.len, self.source[self.index..] });
        self.index = eatWhitespace(self.source, self.index);
        if (self.index >= self.source.len) return error.OutOfSource;
        if (self.nextKeyword()) |token| {
            return token;
        }
        if (self.nextInteger()) |token| {
            return token;
        }
        if (self.nextString()) |token| {
            return token;
        }
        if (self.nextIdentifier()) |token| {
            return token;
        }
        return Token{
            .start = 0,
            .end = 0,
        };
    }

    pub fn init(source: []const u8) Self {
        return Self{
            .source = source,
            .index = 0,
        };
    }

    pub fn lex(self: Self, allocator: std.mem.Allocator) []Token {
        var tokens = std.ArrayList(Token).init(allocator);
        while (true) {
            const token = self.next();
            if (token.start == 0 and token.end == 0) {
                tokens.append(token) catch |err| std.debug.print("fail to append token to tokens array with %s", err);
            }
        }
        return tokens;
    }
};

fn eatWhitespace(source: []const u8, index: u64) u64 {
    var res = index;
    while (source[res] == ' ' or
        source[res] == '\n' or
        source[res] == '\t' or
        source[res] == '\r')
    {
        res = res + 1;
        if (res == source.len) {
            break;
        }
    }

    return res;
}

fn asciiCaseInsensitiveEqual(left: []const u8, right: []const u8) bool {
    var min = left;
    if (right.len < left.len) {
        min = right;
    }

    for (min, 0..) |_, i| {
        var l = left[i];
        if (l >= 97 and l <= 122) {
            l = l - 32;
        }

        var r = right[i];
        if (r >= 97 and r <= 122) {
            r = r - 32;
        }

        if (l != r) {
            return false;
        }
    }

    return true;
}

fn lexKeyword(source: []const u8, index: u64) struct { next_position: u64, token: ?Token } {
    var longest_len: u64 = 0;
    var kind = Kind.select_keyword;
    for (BUILTINS) |builtin| {
        if (index + builtin.name.len >= source.len) {
            continue;
        }

        if (asciiCaseInsensitiveEqual(source[index .. index + builtin.name.len], builtin.name)) {
            longest_len = builtin.name.len;
            kind = builtin.kind;
            // First match is the longest match
            break;
        }
    }

    if (longest_len == 0) {
        return .{ .next_position = 0, .token = null };
    }

    return .{
        .next_position = index + longest_len,
        .token = Token{
            .source = source,
            .start = index,
            .end = index + longest_len,
            .kind = kind,
        },
    };
}

fn lexInteger(source: []const u8, index: u64) struct { next_position: u64, token: ?Token } {
    const start = index;
    var end = index;
    while (source[end] >= '0' and source[end] <= '9') {
        end = end + 1;
    }

    if (start == end) {
        return .{ .next_position = 0, .token = null };
    }

    return .{
        .next_position = end,
        .token = Token{
            .source = source,
            .start = start,
            .end = end,
            .kind = Kind.integer,
        },
    };
}

fn lexString(source: []const u8, index: u64) struct { next_position: u64, token: ?Token } {
    var i = index;
    if (source[i] != '\'') {
        return .{ .next_position = 0, .token = null };
    }
    i = i + 1;

    const start = i;
    var end = i;
    while (source[i] != '\'') {
        end = end + 1;
        i = i + 1;
    }

    if (source[i] == '\'') {
        i = i + 1;
    }

    if (start == end) {
        return .{ .next_position = 0, .token = null };
    }

    return .{
        .next_position = i,
        .token = Token{
            .source = source,
            .start = start,
            .end = end,
            .kind = Kind.string,
        },
    };
}

fn lexIdentifier(source: []const u8, index: u64) struct { next_position: u64, token: ?Token } {
    const start = index;
    var end = index;
    var i = index;
    while ((source[i] >= 'a' and source[i] <= 'z') or
        (source[i] >= 'A' and source[i] <= 'Z') or
        (source[i] == '*'))
    {
        end = end + 1;
        i = i + 1;
    }

    if (start == end) {
        return .{ .next_position = 0, .token = null };
    }

    return .{
        .next_position = end,
        .token = Token{
            .source = source,
            .start = start,
            .end = end,
            .kind = Kind.identifier,
        },
    };
}

pub fn lex(source: []const u8, tokens: *std.ArrayList(Token)) ?[]const u8 {
    var i: u64 = 0;
    while (true) {
        i = eatWhitespace(source, i);
        if (i >= source.len) {
            break;
        }

        const keyword_res = lexKeyword(source, i);
        if (keyword_res.token) |token| {
            tokens.append(token) catch return "Failed to allocate space for keyword token";
            i = keyword_res.next_position;
            continue;
        }

        const integer_res = lexInteger(source, i);
        if (integer_res.token) |token| {
            tokens.append(token) catch return "Failed to allocate space for integer token";
            i = integer_res.next_position;
            continue;
        }

        const string_res = lexString(source, i);
        if (string_res.token) |token| {
            tokens.append(token) catch return "Failed to allocate space for string token";
            i = string_res.next_position;
            continue;
        }

        const identifier_res = lexIdentifier(source, i);
        if (identifier_res.token) |token| {
            tokens.append(token) catch return "Failed to allocate space for identifier token";
            i = identifier_res.next_position;
            continue;
        }

        if (tokens.items.len > 0) {
            debug(tokens.items, tokens.items.len - 1, "Last good token.\n");
        }
        return "Bad token";
    }

    return null;
}
