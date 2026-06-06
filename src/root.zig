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
    rootEnv: *Environment,

    pub fn init(allocator: Allocator, env: *Environment) Vm {
        return Vm{
            .stack = std.ArrayList(*LispObject).initCapacity(allocator, 8) catch unreachable,
            .allocator = allocator,
            .rootEnv = env,
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


    /// Evaluate a single (non-list) Expr into a LispObject.
    pub fn evalAtom(self: *Vm, expr: Expr, env: *Environment) !*LispObject {
        switch (expr) {
            .nil => {
                const obj = try self.allocator.create(LispObject);
                obj.* = LispObject.nilObj();
                return obj;
            },
            .number => |n| {
                const obj = try self.allocator.create(LispObject);
                obj.* = LispObject.numberObj(n);
                return obj;
            },
            .symbol => |sym| {
                // Use sym.name directly — StringHashMap handles the null terminator
                if (env.lookup(sym.name)) |v| return v;
                if (self.rootEnv.lookup(sym.name)) |v| return v;
                const obj = try self.allocator.create(LispObject);
                obj.* = LispObject.nilObj();
                return obj;
            },
            .list => return error.ListExprNotHandledByEvalAtom,
        }
    }

    /// (def name value) — bind in root env, return value.
    pub fn evalDef(self: *Vm, items: []Expr) !*LispObject {
        if (items.len < 3) return error.DefRequiresTwoArgs;
        const name: []const u8 = switch (items[1]) {
            .symbol => |sym| sym.name,
            else => return error.DefInvalidName,
        };
        const val = switch (items[2]) {
            .number => |n| blk: {
                const obj = try self.allocator.create(LispObject);
                obj.* = LispObject.numberObj(n);
                break :blk obj;
            },
            .nil => blk: {
                const obj = try self.allocator.create(LispObject);
                obj.* = LispObject.nilObj();
                break :blk obj;
            },
            else => return error.DefUnsupportedValue,
        };
        try self.rootEnv.bind(name, val);
        return val;
    }

    /// (do expr ...) — evaluate all, return last.
    pub fn evalDo(self: *Vm, items: []Expr) !*LispObject {
        const err = self._evalDo(items);
        return err catch return err;
    }

    fn _evalDo(self: *Vm, items: []Expr) anyerror!*LispObject {
        if (items.len < 2) {
            const obj = try self.allocator.create(LispObject);
            obj.* = LispObject.nilObj();
            return obj;
        }
        var result: *LispObject = self.eval(items[1], self.rootEnv) catch return error.EvalDoFailed;
        var i: usize = 2;
        while (i < items.len) {
            self.allocator.destroy(result);
            result = self.eval(items[i], self.rootEnv) catch return error.EvalDoFailed;
            i += 1;
        }
        return result;
    }

    /// (if test then else?) — conditional dispatch.
    pub fn evalIf(self: *Vm, items: []Expr) !*LispObject {
        return self._evalIf(items);
    }

    fn _evalIf(self: *Vm, items: []Expr) anyerror!*LispObject {
        if (items.len < 3) return error.IfRequiresAtLeastTwoArgs;
        const testVal = self.eval(items[1], self.rootEnv) catch return error.EvalIfFailed;
        defer self.allocator.destroy(testVal);
        if (testVal.type != .nil) {
            if (items.len > 2) return self.eval(items[2], self.rootEnv) catch return error.EvalIfFailed;
            const obj = try self.allocator.create(LispObject);
            obj.* = LispObject.nilObj();
            return obj;
        } else {
            if (items.len > 3) return self.eval(items[3], self.rootEnv) catch return error.EvalIfFailed;
            const obj = try self.allocator.create(LispObject);
            obj.* = LispObject.nilObj();
            return obj;
        }
    }

    /// (cond test-then test-then ...) — sequential matching.
    pub fn evalCond(self: *Vm, items: []Expr) !*LispObject {
        return self._evalCond(items);
    }

    fn _evalCond(self: *Vm, items: []Expr) anyerror!*LispObject {
        var i: usize = 1;
        while (i + 1 < items.len) {
            const testVal = self.eval(items[i], self.rootEnv) catch return error.EvalCondFailed;
            defer self.allocator.destroy(testVal);
            if (testVal.type != .nil) {
                return self.eval(items[i + 1], self.rootEnv) catch return error.EvalCondFailed;
            }
            i += 2;
        }
        const obj = try self.allocator.create(LispObject);
        obj.* = LispObject.nilObj();
        return obj;
    }

    /// (fn (params...) body...) — create closure object.
    pub fn evalFn(self: *Vm, items: []Expr, env: *Environment) !*LispObject {
        if (items.len < 3) return error.FnRequiresParamsAndBody;
        const paramsExpr = items[1];
        const bodyExprs = items[2..];

        // Extract parameter symbols into a heap-allocated array
        var paramCount: usize = 0;
        switch (paramsExpr) {
            .list => |params| {
                var pi: usize = 0;
                while (pi < params.len) : (pi += 1) {
                    switch (params[pi]) {
                        .symbol => { paramCount += 1; },
                        else => {},
                    }
                }
            },
            else => return error.FnParamsMustBeList,
        }

        const paramArr = try self.allocator.alloc(*Symbol, paramCount);
        errdefer self.allocator.free(paramArr);

        switch (paramsExpr) {
            .list => |params| {
                var pi: usize = 0;
                var ai: usize = 0;
                while (pi < params.len and ai < paramCount) : ({
                    pi += 1;
                    ai += 1;
                }) {
                    switch (params[pi]) {
                        .symbol => |s| { paramArr[ai] = s; },
                        else => {},
                    }
                }
            },
            else => {},
        }

        // Duplicate body (survives this frame — Exprs are arena-allocated)
        const body = try self.allocator.dupe(Expr, bodyExprs);

        // Create closure
        const closure = try self.allocator.create(Closure);
        closure.* = Closure{
            .params = paramArr,
            .body = body,
            .env = env,
        };

        // Wrap in LispObject
        const obj = try self.allocator.create(LispObject);
        obj.* = LispObject{
            .type = .closure,
            .value = .{ .closure = closure },
            .next = null,
        };
        return obj;
    }

    /// (defn name (params...) body...) — sugar for (def name (fn params body...)).
    pub fn evalDefn(self: *Vm, items: []Expr, env: *Environment) !*LispObject {
        if (items.len < 4) return error.DefnRequiresNameParamsAndBody;

        // Extract params list and body: items = [defn, name, params_list, body1, body2, ...]
        const paramsExpr = items[2];
        const bodyExprs = items[3..];

        // Build fn items: [fn, params, body1, body2, ...]
        const fnItems: []Expr = try self.allocator.alloc(Expr, 2 + bodyExprs.len);
        defer self.allocator.free(fnItems);

        // Get a "fn" symbol from a temp symtab
        var tempArena = std.heap.ArenaAllocator.init(self.allocator);
        defer tempArena.deinit();
        var tempSymtab = SymbolTable.init(self.allocator, &tempArena);
        const fnSym = try tempSymtab.getOrPut("fn");

        fnItems[0] = Expr{ .symbol = fnSym };
        fnItems[1] = paramsExpr;
        var i: usize = 0;
        while (i < bodyExprs.len) : (i += 1) {
            fnItems[2 + i] = bodyExprs[i];
        }

        // Create the closure
        const closureObj = try self.evalFn(fnItems, env);

        // Get a "def" symbol from temp symtab
        // Bind directly: rootEnv.bind(name, closureObj)
        var name: []const u8 = items[1].symbol.name[0..];
        while (name.len > 0 and name[name.len - 1] == 0) {
            name = name[0 .. name.len - 1];
        }
        try self.rootEnv.bind(name, closureObj);
        return closureObj;
    }

    /// Apply a closure: create child env, bind params, evaluate body.
    pub fn applyClosure(self: *Vm, cl: *Closure, args: []Expr, env: *Environment) !*LispObject {
        return self._applyClosure(cl, args, env);
    }

    fn _applyClosure(self: *Vm, cl: *Closure, args: []Expr, env: *Environment) anyerror!*LispObject {
        // Create child environment with closure's captured env as parent
        const childArena = try self.allocator.create(std.heap.ArenaAllocator);
        childArena.* = std.heap.ArenaAllocator.init(self.allocator);
        const childEnv = try self.allocator.create(Environment);
        childEnv.* = Environment.init(cl.env, childArena.allocator());
        defer {
            childEnv.deinit();
            self.allocator.destroy(childEnv);
        }

        // Bind parameters to argument values
        var ai: usize = 0;
        while (ai < cl.params.len and ai < args.len) {
            var paramName: []const u8 = cl.params[ai].name[0..];
            while (paramName.len > 0 and paramName[paramName.len - 1] == 0) {
                paramName = paramName[0 .. paramName.len - 1];
            }
            const argVal = try self.eval(args[ai], env);
            try childEnv.bind(paramName, argVal);
            ai += 1;
        }

        // Evaluate body sequentially
        var result: *LispObject = try self.allocator.create(LispObject);
        result.* = LispObject.nilObj();
        var i: usize = 0;
        while (i < cl.body.len) : (i += 1) {
            self.allocator.destroy(result);
            result = try self.eval(cl.body[i], childEnv);
        }
        return result;
    }

    /// Full eval: atom, list (calls), special forms (def).
    pub fn eval(self: *Vm, expr: Expr, env: *Environment) !*LispObject {
        switch (expr) {
            .nil => {
                const obj = try self.allocator.create(LispObject);
                obj.* = LispObject.nilObj();
                return obj;
            },
            .number => |n| {
                const obj = try self.allocator.create(LispObject);
                obj.* = LispObject.numberObj(n);
                return obj;
            },
            .symbol => |sym| {
                // Use sym.name directly — StringHashMap handles the null terminator
                if (env.lookup(sym.name)) |v| return v;
                if (self.rootEnv.lookup(sym.name)) |v| return v;
                const obj = try self.allocator.create(LispObject);
                obj.* = LispObject.nilObj();
                return obj;
            },
            .list => |items| {
                if (items.len == 0) {
                    const obj = try self.allocator.create(LispObject);
                    obj.* = LispObject.nilObj();
                    return obj;
                }
                const head = items[0];
                const headName = switch (head) {
                    .symbol => |sym| sym.name,
                    else => "",
                };

                // Strip trailing nulls for comparison
                var clean: []const u8 = headName[0..];
                while (clean.len > 0 and clean[clean.len - 1] == 0) clean = clean[0 .. clean.len - 1];

                // Special forms
                const isDef = clean.len >= 3 and clean[0] == 'd' and clean[1] == 'e' and clean[2] == 'f';
                const isDefn = clean.len >= 5 and clean[0] == 'd' and clean[1] == 'e' and clean[2] == 'f' and clean[3] == 'n';
                const isDo = clean.len >= 2 and clean[0] == 'd' and clean[1] == 'o';
                const isFn = clean.len >= 2 and clean[0] == 'f' and clean[1] == 'n';
                const isIf = clean.len >= 2 and clean[0] == 'i' and clean[1] == 'f';
                const isCond = clean.len >= 4 and clean[0] == 'c' and clean[1] == 'o' and clean[2] == 'n' and clean[3] == 'd';

                if (isDef) return try self.evalDef(items);
                if (isDefn) return try self.evalDefn(items, env);
                if (isDo) return try self._evalDo(items);
                if (isFn) return try self.evalFn(items, env);
                if (isIf) return try self._evalIf(items);
                if (isCond) return try self._evalCond(items);

                // Closure application: if head symbol resolves to a closure, apply it
                switch (head) {
                    .symbol => |sym| {
                        var symName: []const u8 = sym.name[0..];
                        while (symName.len > 0 and symName[symName.len - 1] == 0) {
                            symName = symName[0 .. symName.len - 1];
                        }
                        const fnVal = env.lookup(symName) orelse self.rootEnv.lookup(symName);
                        if (fnVal != null and fnVal.?.type == .closure) {
                            const argCount = if (items.len > 1) items.len - 1 else 0;
                            const argExprs = try self.allocator.alloc(Expr, argCount);
                            defer self.allocator.free(argExprs);
                            var ci: usize = 0;
                            while (ci < items.len - 1) {
                                argExprs[ci] = items[ci + 1];
                                ci += 1;
                            }
                            const result = try self._applyClosure(fnVal.?.value.closure, argExprs, env);
                            self.push(result);
                            return result;
                        }
                    },
                    else => {},
                }

                // Push all args
                var ai: usize = 1;
                while (ai < items.len) {
                    const arg = try self.eval(items[ai], env);
                    self.push(arg);
                    ai += 1;
                }
                
                if (clean.len >= 1 and clean[0] == '+') {
                    const b = self.pop() orelse return blk: {
                        const obj = try self.allocator.create(LispObject);
                        obj.* = LispObject.nilObj();
                        break :blk obj;
                    };
                    const a = self.pop() orelse return blk: {
                        const obj = try self.allocator.create(LispObject);
                        obj.* = LispObject.nilObj();
                        break :blk obj;
                    };
                    if (a.type != .number or b.type != .number) {
                        const obj = try self.allocator.create(LispObject);
                        obj.* = LispObject.nilObj();
                        return obj;
                    }
                    const result = try self.allocator.create(LispObject);
                    result.* = LispObject.numberObj(a.value.number + b.value.number);
                    self.push(result);
                    return result;
                }
                if (clean.len >= 1 and clean[0] == '-') {
                    const b = self.pop() orelse return blk: {
                        const obj = try self.allocator.create(LispObject);
                        obj.* = LispObject.nilObj();
                        break :blk obj;
                    };
                    const a = self.pop() orelse return blk: {
                        const obj = try self.allocator.create(LispObject);
                        obj.* = LispObject.nilObj();
                        break :blk obj;
                    };
                    if (a.type != .number or b.type != .number) {
                        const obj = try self.allocator.create(LispObject);
                        obj.* = LispObject.nilObj();
                        return obj;
                    }
                    const result = try self.allocator.create(LispObject);
                    result.* = LispObject.numberObj(a.value.number - b.value.number);
                    self.push(result);
                    return result;
                }
                if (clean.len >= 1 and clean[0] == '*') {
                    const b = self.pop() orelse return blk: {
                        const obj = try self.allocator.create(LispObject);
                        obj.* = LispObject.nilObj();
                        break :blk obj;
                    };
                    const a = self.pop() orelse return blk: {
                        const obj = try self.allocator.create(LispObject);
                        obj.* = LispObject.nilObj();
                        break :blk obj;
                    };
                    if (a.type != .number or b.type != .number) {
                        const obj = try self.allocator.create(LispObject);
                        obj.* = LispObject.nilObj();
                        return obj;
                    }
                    const result = try self.allocator.create(LispObject);
                    result.* = LispObject.numberObj(a.value.number * b.value.number);
                    self.push(result);
                    return result;
                }

                const obj = try self.allocator.create(LispObject);
                obj.* = LispObject.nilObj();
                return obj;
            },
        }
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
// Phase 7 Tests: fn, defn, closure application
// ============================================================

test "evalFn — creates closure object" {
    const alloc = std.heap.page_allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var symtab = SymbolTable.init(alloc, &arena);
    _ = try symtab.getOrPut("fn");
    _ = try symtab.getOrPut("x");
    var env = Environment.init(null, alloc);
    defer env.deinit();
    var vm = Vm.init(alloc, &env);
    defer vm.deinit();

    const fnSym = try symtab.getOrPut("fn");
    const xSym = try symtab.getOrPut("x");

    // (fn (x) x)
    const paramsList: []Expr = try alloc.dupe(Expr, &[1]Expr{ Expr{ .symbol = xSym } });
    defer alloc.free(paramsList);
    const bodyList: []Expr = try alloc.dupe(Expr, &[1]Expr{ Expr{ .symbol = xSym } });
    defer alloc.free(bodyList);
    const items: []Expr = try alloc.dupe(Expr, &[3]Expr{
        Expr{ .symbol = fnSym },
        Expr{ .list = paramsList },
        Expr{ .list = bodyList },
    });
    defer alloc.free(items);

    const result = try vm.evalFn(items, &env);
    try std.testing.expectEqual(ObjType.closure, result.type);
    alloc.destroy(result);
}

test "evalDefn — creates def + fn binding" {
    const alloc = std.heap.page_allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var symtab = SymbolTable.init(alloc, &arena);
    _ = try symtab.getOrPut("defn");
    _ = try symtab.getOrPut("myfunc");
    _ = try symtab.getOrPut("x");
    var env = Environment.init(null, alloc);
    defer env.deinit();
    var vm = Vm.init(alloc, &env);
    defer vm.deinit();

    const defnSym = try symtab.getOrPut("defn");
    const funcSym = try symtab.getOrPut("myfunc");
    const xSym = try symtab.getOrPut("x");

    // (defn myfunc (x) x)
    const paramsList: []Expr = try alloc.dupe(Expr, &[1]Expr{ Expr{ .symbol = xSym } });
    defer alloc.free(paramsList);
    const bodyList: []Expr = try alloc.dupe(Expr, &[1]Expr{ Expr{ .symbol = xSym } });
    defer alloc.free(bodyList);
    const items: []Expr = try alloc.dupe(Expr, &[4]Expr{
        Expr{ .symbol = defnSym },
        Expr{ .symbol = funcSym },
        Expr{ .list = paramsList },
        Expr{ .list = bodyList },
    });
    defer alloc.free(items);

    const result = try vm.evalDefn(items, &env);
    try std.testing.expectEqual(ObjType.closure, result.type);
    alloc.destroy(result);
}

test "closure — apply simple closure" {
    const alloc = std.heap.page_allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var symtab = SymbolTable.init(alloc, &arena);
    const xSym = try symtab.getOrPut("x");
    var env = Environment.init(null, alloc);
    defer env.deinit();
    var vm = Vm.init(alloc, &env);
    defer vm.deinit();

    // Build body expression: x
    const bodyArr: []Expr = try alloc.dupe(Expr, &[1]Expr{ Expr{ .symbol = xSym } });
    defer alloc.free(bodyArr);

    // Build param array: [xSym]
    const paramArr = try alloc.alloc(*Symbol, 1);
    defer alloc.free(paramArr);
    paramArr[0] = xSym;

    // Create closure manually
    const closure = try alloc.create(Closure);
    closure.* = Closure{
        .params = paramArr,
        .body = bodyArr,
        .env = &env,
    };

    // Create arg: 42
    const argVal = try alloc.create(LispObject);
    argVal.* = LispObject.numberObj(42);

    // Create child environment with closure's env as parent
    const childArena = try alloc.create(std.heap.ArenaAllocator);
    childArena.* = std.heap.ArenaAllocator.init(alloc);
    const childEnv = try alloc.create(Environment);
    childEnv.* = Environment.init(&env, childArena.allocator());
    try childEnv.bind(xSym.name, argVal);

    // Evaluate body: x -> should find 42 in childEnv
    const bodyExpr = bodyArr[0];
    const bodyExprResult = try vm.eval(bodyExpr, childEnv);
    try std.testing.expectEqual(@as(i64, 42), bodyExprResult.value.number);
    alloc.destroy(bodyExprResult);

    childEnv.deinit();
    alloc.destroy(childEnv);
    childArena.deinit();
    alloc.destroy(closure);
    alloc.destroy(argVal);
}


test "closure — apply closure with computation" {
    const alloc = std.heap.page_allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var symtab = SymbolTable.init(alloc, &arena);
    _ = try symtab.getOrPut("fn");
    _ = try symtab.getOrPut("x");
    _ = try symtab.getOrPut("+");
    var env = Environment.init(null, alloc);
    defer env.deinit();
    var vm = Vm.init(alloc, &env);
    defer vm.deinit();

    const fnSym = try symtab.getOrPut("fn");
    const xSym = try symtab.getOrPut("x");
    const plusSym = try symtab.getOrPut("+");

    // (fn (x) (+ x x)) — double
    const paramsList: []Expr = try alloc.dupe(Expr, &[1]Expr{ Expr{ .symbol = xSym } });
    defer alloc.free(paramsList);

    const bodyExpr: []Expr = try alloc.dupe(Expr, &[3]Expr{
        Expr{ .symbol = plusSym },
        Expr{ .symbol = xSym },
        Expr{ .symbol = xSym },
    });
    defer alloc.free(bodyExpr);

    const fnItems: []Expr = try alloc.dupe(Expr, &[3]Expr{
        Expr{ .symbol = fnSym },
        Expr{ .list = paramsList },
        Expr{ .list = bodyExpr },
    });
    defer alloc.free(fnItems);

    const closureObj = try vm.evalFn(fnItems, &env);
    try std.testing.expectEqual(ObjType.closure, closureObj.type);

    // Apply to 21: should return 42
    const argsExpr: []Expr = try alloc.dupe(Expr, &[1]Expr{ Expr{ .number = 21 } });
    defer alloc.free(argsExpr);
    const result = try vm.applyClosure(closureObj.value.closure, argsExpr, &env);
    try std.testing.expectEqual(@as(i64, 42), result.value.number);
    alloc.destroy(result);
    alloc.destroy(closureObj);
}

// ============================================================
// Phase 6 Tests: if, cond, do
// ============================================================

test "eval — if with true branch" {
    const alloc = std.heap.page_allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var symtab = SymbolTable.init(alloc, &arena);
    _ = try symtab.getOrPut("if");
    var env = Environment.init(null, alloc);
    defer env.deinit();
    var vm = Vm.init(alloc, &env);
    defer vm.deinit();

    const ifSym = try symtab.getOrPut("if");
    const items: []Expr = try alloc.dupe(Expr, &[4]Expr{
        Expr{ .symbol = ifSym },
        Expr{ .number = 1 },       // test (truthy)
        Expr{ .number = 42 },       // then
        Expr{ .number = 99 },       // else
    });
    defer alloc.free(items);

    const result = try vm.eval(Expr{ .list = items }, &env);
    try std.testing.expectEqual(@as(i64, 42), result.value.number);
    alloc.destroy(result);
}

test "eval — if with false branch" {
    const alloc = std.heap.page_allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var symtab = SymbolTable.init(alloc, &arena);
    _ = try symtab.getOrPut("if");
    var env = Environment.init(null, alloc);
    defer env.deinit();
    var vm = Vm.init(alloc, &env);
    defer vm.deinit();

    const ifSym = try symtab.getOrPut("if");
    const items: []Expr = try alloc.dupe(Expr, &[4]Expr{
        Expr{ .symbol = ifSym },
        Expr{ .nil = {} },          // test (nil/falsy)
        Expr{ .number = 42 },       // then
        Expr{ .number = 99 },       // else
    });
    defer alloc.free(items);

    const result = try vm.eval(Expr{ .list = items }, &env);
    try std.testing.expectEqual(@as(i64, 99), result.value.number);
    alloc.destroy(result);
}

test "eval — if without else" {
    const alloc = std.heap.page_allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var symtab = SymbolTable.init(alloc, &arena);
    _ = try symtab.getOrPut("if");
    var env = Environment.init(null, alloc);
    defer env.deinit();
    var vm = Vm.init(alloc, &env);
    defer vm.deinit();

    const ifSym = try symtab.getOrPut("if");
    const items: []Expr = try alloc.dupe(Expr, &[3]Expr{
        Expr{ .symbol = ifSym },
        Expr{ .nil = {} },          // test (nil)
        Expr{ .number = 42 },       // then (not evaluated since test is nil)
    });
    defer alloc.free(items);

    const result = try vm.eval(Expr{ .list = items }, &env);
    try std.testing.expectEqual(ObjType.nil, result.type);
    alloc.destroy(result);
}

test "eval — do returns last value" {
    const alloc = std.heap.page_allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var symtab = SymbolTable.init(alloc, &arena);
    _ = try symtab.getOrPut("do");
    var env = Environment.init(null, alloc);
    defer env.deinit();
    var vm = Vm.init(alloc, &env);
    defer vm.deinit();

    const doSym = try symtab.getOrPut("do");
    const items: []Expr = try alloc.dupe(Expr, &[4]Expr{
        Expr{ .symbol = doSym },
        Expr{ .number = 1 },
        Expr{ .number = 2 },
        Expr{ .number = 3 },
    });
    defer alloc.free(items);

    const result = try vm.eval(Expr{ .list = items }, &env);
    try std.testing.expectEqual(@as(i64, 3), result.value.number);
    alloc.destroy(result);
}

test "eval — cond first branch matches" {
    const alloc = std.heap.page_allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var symtab = SymbolTable.init(alloc, &arena);
    _ = try symtab.getOrPut("cond");
    var env = Environment.init(null, alloc);
    defer env.deinit();
    var vm = Vm.init(alloc, &env);
    defer vm.deinit();

    const condSym = try symtab.getOrPut("cond");
    const items: []Expr = try alloc.dupe(Expr, &[6]Expr{
        Expr{ .symbol = condSym },
        Expr{ .nil = {} },         // test 1: nil (skip)
        Expr{ .number = 111 },     // then 1
        Expr{ .number = 1 },       // test 2: truthy
        Expr{ .number = 222 },     // then 2
        Expr{ .number = 999 },     // then 3 (not reached)
    });
    defer alloc.free(items);

    const result = try vm.eval(Expr{ .list = items }, &env);
    try std.testing.expectEqual(@as(i64, 222), result.value.number);
    alloc.destroy(result);
}

test "eval — cond no branch matches returns nil" {
    const alloc = std.heap.page_allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var symtab = SymbolTable.init(alloc, &arena);
    _ = try symtab.getOrPut("cond");
    var env = Environment.init(null, alloc);
    defer env.deinit();
    var vm = Vm.init(alloc, &env);
    defer vm.deinit();

    const condSym = try symtab.getOrPut("cond");
    const items: []Expr = try alloc.dupe(Expr, &[4]Expr{
        Expr{ .symbol = condSym },
        Expr{ .nil = {} },         // test 1: nil (skip)
        Expr{ .number = 100 },     // then 1
        Expr{ .nil = {} },         // test 2: nil (skip)
    });
    defer alloc.free(items);

    const result = try vm.eval(Expr{ .list = items }, &env);
    try std.testing.expectEqual(ObjType.nil, result.type);
    alloc.destroy(result);
}

// ============================================================
// Phase 5 Tests: def, eval
// ============================================================

test "evalAtom — number returns number object" {
    const alloc = std.heap.page_allocator;
    var env = Environment.init(null, alloc);
    defer env.deinit();
    var vm = Vm.init(alloc, &env);
    defer vm.deinit();
    const result = try vm.evalAtom(Expr{ .number = 42 }, &env);
    try std.testing.expectEqual(@as(i64, 42), result.value.number);
    alloc.destroy(result);
}

test "evalAtom — nil returns nil object" {
    const alloc = std.heap.page_allocator;
    var env = Environment.init(null, alloc);
    defer env.deinit();
    var vm = Vm.init(alloc, &env);
    defer vm.deinit();
    const result = try vm.evalAtom(Expr{ .nil = {} }, &env);
    try std.testing.expectEqual(ObjType.nil, result.type);
    alloc.destroy(result);
}

test "def — bind value in root env" {
    const alloc = std.heap.page_allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var symtab = SymbolTable.init(alloc, &arena);
    _ = try symtab.getOrPut("def");
    _ = try symtab.getOrPut("x");
    var env = Environment.init(null, alloc);
    defer env.deinit();
    var vm = Vm.init(alloc, &env);
    defer vm.deinit();

    const defSym = try symtab.getOrPut("def");
    const xSym = try symtab.getOrPut("x");
    const items: []Expr = try alloc.dupe(Expr, &[3]Expr{
        Expr{ .symbol = defSym },
        Expr{ .symbol = xSym },
        Expr{ .number = 42 },
    });
    defer alloc.free(items);

    const result = try vm.evalDef(items);
    try std.testing.expectEqual(@as(i64, 42), result.value.number);
    alloc.destroy(result);
}

test "def — lookup bound value" {
    const alloc = std.heap.page_allocator;
    var env = Environment.init(null, alloc);
    defer env.deinit();
    const val_obj = alloc.create(LispObject) catch unreachable;
    val_obj.* = LispObject.numberObj(42);
    try env.bind("x", val_obj);
    const val = env.lookup("x");
    try std.testing.expect(val != null);
    try std.testing.expectEqual(@as(i64, 42), val.?.value.number);
    alloc.destroy(val_obj);
}

test "eval — number literal" {
    const alloc = std.heap.page_allocator;
    var env = Environment.init(null, alloc);
    defer env.deinit();
    var vm = Vm.init(alloc, &env);
    defer vm.deinit();
    const result = try vm.eval(Expr{ .number = 42 }, &env);
    try std.testing.expectEqual(@as(i64, 42), result.value.number);
    alloc.destroy(result);
}

test "eval — + primitive call (a + b)" {
    const alloc = std.heap.page_allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var symtab = SymbolTable.init(alloc, &arena);
    _ = try symtab.getOrPut("+");
    var env = Environment.init(null, alloc);
    defer env.deinit();
    var vm = Vm.init(alloc, &env);
    defer vm.deinit();

    const plusSym = try symtab.getOrPut("+");
    const items: []Expr = try alloc.dupe(Expr, &[3]Expr{
        Expr{ .symbol = plusSym },
        Expr{ .number = 2 },
        Expr{ .number = 3 },
    });

    const result = try vm.eval(Expr{ .list = items }, &env);
    try std.testing.expectEqual(@as(i64, 5), result.value.number);
    alloc.destroy(result);
    alloc.free(items);
}

test "eval — nested + call" {
    const alloc = std.heap.page_allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var symtab = SymbolTable.init(alloc, &arena);
    _ = try symtab.getOrPut("+");
    var env = Environment.init(null, alloc);
    defer env.deinit();
    var vm = Vm.init(alloc, &env);
    defer vm.deinit();

    const plusSym = try symtab.getOrPut("+");
    const inner: []Expr = try alloc.dupe(Expr, &[3]Expr{
        Expr{ .symbol = plusSym },
        Expr{ .number = 1 },
        Expr{ .number = 2 },
    });
    const outer: []Expr = try alloc.dupe(Expr, &[3]Expr{
        Expr{ .symbol = plusSym },
        Expr{ .list = inner },
        Expr{ .number = 3 },
    });

    const result = try vm.eval(Expr{ .list = outer }, &env);
    try std.testing.expectEqual(@as(i64, 6), result.value.number);
    alloc.destroy(result);
    alloc.free(inner);
    alloc.free(outer);
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
