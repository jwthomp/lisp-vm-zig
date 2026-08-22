const std = @import("std");
const posix = std.posix;
const os = std.os;
const Allocator = std.mem.Allocator;

// ============================================================
// Debug print helper — guards std.debug.print in test mode
// std.debug.print crashes in Zig 0.16 test binaries (SIGABRT).
// ============================================================
pub fn debugPrint(comptime fmt: []const u8, args: anytype) void {
    if (@import("builtin").is_test) return;
    std.debug.print(fmt, args);
}

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
    str_lit,
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
    current_text: []const u8 = "",
    pos: usize,

    pub fn init(input: []const u8) Lexer {
        return Lexer{ .input = input, .current_text = "", .pos = 0 };
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
        switch (c) {
            '(' => {
                self.pos += 1;
                return .left_paren;
            },
            ')' => {
                self.pos += 1;
                return .right_paren;
            },
            '[' => {
                self.pos += 1;
                return .left_paren;
            },
            ']' => {
                self.pos += 1;
                return .right_paren;
            },
            else => {},
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
            const num_start = self.pos;
            self.pos += 1;
            while (self.pos < self.input.len and std.ascii.isDigit(self.input[self.pos])) {
                self.pos += 1;
            }
            self.current_text = self.input[num_start..self.pos];
            return .number;
        }
        if (c == '"') {
            self.pos += 1;
            const str_start = self.pos;
            var escaped: bool = false;
            while (self.pos < self.input.len) {
                const ch = self.input[self.pos];
                if (escaped) {
                    escaped = false;
                    self.pos += 1;
                    continue;
                }
                if (ch == '"') {
                    break;
                }
                if (ch == '\\') {
                    escaped = true;
                }
                self.pos += 1;
            }
            self.current_text = self.input[str_start..self.pos];
            self.pos += 1;
            return .str_lit;
        }
        if (std.ascii.isAlphabetic(c) or c == '+' or c == '-' or c == '*' or c == '/' or
            c == '=' or c == '<' or c == '>' or c == '_' or c == '!' or c == '?' or c == '$' or
            c == '.')
        {
            const sym_start = self.pos;
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
            self.current_text = self.input[sym_start..self.pos];
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
    string: []const u8,
    nil,

    pub fn nilExpr() Expr { return Expr{ .nil = {} }; }
};

// ============================================================
// Parser
// ============================================================

pub const Parser = struct {
    tokens: []Token,
    token_texts: []const u8,
    pos: usize,
    arena: *std.heap.ArenaAllocator,
    symtab: *SymbolTable,

    pub fn init(tokens: []Token, texts: []const u8, arena: *std.heap.ArenaAllocator, symtab: *SymbolTable) Parser {
        return Parser{ .tokens = tokens, .token_texts = texts, .pos = 0, .arena = arena, .symtab = symtab };
    }

    pub fn parse(self: *Parser) !Expr {
        return self.parseSExpr(0) catch {
            return Expr.nilExpr();
        };
    }

    pub fn parseSExpr(self: *Parser, depth: usize) !Expr {
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
            .quote => {
                self.pos += 1;
                // 'expr → (quote expr)
                const inner = self.parseSExpr(depth + 1) catch {
                    return Expr.nilExpr();
                };
                const quote_items: []Expr = try self.arena.allocator().dupe(
                    Expr, &[2]Expr{
                        Expr{ .symbol = try self.symtab.getOrPut("quote") },
                        inner,
                    },
                );
                return Expr{ .list = quote_items };
            },
            else => {
                self.pos += 1;
                return self.parseAtom();
            },
        };
    }

    pub fn parseAtom(self: *Parser) !Expr {
        const tok = self.tokens[self.pos - 1];
        const text = self._getTokenText();
        return switch (tok) {
            .number => blk: {
                var n: i64 = 0;
                var sign: i64 = 1;
                var s: []const u8 = text;
                if (s.len > 0 and s[0] == '-') {
                    sign = -1;
                    s = s[1..];
                }
                for (s) |c| {
                    if (c >= '0' and c <= '9') n = n * 10 + @as(i64, c - '0');
                }
                break :blk Expr{ .number = sign * n };
            },
            .symbol => blk: {
                const sym = try self.symtab.getOrPut(text);
                break :blk Expr{ .symbol = sym };
            },
            .str_lit => blk: {
                break :blk Expr{ .string = try self.arena.allocator().dupe(u8, text) };
            },
            else => Expr.nilExpr(),
        };
    }

    /// Get the text for the token at index i.
    /// token_texts contains null-separated strings.
    pub fn _getTokenText(self: *Parser) []const u8 {
        // Walk through token_texts to find the text for token at self.pos - 1
        var idx: usize = 0;
        const target_idx: usize = self.pos - 1;
        var count: usize = 0;
        while (idx < self.token_texts.len) {
            // Each token text is null-terminated
            var end = idx;
            while (end < self.token_texts.len and self.token_texts[end] != 0) {
                end += 1;
            }
            if (count == target_idx) {
                return self.token_texts[idx..end];
            }
            count += 1;
            idx = end + 1; // skip NUL
        }
        return "";
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
    err,
    string,
};

pub const LispObject = struct {
    type: ObjType,
    value: ValueUnion,
    next: ?*LispObject,
    marked: bool,

    const ValueUnion = union(ObjType) {
        nil: void,
        symbol: *Symbol,
        number: i64,
        cons: *ConsCell,
        closure: *Closure,
        builtin: []const u8,
        err: []const u8,
        string: []const u8,
    };

    pub fn nilObj() LispObject {
        return LispObject{ .type = .nil, .value = .{ .nil = {} }, .next = null, .marked = false };
    }

    pub fn symbolObj(sym: *Symbol) LispObject {
        return LispObject{ .type = .symbol, .value = .{ .symbol = sym }, .next = null, .marked = false };
    }

    pub fn numberObj(n: i64) LispObject {
        return LispObject{ .type = .number, .value = .{ .number = n }, .next = null, .marked = false };
    }

    pub fn errorObj(msg: []const u8) LispObject {
        return LispObject{ .type = .err, .value = .{ .err = msg }, .next = null, .marked = false };
    }

    pub fn stringObj(s: []const u8) LispObject {
        return LispObject{ .type = .string, .value = .{ .string = s }, .next = null, .marked = false };
    }
};

// ============================================================
// Bytecode Compiler & Interpreter


pub const BuiltinKind = enum {
    add, sub, mul, div, eq, lt, gt, le, ge, rem,
    // Bitwise
    bit_and, bit_or, bit_not, bit_shl, bit_shr,
    cons, car, cdr,
    print,
    null, symbol, number, list, not,
    length,
    append, reverse, member, assoc, map, filter,
    println, load, import,
    // Predicates
    equal, even, odd, positive, negative, type_of,
    str, str_cat, str_len, str_eq, substr,
    // IO
    read_line, writeln,
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
    is_macro: bool,
};

// ============================================================
// Environment (Phase 3)
// ============================================================

pub const Environment = struct {
    parent: ?*Environment,
    arena: std.heap.ArenaAllocator,
    allocator: Allocator,
    bindings: std.StringHashMap(*LispObject),

    pub fn init(parent: ?*Environment, allocator: Allocator) Environment {
        return Environment{
            .parent = parent,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .allocator = allocator,
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
        const key = try self.allocator.dupeZ(u8, name);
        errdefer self.allocator.free(key);
        try self.bindings.put(key, val);
        
    }

    /// Create a child environment with one binding.
    pub fn child(self: *Environment, allocator: Allocator) Environment {
        return Environment.init(self, allocator);
    }
};

