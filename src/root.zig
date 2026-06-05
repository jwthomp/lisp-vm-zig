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
        // Semicolons start comments — skip and continue
        if (c == ';') {
            self.pos += 1;
            self.skipComment();
            return self.nextToken();
        }
        // Single quote is the quote character
        if (c == 39) {
            self.pos += 1;
            return .quote;
        }
        // Numbers
        if (std.ascii.isDigit(c)) {
            self.pos += 1;
            while (self.pos < self.input.len and std.ascii.isDigit(self.input[self.pos])) {
                self.pos += 1;
            }
            return .number;
        }
        // Symbols — letters, digits, and Lisp special chars
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
        _ = tok;
        return Expr.nilExpr();
    }
};

// ============================================================
// Tests
// ============================================================

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
    // (+ - * / = < > _ ! ? $)
    // Tokens: ( + - * / = < > _ ! ? $ ) = 13 tokens
    var lexer = Lexer.init("(+ - * / = < > _ ! ? $)");
    try std.testing.expectEqual(.left_paren, lexer.nextToken());  // 1: (
    try std.testing.expectEqual(.symbol, lexer.nextToken());      // 2: +
    try std.testing.expectEqual(.symbol, lexer.nextToken());      // 3: -
    try std.testing.expectEqual(.symbol, lexer.nextToken());      // 4: *
    try std.testing.expectEqual(.symbol, lexer.nextToken());      // 5: /
    try std.testing.expectEqual(.symbol, lexer.nextToken());      // 6: =
    try std.testing.expectEqual(.symbol, lexer.nextToken());      // 7: <
    try std.testing.expectEqual(.symbol, lexer.nextToken());      // 8: >
    try std.testing.expectEqual(.symbol, lexer.nextToken());      // 9: _
    try std.testing.expectEqual(.symbol, lexer.nextToken());      // 10: !
    try std.testing.expectEqual(.symbol, lexer.nextToken());      // 11: ?
    try std.testing.expectEqual(.symbol, lexer.nextToken());      // 12: $
    try std.testing.expectEqual(.right_paren, lexer.nextToken()); // 13: )
}

test "lexer whitespace and comments" {
    var lexer = Lexer.init("  ( + \n  ; comment\n  1  )  ");
    try std.testing.expectEqual(.left_paren, lexer.nextToken());
    try std.testing.expectEqual(.symbol, lexer.nextToken());
    try std.testing.expectEqual(.number, lexer.nextToken());
    try std.testing.expectEqual(.right_paren, lexer.nextToken());
}

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

test "symbol table — intern 5 symbols, all unique except duplicates" {
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
