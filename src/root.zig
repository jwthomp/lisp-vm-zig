const std = @import("std");
const Allocator = std.mem.Allocator;

// ============================================================
// Token
// ============================================================

pub const Token = enum(u8) {
    left_paren,
    right_paren,
    semicolon,
    quote,
    symbol,
    number,
    eof,

    pub fn toToken(c: u8) ?Token {
        return switch (c) {
            '(' => .left_paren,
            ')' => .right_paren,
            else => null,
        };
    }
};

// ============================================================
// Lexer
// ============================================================

pub const Lexer = struct {
    input: []const u8,
    pos: usize,

    pub fn init(input: []const u8) Lexer {
        return Lexer{ .input = input, .pos = 0 };
    }

    pub fn skipWhitespace(self: *Lexer) void {
        while (self.pos < self.input.len) {
            const c = self.input[self.pos];
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                self.pos += 1;
            } else {
                break;
            }
        }
    }

    pub fn skipComment(self: *Lexer) void {
        while (self.pos < self.input.len) : (self.pos += 1) {
            if (self.input[self.pos - 1] == '\n') return;
        }
    }

    pub fn nextToken(self: *Lexer) ?Token {
        self.skipWhitespace();
        if (self.pos >= self.input.len) return .eof;
        const c = self.input[self.pos];
        if (Token.toToken(c)) |tok| {
            self.pos += 1;
            return tok;
        }
        if (c == ';') {
            self.pos += 1;
            self.skipComment();
            return self.nextToken();
        }
        if (c == 39) {
            self.pos += 1;
            return .quote;
        }
        if (std.ascii.isDigit(c)) {
            self.pos += 1;
            while (self.pos < self.input.len and std.ascii.isDigit(self.input[self.pos])) {
                self.pos += 1;
            }
            return .number;
        }
        if (std.ascii.isAlphabetic(c) or c == '+' or c == '-' or c == '*' or c == '/' or
            c == '=' or c == '<' or c == '>' or c == '_' or c == '!' or c == '?' or c == '$')
        {
            self.pos += 1;
            while (self.pos < self.input.len) {
                const ch = self.input[self.pos];
                if (std.ascii.isAlphanumeric(ch) or ch == '+' or ch == '-' or ch == '*' or ch == '/' or
                    ch == '=' or ch == '<' or ch == '>' or ch == '_' or ch == '.' or ch == '!' or
                    ch == '?' or ch == '@' or ch == '%')
                {
                    self.pos += 1;
                } else {
                    break;
                }
            }
            return .symbol;
        }
        return null;
    }
};

// ============================================================
// Symbol Internment
// ============================================================

pub const Symbol = struct {
    name: [:0]const u8,
};

pub const SymbolTable = struct {
    allocator: Allocator,
    arena: *std.heap.ArenaAllocator,
    table: std.StringHashMap(*Symbol),

    pub fn init(allocator: Allocator, arena: *std.heap.ArenaAllocator) SymbolTable {
        return SymbolTable{
            .allocator = allocator,
            .arena = arena,
            .table = std.StringHashMap(*Symbol).init(arena.allocator()),
        };
    }

    pub fn deinit(_: *SymbolTable) void {}

    pub fn getOrPut(self: *SymbolTable, name: []const u8) !*Symbol {
        if (self.table.get(name)) |sym| {
            return sym;
        }

        const key = try self.allocator.dupeZ(u8, name);
        errdefer self.allocator.free(key);

        const sym = try self.allocator.create(Symbol);
        errdefer self.allocator.free(key);
        sym.* = Symbol{ .name = key };

        try self.table.put(key, sym);
        return sym;
    }

    pub fn contains(self: *const SymbolTable, name: []const u8) bool {
        return self.table.contains(name);
    }
};

// ============================================================
// AST
// ============================================================

pub const Expr = union(enum) {
    symbol: *Symbol,
    number: i64,
    list: []Expr,
    nil,

    pub fn nilExpr() Expr { return Expr{ .nil = {} }; }
};

// ============================================================
// Parser
// ============================================================

pub const Parser = struct {
    tokens: []Token,
    pos: usize,
    arena: *std.heap.ArenaAllocator,
    symtab: *SymbolTable,

    pub fn init(tokens: []Token, arena: *std.heap.ArenaAllocator, symtab: *SymbolTable) Parser {
        return Parser{ .tokens = tokens, .pos = 0, .arena = arena, .symtab = symtab };
    }

    pub fn parse(self: *Parser) !Expr {
        return self.parseSExpr(0) catch {
            return Expr.nilExpr();
        };
    }

    fn parseSExpr(self: *Parser, depth: usize) !Expr {
        const MAX_DEPTH: usize = 64;
        if (depth > MAX_DEPTH) return Expr.nilExpr();
        if (self.pos >= self.tokens.len) return Expr.nilExpr();

        const tok = self.tokens[self.pos];
        return switch (tok) {
            .left_paren => {
                self.pos += 1;
                var items = try std.ArrayList(Expr).initCapacity(self.arena.allocator(), 4);
                errdefer items.deinit(self.arena.allocator());

                while (self.pos < self.tokens.len and self.tokens[self.pos] != .right_paren) {
                    const expr = self.parseSExpr(depth + 1) catch {
                        items.deinit(self.arena.allocator());
                        return error.ParseError;
                    };
                    try items.append(self.arena.allocator(), expr);
                }

                if (self.pos < self.tokens.len) {
                    self.pos += 1;
                }

                return Expr{ .list = try items.toOwnedSlice(self.arena.allocator()) };
            },
            .right_paren, .eof => return Expr.nilExpr(),
            else => {
                self.pos += 1;
                return self.parseAtom();
            },
        };
    }

    fn parseAtom(self: *Parser) !Expr {
        const tok = self.tokens[self.pos - 1];
        switch (tok) {
            .number => return Expr.nilExpr(),
            .symbol => return Expr.nilExpr(),
            else => return Expr.nilExpr(),
        }
    }
};

// ============================================================
// Runtime Objects
// ============================================================

pub const ObjType = enum(u8) {
    nil,
    symbol,
    number,
    cons,
    closure,
    builtin,
};

pub const LispObject = struct {
    type: ObjType,
    value: ValueUnion,
    next: ?*LispObject,

    const ValueUnion = union(ObjType) {
        nil: void,
        symbol: *Symbol,
        number: i64,
        cons: *ConsCell,
        closure: *Closure,
        builtin: []const u8,
    };

    pub fn nilObj() LispObject {
        return LispObject{ .type = .nil, .value = .{ .nil = {} }, .next = null };
    }

    pub fn symbolObj(sym: *Symbol) LispObject {
        return LispObject{ .type = .symbol, .value = .{ .symbol = sym }, .next = null };
    }

    pub fn numberObj(n: i64) LispObject {
        return LispObject{ .type = .number, .value = .{ .number = n }, .next = null };
    }
};

pub const ConsCell = struct {
    car: *LispObject,
    cdr: *LispObject,

    pub fn init(car: *LispObject, cdr: *LispObject) ConsCell {
        return ConsCell{ .car = car, .cdr = cdr };
    }
};

pub const Closure = struct {
    params: []const *Symbol,
    body: []const Expr,
    env: *Environment,
};

// ============================================================
// Environment (Phase 3)
// ============================================================

pub const Environment = struct {
    parent: ?*Environment,
    arena: std.heap.ArenaAllocator,
    bindings: std.StringHashMap(*LispObject),

    pub fn init(parent: ?*Environment, allocator: Allocator) Environment {
        return Environment{
            .parent = parent,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .bindings = std.StringHashMap(*LispObject).init(allocator),
        };
    }

    pub fn deinit(self: *Environment) void {
        self.bindings.deinit();
        self.arena.deinit();
    }

    /// Lookup a value by symbol name. Searches current frame then parents.
    pub fn lookup(self: *Environment, name: []const u8) ?*LispObject {
        if (self.bindings.get(name)) |val| {
            return val;
        }
        if (self.parent) |parent| {
            return parent.lookup(name);
        }
        return null;
    }

    /// Bind a value in the current frame.
    pub fn bind(self: *Environment, name: []const u8, val: *LispObject) !void {
        try self.bindings.put(name, val);
    }

    /// Create a child environment with one binding.
    pub fn child(self: *Environment, allocator: Allocator) Environment {
        return Environment.init(self, allocator);
    }
};

// ============================================================
// Vm — stack-based evaluator
// ============================================================

pub const Vm = struct {
    stack: std.ArrayList(*LispObject),
    allocator: Allocator,
    env: *Environment,

    pub fn init(allocator: Allocator, env: *Environment) Vm {
        return Vm{
            .stack = std.ArrayList(*LispObject).initCapacity(allocator, 8) catch unreachable,
            .allocator = allocator,
            .env = env,
        };
    }

    pub fn deinit(self: *Vm) void {
        self.stack.deinit(self.allocator);
    }

    pub fn push(self: *Vm, obj: *LispObject) void {
        self.stack.appendAssumeCapacity(obj);
    }

    pub fn pop(self: *Vm) ?*LispObject {
        if (self.stack.items.len > 0) return self.stack.pop(); return null;
    }

    pub fn peek(self: *Vm) ?*LispObject {
        if (self.stack.items.len == 0) return null;
        return self.stack.items[self.stack.items.len - 1];
    }

    pub fn drop(self: *Vm, n: usize) void {
        const len = self.stack.items.len;
        if (n >= len) {
            self.stack.clearRetainingCapacity();
        } else {
            self.stack.shrinkRetainingCapacity(len - n);
        }
    }

    // Primitives (Phase 4)
    pub fn primAdd(self: *Vm) !void {
        const b = self.pop() orelse return error.StackUnderflow;
        const a = self.pop() orelse return error.StackUnderflow;
        if (a.type != .number or b.type != .number) {
            return error.TypeError;
        }
        const result = self.allocator.create(LispObject) catch return error.OutOfMemory;
        result.* = LispObject.numberObj(a.value.number + b.value.number);
        self.push(result);
    }

    pub fn primSub(self: *Vm) !void {
        const a = self.pop() orelse return error.StackUnderflow;
        const b = self.pop() orelse return error.StackUnderflow;
        if (a.type != .number or b.type != .number) return error.TypeError;
        const result = self.allocator.create(LispObject) catch return error.OutOfMemory;
        result.* = LispObject.numberObj(a.value.number - b.value.number);
        self.push(result);
    }

    pub fn primMul(self: *Vm) !void {
        const b = self.pop() orelse return error.StackUnderflow;
        const a = self.pop() orelse return error.StackUnderflow;
        if (a.type != .number or b.type != .number) return error.TypeError;
        const result = self.allocator.create(LispObject) catch return error.OutOfMemory;
        result.* = LispObject.numberObj(a.value.number * b.value.number);
        self.push(result);
    }

    pub fn primDiv(self: *Vm) !void {
        const a = self.pop() orelse return error.StackUnderflow;
        const b = self.pop() orelse return error.StackUnderflow;
        if (a.type != .number or b.type != .number) return error.TypeError;
        if (b.value.number == 0) return error.DivisionByZero;
        const result = self.allocator.create(LispObject) catch return error.OutOfMemory;
        result.* = LispObject.numberObj(@divTrunc(a.value.number, b.value.number));
        self.push(result);
    }

    pub fn primEq(self: *Vm) !void {
        const b = self.pop() orelse return error.StackUnderflow;
        const a = self.pop() orelse return error.StackUnderflow;
        const result = self.allocator.create(LispObject) catch return error.OutOfMemory;
        result.* = if (a.type == .number and b.type == .number)
            LispObject.numberObj(if (a.value.number == b.value.number) 1 else 0)
        else
            LispObject.numberObj(0);
        self.push(result);
    }

    pub fn primLt(self: *Vm) !void {
        const a = self.pop() orelse return error.StackUnderflow;
        const b = self.pop() orelse return error.StackUnderflow;
        const result = self.allocator.create(LispObject) catch return error.OutOfMemory;
        result.* = if (a.type == .number and b.type == .number)
            LispObject.numberObj(if (a.value.number < b.value.number) 1 else 0)
        else
            LispObject.numberObj(0);
        self.push(result);
    }

    pub fn primGt(self: *Vm) !void {
        const a = self.pop() orelse return error.StackUnderflow;
        const b = self.pop() orelse return error.StackUnderflow;
        const result = self.allocator.create(LispObject) catch return error.OutOfMemory;
        result.* = if (a.type == .number and b.type == .number)
            LispObject.numberObj(if (a.value.number > b.value.number) 1 else 0)
        else
            LispObject.numberObj(0);
        self.push(result);
    }

    /// Call a primitive by name
    pub fn callPrim(self: *Vm, name: []const u8) !void {
        if (std.mem.eql(u8, name, "+")) return try self.primAdd();
        if (std.mem.eql(u8, name, "-")) return try self.primSub();
        if (std.mem.eql(u8, name, "*")) return try self.primMul();
        if (std.mem.eql(u8, name, "/")) return try self.primDiv();
        if (std.mem.eql(u8, name, "=")) return try self.primEq();
        if (std.mem.eql(u8, name, "<")) return try self.primLt();
        if (std.mem.eql(u8, name, ">")) return try self.primGt();
        return error.UnknownPrimitive;
    }
};

// ============================================================
// Tests
// ============================================================

// --- Lexer tests ---
test "lexer basic tokens" {
    var lexer = Lexer.init("(+ 1)");
    try std.testing.expectEqual(.left_paren, lexer.nextToken());
    try std.testing.expectEqual(.symbol, lexer.nextToken());
    try std.testing.expectEqual(.number, lexer.nextToken());
    try std.testing.expectEqual(.right_paren, lexer.nextToken());
}

test "lexer multiple numbers" {
    var lexer = Lexer.init("(+ 1 2 3)");
    try std.testing.expectEqual(.left_paren, lexer.nextToken());
    try std.testing.expectEqual(.symbol, lexer.nextToken());
    try std.testing.expectEqual(.number, lexer.nextToken());
    try std.testing.expectEqual(.number, lexer.nextToken());
    try std.testing.expectEqual(.number, lexer.nextToken());
    try std.testing.expectEqual(.right_paren, lexer.nextToken());
}

test "lexer symbols with special chars" {
    var lexer = Lexer.init("(+ - * / = < > _ ! ? $)");
    try std.testing.expectEqual(.left_paren, lexer.nextToken());
    try std.testing.expectEqual(.symbol, lexer.nextToken());
    try std.testing.expectEqual(.symbol, lexer.nextToken());
    try std.testing.expectEqual(.symbol, lexer.nextToken());
    try std.testing.expectEqual(.symbol, lexer.nextToken());
    try std.testing.expectEqual(.symbol, lexer.nextToken());
    try std.testing.expectEqual(.symbol, lexer.nextToken());
    try std.testing.expectEqual(.symbol, lexer.nextToken());
    try std.testing.expectEqual(.symbol, lexer.nextToken());
    try std.testing.expectEqual(.symbol, lexer.nextToken());
    try std.testing.expectEqual(.symbol, lexer.nextToken());
    try std.testing.expectEqual(.symbol, lexer.nextToken());
    try std.testing.expectEqual(.right_paren, lexer.nextToken());
}

test "lexer whitespace and comments" {
    var lexer = Lexer.init("  ( + \n  ; comment\n  1  )  ");
    try std.testing.expectEqual(.left_paren, lexer.nextToken());
    try std.testing.expectEqual(.symbol, lexer.nextToken());
    try std.testing.expectEqual(.number, lexer.nextToken());
    try std.testing.expectEqual(.right_paren, lexer.nextToken());
}

// --- Symbol table tests ---
test "symbol table — intern same name returns same pointer" {
    const alloc = std.heap.page_allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var table = SymbolTable.init(alloc, &arena);
    const sym1 = try table.getOrPut("foo");
    const sym2 = try table.getOrPut("foo");
    try std.testing.expectEqual(@as(*Symbol, @ptrCast(sym1)), @as(*Symbol, @ptrCast(sym2)));
}

test "symbol table — different names are different pointers" {
    const alloc = std.heap.page_allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var table = SymbolTable.init(alloc, &arena);
    const sym1 = try table.getOrPut("foo");
    const sym2 = try table.getOrPut("bar");
    try std.testing.expect(@as(*Symbol, @ptrCast(sym1)) != @as(*Symbol, @ptrCast(sym2)));
}

test "symbol table — contains check" {
    const alloc = std.heap.page_allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var table = SymbolTable.init(alloc, &arena);
    try std.testing.expect(!table.contains("foo"));
    _ = try table.getOrPut("foo");
    try std.testing.expect(table.contains("foo"));
    try std.testing.expect(!table.contains("bar"));
}

test "symbol table — intern 5 symbols" {
    const alloc = std.heap.page_allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var table = SymbolTable.init(alloc, &arena);
    const a = try table.getOrPut("x");
    const b = try table.getOrPut("y");
    const c = try table.getOrPut("x");
    const d = try table.getOrPut("z");
    const e = try table.getOrPut("y");
    try std.testing.expect(@as(*Symbol, @ptrCast(a)) == @as(*Symbol, @ptrCast(c)));
    try std.testing.expect(@as(*Symbol, @ptrCast(b)) == @as(*Symbol, @ptrCast(e)));
    try std.testing.expect(@as(*Symbol, @ptrCast(a)) != @as(*Symbol, @ptrCast(b)));
    try std.testing.expect(@as(*Symbol, @ptrCast(b)) != @as(*Symbol, @ptrCast(d)));
}

// --- LispObject tests ---
test "LispObject — create nil object" {
    const obj = LispObject.nilObj();
    try std.testing.expectEqual(ObjType.nil, obj.type);
}

test "LispObject — create number object" {
    const obj = LispObject.numberObj(42);
    try std.testing.expectEqual(ObjType.number, obj.type);
    try std.testing.expectEqual(@as(i64, 42), obj.value.number);
}

test "LispObject — create symbol object" {
    const alloc = std.heap.page_allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var table = SymbolTable.init(alloc, &arena);
    const sym = try table.getOrPut("hello");
    const obj = LispObject.symbolObj(sym);
    try std.testing.expectEqual(ObjType.symbol, obj.type);
    try std.testing.expectEqual(@as(*Symbol, @ptrCast(sym)), obj.value.symbol);
}

// --- ConsCell tests ---
test "ConsCell — create cons pair" {
    const alloc = std.heap.page_allocator;
    const car = alloc.create(LispObject) catch unreachable;
    car.* = LispObject.numberObj(1);
    const cdr = alloc.create(LispObject) catch unreachable;
    cdr.* = LispObject.nilObj();
    const cell = ConsCell.init(car, cdr);
    try std.testing.expectEqual(@as(i64, 1), cell.car.value.number);
    alloc.destroy(car);
    alloc.destroy(cdr);
}

test "ConsCell — build a list (1 2 nil)" {
    const alloc = std.heap.page_allocator;
    const nil_obj = alloc.create(LispObject) catch unreachable;
    nil_obj.* = LispObject.nilObj();
    const n2_obj = alloc.create(LispObject) catch unreachable;
    n2_obj.* = LispObject.numberObj(2);
    const n1_obj = alloc.create(LispObject) catch unreachable;
    n1_obj.* = LispObject.numberObj(1);
    const cell3 = alloc.create(ConsCell) catch unreachable;
    cell3.* = ConsCell.init(n2_obj, nil_obj);
    const cell2 = alloc.create(ConsCell) catch unreachable;
    cell2.* = ConsCell.init(n1_obj, @ptrCast(cell3));
    try std.testing.expectEqual(@as(i64, 1), cell2.car.value.number);
    try std.testing.expectEqual(@as(i64, 2), cell3.car.value.number);
    try std.testing.expectEqual(ObjType.nil, cell3.cdr.type);
    alloc.destroy(cell3);
    alloc.destroy(cell2);
    alloc.destroy(nil_obj);
    alloc.destroy(n2_obj);
    alloc.destroy(n1_obj);
}

// --- Environment tests ---
test "Environment — init and lookup" {
    const alloc = std.heap.page_allocator;
    var env = Environment.init(null, alloc);
    defer env.deinit();
    try std.testing.expect(env.parent == null);
}

test "Environment — bind and lookup in same frame" {
    const alloc = std.heap.page_allocator;
    const obj = alloc.create(LispObject) catch unreachable;
    obj.* = LispObject.numberObj(42);
    var env = Environment.init(null, alloc);
    defer env.deinit();
    errdefer alloc.destroy(obj);
    try env.bind("x", obj);
    const val = env.lookup("x");
    try std.testing.expect(val != null);
    try std.testing.expectEqual(@as(i64, 42), val.?.value.number);
}

test "Environment — lookup in parent frame" {
    const alloc = std.heap.page_allocator;
    const parent_obj = alloc.create(LispObject) catch unreachable;
    parent_obj.* = LispObject.numberObj(10);
    var parent = Environment.init(null, alloc);
    defer parent.deinit();
    errdefer alloc.destroy(parent_obj);
    try parent.bind("x", parent_obj);

    var child = parent.child(alloc);
    defer child.deinit();

    const val = child.lookup("x");
    try std.testing.expect(val != null);
    try std.testing.expectEqual(@as(i64, 10), val.?.value.number);
}

test "Environment — shadowing" {
    const alloc = std.heap.page_allocator;
    const inner_obj = alloc.create(LispObject) catch unreachable;
    inner_obj.* = LispObject.numberObj(99);
    const parent_obj = alloc.create(LispObject) catch unreachable;
    parent_obj.* = LispObject.numberObj(10);
    var parent = Environment.init(null, alloc);
    defer parent.deinit();
    errdefer alloc.destroy(parent_obj);
    try parent.bind("x", parent_obj);

    var child = parent.child(alloc);
    defer child.deinit();
    errdefer alloc.destroy(inner_obj);
    try child.bind("x", inner_obj);

    const val = child.lookup("x");
    try std.testing.expectEqual(@as(i64, 99), val.?.value.number);
}

// --- Vm stack tests ---
test "Vm — push and pop" {
    const alloc = std.heap.page_allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var env = Environment.init(null, alloc);
    defer env.deinit();
    var vm = Vm.init(alloc, &env);
    defer vm.deinit();

    const obj = alloc.create(LispObject) catch unreachable;
    obj.* = LispObject.numberObj(42);
    errdefer alloc.destroy(obj);

    vm.push(obj);
    const popped = vm.pop();
    try std.testing.expect(popped != null);
    try std.testing.expectEqual(@as(i64, 42), popped.?.value.number);
}

test "Vm — peek does not remove" {
    const alloc = std.heap.page_allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var env = Environment.init(null, alloc);
    defer env.deinit();
    var vm = Vm.init(alloc, &env);
    defer vm.deinit();

    const obj = alloc.create(LispObject) catch unreachable;
    obj.* = LispObject.numberObj(7);
    errdefer alloc.destroy(obj);

    vm.push(obj);
    const peeked = vm.peek();
    try std.testing.expect(peeked != null);
    try std.testing.expectEqual(@as(i64, 7), peeked.?.value.number);
    const popped = vm.pop();
    try std.testing.expectEqual(@as(i64, 7), popped.?.value.number);
}

test "Vm — drop" {
    const alloc = std.heap.page_allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var env = Environment.init(null, alloc);
    defer env.deinit();
    var vm = Vm.init(alloc, &env);
    defer vm.deinit();

    for (0..5) |i| {
        const obj = alloc.create(LispObject) catch unreachable;
        obj.* = LispObject.numberObj(@intCast(i));
        errdefer alloc.destroy(obj);
        vm.push(obj);
    }
    vm.drop(2);
    try std.testing.expectEqual(@as(usize, 3), vm.stack.items.len);
}

// --- Primitive tests ---
test "primAdd — 2 + 3 = 5" {
    const alloc = std.heap.page_allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var env = Environment.init(null, alloc);
    defer env.deinit();
    var vm = Vm.init(alloc, &env);
    defer vm.deinit();

    const a = alloc.create(LispObject) catch unreachable;
    a.* = LispObject.numberObj(2);
    const b = alloc.create(LispObject) catch unreachable;
    b.* = LispObject.numberObj(3);
    errdefer alloc.destroy(b);
    errdefer alloc.destroy(a);

    vm.push(b);
    vm.push(a);
    try vm.primAdd();

    const result = vm.pop();
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(i64, 5), result.?.value.number);
}

test "primSub — 10 - 4 = 6" {
    const alloc = std.heap.page_allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var env = Environment.init(null, alloc);
    defer env.deinit();
    var vm = Vm.init(alloc, &env);
    defer vm.deinit();

    const b = alloc.create(LispObject) catch unreachable;
    b.* = LispObject.numberObj(4);
    const a = alloc.create(LispObject) catch unreachable;
    a.* = LispObject.numberObj(10);
    errdefer alloc.destroy(a);
    errdefer alloc.destroy(b);

    vm.push(b);
    vm.push(a);
    try vm.primSub();

    const result = vm.pop();
    try std.testing.expectEqual(@as(i64, 6), result.?.value.number);
}

test "primMul — 3 * 4 * 5" {
    const alloc = std.heap.page_allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var env = Environment.init(null, alloc);
    defer env.deinit();
    var vm = Vm.init(alloc, &env);
    defer vm.deinit();

    const c = alloc.create(LispObject) catch unreachable;
    c.* = LispObject.numberObj(5);
    const b = alloc.create(LispObject) catch unreachable;
    b.* = LispObject.numberObj(4);
    const a = alloc.create(LispObject) catch unreachable;
    a.* = LispObject.numberObj(3);
    errdefer alloc.destroy(c);
    errdefer alloc.destroy(b);
    errdefer alloc.destroy(a);

    vm.push(c);
    vm.push(b);
    try vm.primMul();
    vm.push(a);
    try vm.primMul();

    const result = vm.pop();
    try std.testing.expectEqual(@as(i64, 60), result.?.value.number);
}

test "primDiv — 20 / 4 = 5" {
    const alloc = std.heap.page_allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var env = Environment.init(null, alloc);
    defer env.deinit();
    var vm = Vm.init(alloc, &env);
    defer vm.deinit();

    const b = alloc.create(LispObject) catch unreachable;
    b.* = LispObject.numberObj(4);
    const a = alloc.create(LispObject) catch unreachable;
    a.* = LispObject.numberObj(20);
    errdefer alloc.destroy(b);
    errdefer alloc.destroy(a);

    vm.push(b);
    vm.push(a);
    try vm.primDiv();

    const result = vm.pop();
    try std.testing.expectEqual(@as(i64, 5), result.?.value.number);
}

test "primEq — 5 == 5 returns 1" {
    const alloc = std.heap.page_allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var env = Environment.init(null, alloc);
    defer env.deinit();
    var vm = Vm.init(alloc, &env);
    defer vm.deinit();

    const b = alloc.create(LispObject) catch unreachable;
    b.* = LispObject.numberObj(5);
    const a = alloc.create(LispObject) catch unreachable;
    a.* = LispObject.numberObj(5);
    errdefer alloc.destroy(b);
    errdefer alloc.destroy(a);

    vm.push(b);
    vm.push(a);
    try vm.primEq();

    const result = vm.pop();
    try std.testing.expectEqual(@as(i64, 1), result.?.value.number);
}

test "primEq — 3 == 7 returns 0" {
    const alloc = std.heap.page_allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var env = Environment.init(null, alloc);
    defer env.deinit();
    var vm = Vm.init(alloc, &env);
    defer vm.deinit();

    const b = alloc.create(LispObject) catch unreachable;
    b.* = LispObject.numberObj(7);
    const a = alloc.create(LispObject) catch unreachable;
    a.* = LispObject.numberObj(3);
    errdefer alloc.destroy(b);
    errdefer alloc.destroy(a);

    vm.push(b);
    vm.push(a);
    try vm.primEq();

    const result = vm.pop();
    try std.testing.expectEqual(@as(i64, 0), result.?.value.number);
}

test "primLt — 3 < 7 returns 1" {
    const alloc = std.heap.page_allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var env = Environment.init(null, alloc);
    defer env.deinit();
    var vm = Vm.init(alloc, &env);
    defer vm.deinit();

    const b = alloc.create(LispObject) catch unreachable;
    b.* = LispObject.numberObj(7);
    const a = alloc.create(LispObject) catch unreachable;
    a.* = LispObject.numberObj(3);
    errdefer alloc.destroy(b);
    errdefer alloc.destroy(a);

    vm.push(b);
    vm.push(a);
    try vm.primLt();

    const result = vm.pop();
    try std.testing.expectEqual(@as(i64, 1), result.?.value.number);
}

test "primGt — 7 > 3 returns 1" {
    const alloc = std.heap.page_allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var env = Environment.init(null, alloc);
    defer env.deinit();
    var vm = Vm.init(alloc, &env);
    defer vm.deinit();

    const b = alloc.create(LispObject) catch unreachable;
    b.* = LispObject.numberObj(3);
    const a = alloc.create(LispObject) catch unreachable;
    a.* = LispObject.numberObj(7);
    errdefer alloc.destroy(b);
    errdefer alloc.destroy(a);

    vm.push(b);
    vm.push(a);
    try vm.primGt();

    const result = vm.pop();
    try std.testing.expectEqual(@as(i64, 1), result.?.value.number);
}

// ============================================================
// Main
// ============================================================

pub fn main() void {
    const input = "(+ 1 2 3)";
    std.debug.print("Input: {s}\n", .{input});

    var lexer = Lexer.init(input);
    var tok_buf: [128]Token = undefined;
    var tok_count: usize = 0;
    while (tok_count < tok_buf.len) {
        const tok = lexer.nextToken() orelse break;
        if (tok == .eof) break;
        tok_buf[tok_count] = tok;
        tok_count += 1;
    }
    const tokens = tok_buf[0..tok_count];
    std.debug.print("Tokens: {} items\n", .{tok_count});

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var symtab = SymbolTable.init(std.heap.page_allocator, &arena);
    defer symtab.deinit();

    var parser = Parser.init(tokens, &arena, &symtab);
    _ = parser.parse() catch {
        std.debug.print("Parse failed\n", .{});
        return;
    };
    std.debug.print("Parsed successfully\n", .{});
}
