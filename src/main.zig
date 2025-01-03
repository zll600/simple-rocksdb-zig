const std = @import("std");
const lex = @import("lex.zig");
const Lex = @import("lex.zig").Lex;
const Parser = @import("parser.zig").Parser;
const KV = @import("kv.zig").KV;
const Storage = @import("storage.zig").Storage;
const Executor = @import("executor.zig").Executor;

pub const DBError = error{
    InvalidArgument,
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const stdout = std.io.getStdOut().writer();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    var database_path: []const u8 = undefined;
    var script: []const u8 = undefined;
    var debugTokens = false;
    var debugAST = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--database")) {
            database_path = args.next().?;
        } else if (std.mem.eql(u8, arg, "--script")) {
            script = args.next().?;
        } else if (std.mem.eql(u8, arg, "--debug-tokens")) {
            debugTokens = true;
        } else if (std.mem.eql(u8, arg, "--debug-ast")) {
            debugAST = true;
        }
    }

    if (database_path.len == 0) {
        std.log.err("No database specified", .{});
        return;
    }
    if (script.len == 0) {
        std.log.err("No script specified", .{});
        return;
    }

    // read script
    const script_file = try std.fs.cwd().openFile(script, .{});
    defer script_file.close();

    const file_size = try script_file.getEndPos();
    const script_buffer = try allocator.alloc(u8, file_size);
    defer allocator.free(script_buffer);

    _ = try script_file.readAll(script_buffer);

    // lex SQL script
    const tokens = Lex.init(script_buffer).lex(allocator);
    // var tokens = std.ArrayList(lex.Token).init(allocator);
    defer allocator.free(tokens);
    if (tokens.len == 0) {
        std.log.err("No tokens found", .{});
        return;
    }

    // parse SQL script
    const ast = try Parser.init(allocator).parse(tokens);

    // init rocksdb
    var kv: KV = try KV.init(allocator, database_path);
    defer kv.deinit();

    // init rocksdb
    const db = Storage.init(allocator, kv);

    // execute AST
    const executer = Executor.init(allocator, db);
    const resp = try executer.execute(ast);
    // for `create table` and `insert` SQL, we print OK
    if (resp.rows.len == 0) {
        try stdout.print("OK\n", .{});
        return;
    }

    // for select SQL
    // print fields
    try stdout.print("| ", .{});
    for (resp.fields) |field| {
        try stdout.print("{s}\t\t ", .{field});
    }
    try stdout.print("\n+", .{});

    // print ----
    for (resp.fields) |field| {
        var fl = field.len;
        while (fl > 0) : (fl -= 1) {
            try stdout.print("-", .{});
        }
        try stdout.print("\t\t ", .{});
    }
    try stdout.print("\n", .{});

    // print rows
    for (resp.rows) |row| {
        try stdout.print("| ", .{});
        for (row) |value| {
            try stdout.print("{s}\t\t ", .{value});
        }
        try stdout.print("\n", .{});
    }
}
