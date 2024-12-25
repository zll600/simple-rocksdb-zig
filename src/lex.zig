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
    Kind: Kind,
};

const BUILTINS = [_]Builtin{
    .{ .name = "CREATE TABLE", .Kind = Token.Kind.create_table_keyword },
    .{ .name = "INSERT INTO", .Kind = Token.Kind.insert_keyword },
    .{ .name = "SELECT", .Kind = Token.Kind.select_keyword },
    .{ .name = "VALUES", .Kind = Token.Kind.values_keyword },
    .{ .name = "WHERE", .Kind = Token.Kind.where_keyword },
    .{ .name = "FROM", .Kind = Token.Kind.from_keyword },
    .{ .name = "||", .Kind = Token.Kind.concat_operator },
    .{ .name = "=", .Kind = Token.Kind.equal_operator },
    .{ .name = "+", .Kind = Token.Kind.plus_operator },
    .{ .name = "<", .Kind = Token.Kind.lt_operator },
    .{ .name = ">", .Kind = Token.Kind.gt_operator },
    .{ .name = "(", .Kind = Token.Kind.left_paren_syntax },
    .{ .name = ")", .Kind = Token.Kind.right_paren_syntax },
    .{ .name = ",", .Kind = Token.Kind.comma_syntax },
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
};

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
    pub fn next(self: *Self) !Token {
        // std.debug.print("index: {d}, len: {d}, src: {s}\n", .{ self.index, self.source.len, self.source[self.index..] });
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
        return error.BadToken;
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
            const token = try self.next();
            tokens.addOne(token);
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

fn asciiCaseInsensitiveEqual(actual: []const u8, expected: []const u8) bool {
    var index: u64 = 1;
    while (index < actual.len and index < expected.len) {
        if (actual[index] == expected[index]) {
            return true;
        }

        if (actual[index] >= 32 and (actual[index] - 32) == expected[index]) {
            return true;
        }
        if (expected[index] >= 32 and actual[index] == (expected[index] - 32))
            index += 1;
    }
    return false;
}

// fn asciiCaseInsensitiveEqual(left: String, right: String) bool {
//     var min = left;
//     if (right.len < left.len) {
//         min = right;
//     }

//     for (min) |_, i| {
//         var l = left[i];
//         if (l >= 97 and l <= 122) {
//             l = l - 32;
//         }

//         var r = right[i];
//         if (r >= 97 and r <= 122) {
//             r = r - 32;
//         }

//         if (l != r) {
//             return false;
//         }
//     }
