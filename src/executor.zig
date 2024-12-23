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
    // 取出对应field的值    pub fn get(self: Self, field: []const u8, val: *Value) bool {        if (field.len == 0) {            return false;        }        for (self.table.columns, 0..) |f, i| {            if (std.mem.eql(u8, f, field)) {                val.* = self.cells.items[i];                return true;            }        }        return false;    }
    pub fn reset(self: *Self) void {
        for (self.cells.items) |c| {
            c.deinit(self.allocator);
        }
        self.cells.clearRetainingCapacity();
    }
};

const RowIter = struct {
    const Self = @This();
    iter: Rocksdb.Iter,
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
// [length: 4bytes][bytes]pub fn serializeBytes(allocator: std.mem.Allocator, bytes: []const u8) ![]const u8 {    var h: [4]u8 = undefined;    serializeInteger(u32, @intCast(bytes.len), &h);    const parts = [_][]const u8{ &h, bytes };    return std.mem.concat(allocator, u8, &parts);}
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


@spec serialize(int | string | bool) -> bytes // alias s/1
@spec serializeBytes(bytes) -> bytes // alias sB/1
table_dewuer => |sB(year)|sB(int)|sB(age)|sB(int)|sB(name)|sB(text)|

// table_{table} => |{column}|{type}|{column}|{type}|....
pub fn writeTable(self: Self, table: Table) !void {    
    // table name    
    const k = try std.fmt.allocPrint(self.allocator, "table_{s}", .{table.name});    
    defer self.allocator.free(k);
    var cb = std.ArrayList(u8).init(self.allocator);    
    defer cb.deinit();
    for (table.columns, 0..) |col, i| {        
        const b1 = try value.serializeBytes(self.allocator, col);        
        defer self.allocator.free(b1);        
        try cb.appendSlice(b1);        
        const b2 = try value.serializeBytes(self.allocator, table.types[i]);        
        defer self.allocator.free(b2);        
        try cb.appendSlice(b2);    
    }    
    try self.db.set(k, cb.items);
}

@spec serialize(int | string | bool) -> bytes // alias s/1
@spec serializeBytes(bytes) -> bytes // alias sB/1
row_dewuer_{random_id()} => sB(s(2020))++sB(s(34))++sB(s('Lisi'))

// row_{tablel}_{id} => {row}
pub fn writeRow(self: Self, table: []const u8, row: Row) !void {    
    // make sure table exists    
    if (!try self.tableExists(table)) {        
        return StorageError.TableNotFound;    
    }    
    const buf = try self.allocator.alloc(u8, table.len + 21);    
    defer self.allocator.free(buf);    
    var id: [16]u8 = undefined;    

    generateId(&id); // 生成随机串当做主键    
    const k = try std.fmt.bufPrint(buf, "row_{s}_{s}", .{ table, id });
    // row data    
    var va = std.ArrayList(u8).init(self.allocator);    
    defer va.deinit();    
    for (row.items()) |cell| {        
        var b = std.ArrayList(u8).init(self.allocator);        
        defer b.deinit();        
        try cell.serialize(&b);
        const bin = try value.serializeBytes(self.allocator, b.items);        
        defer self.allocator.free(bin);        
        try va.appendSlice(bin);    
    }    
    return self.db.set(k, va.items);
}

pub fn getTable(self: Self, table_name: []const u8) !?Table {    
    const k = try std.fmt.allocPrint(self.allocator, "table_{s}", .{table_name});    
    defer self.allocator.free(k);
    var columns = std.ArrayList([]const u8).init(self.allocator);    
    var types = std.ArrayList([]const u8).init(self.allocator);
    // get table info    
    var b = std.ArrayList(u8).init(self.allocator);    
    defer b.deinit();    
    try self.db.get(k, &b);    
    const detail = b.items;    
    if (detail.len == 0) {        
        return null;    
    }    
    // rebuild columns    
    var offset: usize = 0;    
    while (offset < detail.len) {        
        var buf: []const u8 = undefined;        
        offset += value.deserializeBytes(detail[offset..], &buf);        
        try columns.append(try self.allocator.dupe(u8, buf));        
        offset += value.deserializeBytes(detail[offset..], &buf);        
        try types.append(try self.allocator.dupe(u8, buf));    
    }
    return Table.init(        
        self.allocator,        
        table_name,        
        try columns.toOwnedSlice(),        
        try types.toOwnedSlice(),    
        );
}

pub fn getRowIter(self: Self, table: Table) !RowIter {    
    const row_prefix = try std.fmt.allocPrint(self.allocator, "row_{s}", .{table.name});    
    defer self.allocator.free(row_prefix);
    return RowIter.init(self.allocator, self.db, row_prefix, table);
}


fn executeExpression(self: Self, expr: ast.ExpressionAST, row: storage.Row) !Value {    return switch (expr) {        .literal => |literal| {            switch (literal.getKind()) {                .string => return Value{ .string_value = literal.string() },                .integer => return Value{ .integer_value = try std.fmt.parseInt(i64, literal.string(), 10) },                .identifier => { // 普通标记符，一般为column名                    var val: Value = undefined;                    if (row.get(literal.string(), &val)) {                        return val;                    }                    unreachable;                },                else => unreachable,            }        },        .binary_operation => |binary_operation| {            const left = try self.executeExpression(binary_operation.getLeft(), row);            defer left.deinit(self.allocator);            const right = try self.executeExpression(binary_operation.getRight(), row);            defer right.deinit(self.allocator);            var lb = std.ArrayList(u8).init(self.allocator);            defer lb.deinit();            var rb = std.ArrayList(u8).init(self.allocator);            defer rb.deinit();            // 先将两臂的值都转换为字符串，方便后续的比较逻辑，这里实现有点丑陋==            try left.asString(&lb);            try right.asString(&rb);
            switch (binary_operation.getOpKind()) {                // 相等计算 -> 比较两臂字符串是否相等                .equal_operator => return Value{ .bool_value = std.mem.eql(u8, lb.items, rb.items) },                // 连接计算 -> 将两臂字符串连接                .concat_operator => {                    var result = std.ArrayList(u8).init(self.allocator);                    try result.appendSlice(lb.items);                    try result.appendSlice(rb.items);                    return Value{ .string_value = try result.toOwnedSlice() };                },                // 大于计算 -> 将两臂转换为整型后比较                .lt_operator => {                    if (try left.asInteger() < try right.asInteger()) {                        return Value.TRUE;                    } else {                        return Value.FALSE;                    }                },                // 小于计算 -> 同理大于计算                .gt_operator => {                    if (try left.asInteger() > try right.asInteger()) {                        return Value.TRUE;                    } else {                        return Value.FALSE;                    }                },                // 加法计算 -> 将两臂转换为整型后相加                .plus_operator => {                    return Value{ .integer_value = try left.asInteger() + try right.asInteger() };                },                else => unreachable,            }        },    };}


fn executeCreateTable(self: Self, create_table: ast.CreateTableAST) !QueryResponse {    const table_name = create_table.getTableName();    if (try self.storage.getTable(table_name)) |t| {        t.deinit();        return ExecuteError.TableAlreadyExists;    }
    var columns = std.ArrayList([]const u8).init(self.allocator);    defer columns.deinit();    var types = std.ArrayList([]const u8).init(self.allocator);    defer types.deinit();
    for (create_table.columns) |c| {        try columns.append(c.getName()); // 取出字段名        try types.append(c.getKind()); // 取出字段类型    }
    const table = Table.init(        self.allocator,        table_name,        columns.items,        types.items,    );
    try self.storage.writeTable(table); // 写入KV
    return QueryResponse{        .fields = undefined,        .rows = undefined,        .allocator = self.allocator,    };}


fn executeInsert(self: Self, insert: ast.InsertAST) !QueryResponse {    const table_name = insert.getTableName();    if (try self.storage.getTable(table_name)) |t| {        defer t.deinit();        var empty_row = Row.init(self.allocator, t);        defer empty_row.deinit();        var row = Row.init(self.allocator, t);        defer row.deinit();        for (insert.values) |v| {            try row.append(try self.executeExpression(v, empty_row));        }
        // write row        try self.storage.writeRow(table_name, row);
        return QueryResponse{            .fields = undefined,            .rows = undefined,            .allocator = self.allocator,        };    }
    return ExecuteError.TableNotFound;}

fn executeSelect(self: Self, select: ast.SelectAST) !QueryResponse {    const table_name = select.getTableName();
    // select x, y    var select_fields = std.ArrayList([]const u8).init(self.allocator);    for (select.columns) |column| {        var field_name: []const u8 = undefined;        switch (column) {            .literal => |l| {                if (l.getKind() == .identifier) {                    field_name = l.string();                } else {                    unreachable;                }            },            else => unreachable,        }        try select_fields.append(field_name);    }    // 判断是否为Select *    var select_all = false;    if (select_fields.items.len == 1 and std.mem.eql(u8, select_fields.items[0], "*")) {        select_all = true;        select_fields.clearRetainingCapacity();        if (try self.storage.getTable(table_name)) |table| {            defer table.deinit();            for (table.getColumns()) |c| {                try select_fields.append(try self.allocator.dupe(u8, c));            }        } else {            return ExecuteError.TableNotFound;        }    }
    var rows = std.ArrayList([][]const u8).init(self.allocator);    if (try self.storage.getTable(table_name)) |table| {        defer table.deinit();        var iter = try self.storage.getRowIter(table);        defer iter.deinit();
        while (try iter.next()) |row| {            defer row.deinit();            // 判断这条Row是否满足Where条件            var whereable = false;            if (select.where) |where| {                const wv = try self.executeExpression(where, row);                defer wv.deinit(self.allocator);                if (wv.asBool()) {                    whereable = true;                }            } else {                // no where clause, add all                whereable = true;            }
            if (whereable) {                var select_res = std.ArrayList([]const u8).init(self.allocator);                if (select_all) {                    for (table.getColumns()) |c| {                        var val: Value = undefined;                        if (row.get(c, &val)) {                            var b = std.ArrayList(u8).init(self.allocator);                            try val.asString(&b);                            try select_res.append(try b.toOwnedSlice());                        } else {                            unreachable;                        }                    }                } else {                    for (select.columns) |column| {                        const val = try self.executeExpression(column, row);                        defer val.deinit(self.allocator);                        var b = std.ArrayList(u8).init(self.allocator);                        try val.asString(&b);                        try select_res.append(try b.toOwnedSlice());                    }                }                try rows.append(try select_res.toOwnedSlice());            }        }        return QueryResponse{            .fields = try select_fields.toOwnedSlice(),            .rows = try rows.toOwnedSlice(),            .allocator = self.allocator,        };    }    // table not exists    return ExecuteError.TableNotFound;}