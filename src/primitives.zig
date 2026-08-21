// Primitives module — Vm struct with all methods plus Opcode and Bytecode
// Token/Lexer/etc. are imported as needed

const std = @import("std");
const posix = std.posix;
const os = std.os;
const types = @import("types.zig");

// Type aliases from types.zig (only for types used in bytecode/vm methods)
const Allocator = std.mem.Allocator;
const Expr = types.Expr;
const Parser = types.Parser;
const Environment = types.Environment;
const LispObject = types.LispObject;
const ConsCell = types.ConsCell;
const Closure = types.Closure;
const Symbol = types.Symbol;
const Lexer = types.Lexer;
const Token = types.Token;
const SymbolTable = types.SymbolTable;
const debugPrint = types.debugPrint;
const BuiltinKind = types.BuiltinKind;

// ============================================================

/// Bytecode instructions
pub const Opcode = enum(u8) {
    // Constants
    nil,           // push nil
    number,        // push number (next 8 bytes = i64)
    symbol,        // push symbol value from env (next 4 bytes = u32 index into constants)
    const_val,     // push constant value (next 4 bytes = u32 index into constants)

    // Control flow
    jump,          // unconditional jump (next 4 bytes = u32 offset)
    jump_if_false, // conditional jump (next 4 bytes = u32 offset)

    // Special forms
    def,           // define variable (next 4 bytes = u32 index into constants)
    defn,          // define function (next 4 bytes = u32 index into constants)
    let,           // let bindings (next 4 bytes = u32 index into constants)
    iff,           // conditional (next 4 bytes = u32 offset for else/nil branch)
    quote,         // quote (next 4 bytes = u32 index into constants)
    do,            // do block (next 4 bytes = u32 count of expressions)

    // Function calls
    call,          // call function with N args (next 1 byte = u8 count)
    tailcall,      // tail call with N args (next 1 byte = u8 count)

    // Stack ops
    pop,           // pop top of stack
    dup,           // duplicate top of stack
};

/// A compiled bytecode program
pub const Bytecode = struct {
    ops: std.ArrayList(u8),
    constants: std.ArrayList(*LispObject),
    closure_bodies: std.ArrayList(std.ArrayList(u8)),
    allocator: Allocator,

    pub fn init(allocator: Allocator) !Bytecode {
        return Bytecode{
            .ops = try std.ArrayList(u8).initCapacity(allocator, 64),
            .constants = try std.ArrayList(*LispObject).initCapacity(allocator, 16),
            .closure_bodies = try std.ArrayList(std.ArrayList(u8)).initCapacity(allocator, 4),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Bytecode) void {
        var i: usize = 0;
        while (i < self.closure_bodies.items.len) : (i += 1) {
            self.closure_bodies.items[i].deinit(self.allocator);
        }
        self.closure_bodies.deinit(self.allocator);
        self.ops.deinit(self.allocator);
        self.constants.deinit(self.allocator);
    }

    /// Clear all bytecode data, retaining allocated capacity for reuse.
    pub fn clear(self: *Bytecode) void {
        var i: usize = 0;
        while (i < self.closure_bodies.items.len) : (i += 1) {
            self.closure_bodies.items[i].clearRetainingCapacity();
        }
        self.closure_bodies.clearRetainingCapacity();
        self.ops.clearRetainingCapacity();
        self.constants.clearRetainingCapacity();
    }

    /// Emit a single opcode byte
    fn emitOp(self: *Bytecode, op: Opcode) !void {
        try self.ops.append(self.allocator, @intFromEnum(op));
    }

    /// Emit an operand (u32, little-endian)
    fn emitU32(self: *Bytecode, val: u32) !void {
        var v = val;
        var i: usize = 0;
        while (i < 4) : (i += 1) {
            try self.ops.append(self.allocator, @as(u8, @intCast(v & 0xFF)));
            v >>= 8;
        }
    }

    /// Emit an operand (i64, little-endian)
    fn emitI64(self: *Bytecode, val: i64) !void {
        var v = val;
        var i: usize = 0;
        while (i < 8) : (i += 1) {
            try self.ops.append(self.allocator, @as(u8, @intCast(v & 0xFF)));
            v >>= 8;
        }
    }

    /// Emit a nil opcode
    pub fn emitNil(self: *Bytecode) !void {
        try self.emitOp(.nil);
    }

    /// Emit a number opcode
pub fn emitNumber(self: *Bytecode, n: i64) !void {
    try self.emitOp(.number);
try self.emitI64(n);
}

/// Emit a symbol lookup opcode (index into constants)
fn emitSymbol(self: *Bytecode, index: u32) !void {
    try self.emitOp(.symbol);
try self.emitU32(index);
}

/// Emit a constant value opcode (index into constants)
fn emitConstVal(self: *Bytecode, index: u32) !void {
    try self.emitOp(.const_val);
try self.emitU32(index);
}

/// Add a symbol to constants and return its index
pub fn emitConstRef(self: *Bytecode, sym: *Symbol) !u32 {
        const idx = @as(u32, @intCast(self.constants.items.len));
        debugPrint("emitConstRef: creating symbol object for '{s}'\n", .{sym.name[0..]});
        const obj = try self.allocator.create(LispObject);
        obj.* = LispObject.symbolObj(sym);
        debugPrint("emitConstRef: appending to constants, len before={d}, len after={d}\n", .{ idx, idx + 1 });
        self.constants.appendAssumeCapacity(obj);
        debugPrint("emitConstRef: constants.items.len = {d}\n", .{self.constants.items.len});
        return idx;
    }

    /// Emit a jump opcode (placeholder, filled later)
    pub fn emitJump(self: *Bytecode) !u32 {
        try self.emitOp(.jump);
        const offset = @as(u32, @intCast(self.ops.items.len));
        try self.emitU32(0); // placeholder
        return offset;
    }

    /// Emit a conditional jump opcode
    pub fn emitJumpIfFalse(self: *Bytecode) !u32 {
        try self.emitOp(.jump_if_false);
        const offset = @as(u32, @intCast(self.ops.items.len));
        try self.emitU32(0); // placeholder
        return offset;
    }

    /// Patch a jump offset
    pub fn patchJump(self: *Bytecode, offset: usize, target: usize) void {
        var i: u8 = 0;
        while (i < 4) : (i += 1) {
            const shift: u6 = @intCast(i * 8);
            self.ops.items[offset + i] = @as(u8, @intCast((target >> shift) & 0xFF));
        }
    }

    /// Emit a def opcode
    pub fn emitDef(self: *Bytecode, index: u32) !void {
        try self.emitOp(.def);
        try self.emitU32(index);
    }

    /// Emit a defn opcode
    pub fn emitDefn(self: *Bytecode, index: u32) !void {
        try self.emitOp(.defn);
        try self.emitU32(index);
    }

    /// Emit a let opcode (startIdx, count)
    pub fn emitLet(self: *Bytecode, startIdx: u32, count: u32) !void {
        try self.emitOp(.let);
        try self.emitU32(startIdx);
        try self.emitU32(count);
    }

    /// Emit an if opcode
    pub fn emitIf(self: *Bytecode, elseOffset: u32) !void {
        try self.emitOp(.iff);
        try self.emitU32(elseOffset);
    }

    /// Emit a quote opcode
    pub fn emitQuote(self: *Bytecode, index: u32) !void {
        try self.emitOp(.quote);
        try self.emitU32(index);
    }

    /// Emit a do opcode
    pub fn emitDo(self: *Bytecode, count: u32) !void {
        try self.emitOp(.do);
        try self.emitU32(count);
    }

    /// Emit a call opcode
    pub fn emitCall(self: *Bytecode, argCount: u8) !void {
        try self.emitOp(.call);
        self.ops.appendAssumeCapacity(argCount);
    }

    /// Emit a tailcall opcode
    pub fn emitTailcall(self: *Bytecode, argCount: u8) !void {
        try self.emitOp(.tailcall);
        self.ops.appendAssumeCapacity(argCount);
    }

    /// Emit a pop opcode
    pub fn emitPop(self: *Bytecode) !void {
        try self.emitOp(.pop);
    }

    /// Emit a dup opcode
    pub fn emitDup(self: *Bytecode) !void {
        try self.emitOp(.dup);
    }

    /// Add a constant and return its index
    fn addConstant(self: *Bytecode, val: *LispObject) u32 {
        const idx = @as(u32, @intCast(self.constants.items.len));
        self.constants.appendAssumeCapacity(val);
        return idx;
    }

    /// Get constant by index
    fn getConstant(self: *Bytecode, idx: u32) ?*LispObject {
        if (idx < self.constants.items.len) return self.constants.items[idx];
        return null;
    }

    /// Compile an expression to bytecode
    pub fn compileExpr(self: *Bytecode, expr: Expr, env: *Environment, vm: *Vm) anyerror!void {
        switch (expr) {
            .nil => {
                try self.emitNil();
            },
            .number => |n| {
                try self.emitNumber(n);
            },
            .symbol => |sym| {
                // Check if it's a special form
                var clean: []const u8 = sym.name[0..];
                while (clean.len > 0 and clean[clean.len - 1] == 0) clean = clean[0 .. clean.len - 1];

                if (std.mem.eql(u8, clean, "nil")) {
                    try self.emitNil();
                } else {
                    // Regular symbol lookup — add to bytecode constants
                    try self.emitSymbol(try self.emitConstRef(sym));
                }
            },
            .string => |s| {
                const idx = try vm._addConstantStr(s);
                try self.emitConstVal(idx);
            },
            .list => |items| {
                if (items.len == 0) {
                    try self.emitNil();
                    return;
                }

                const head = items[0];
                const headName = switch (head) {
                    .symbol => |sym| sym.name,
                    else => "",
                };
                var clean: []const u8 = headName[0..];
                while (clean.len > 0 and clean[clean.len - 1] == 0) clean = clean[0 .. clean.len - 1];

                // Special forms
                if (std.mem.eql(u8, clean, "if")) {
                    try self.compileIf(items, env, vm);
                } else if (std.mem.eql(u8, clean, "quote")) {
                    try self.compileQuote(items, vm);
                } else if (std.mem.eql(u8, clean, "def")) {
                    try self.compileDef(items, env, vm);
                } else if (std.mem.eql(u8, clean, "defn")) {
                    try self.compileDefn(items, env, vm);
                } else if (std.mem.eql(u8, clean, "let")) {
                    try self.compileLet(items, env, vm);
                } else if (std.mem.eql(u8, clean, "do")) {
                    try self.compileDo(items, env, vm);
                } else if (std.mem.eql(u8, clean, "fn")) {
                    // (fn (params) body...)
                    try self.compileFn(items[1], items[2..], env, vm);
                } else {
                    // Function call
                    try self.compileCall(items, env, vm);
                }
            },
        }
    }

    fn compileIf(self: *Bytecode, items: []Expr, env: *Environment, vm: *Vm) !void {
        // (if test then else?)
        try self.compileExpr(items[1], env, vm); // test
        const elseOffset = try self.emitJumpIfFalse();
        try self.compileExpr(items[2], env, vm); // then
        const endOffset = try self.emitJump();
        self.patchJump(elseOffset, self.ops.items.len);
        if (items.len > 3) {
            try self.compileExpr(items[3], env, vm); // else
        } else {
            try self.emitNil(); // implicit nil
        }
        self.patchJump(endOffset, self.ops.items.len);
    }

    fn compileQuote(self: *Bytecode, items: []Expr, vm: *Vm) !void {
        // (quote x) — push constant
        const idx = try vm._addConstantExpr(items[1]);
        try self.emitQuote(idx);
    }

    fn compileDef(self: *Bytecode, items: []Expr, env: *Environment, vm: *Vm) !void {
        // (def name value)
        if (items[1] == .symbol) {
            const nameIdx = try self.emitConstRef(items[1].symbol);
            try self.compileExpr(items[2], env, vm); // value
            try self.emitDef(nameIdx);
        }
    }

    fn compileDefn(self: *Bytecode, items: []Expr, env: *Environment, vm: *Vm) !void {
        debugPrint("compileDefn: entering, ops.len={d}\n", .{self.ops.items.len});
        // (defn name (params) body...)
        const nameIdx = try vm._addConstantExpr(items[1]);
        debugPrint("compileDefn: nameIdx={d}, ops.len={d}\n", .{nameIdx, self.ops.items.len});
        const paramsExpr = items[2];
        const bodyExprs = items[3..];
        try self.compileFn(paramsExpr, bodyExprs, env, vm);
        try self.emitDefn(nameIdx);
    }

    fn compileLet(self: *Bytecode, items: []Expr, env: *Environment, vm: *Vm) !void {
        // (let ((name val) ...) body...)
        const bindingsExpr = items[1];
        const bodyExprs = items[2..];

        // Capture current constant index before adding binding names
        const startIdx: u32 = if (bindingsExpr == .list) @intCast(self.constants.items.len) else 0;

        // Add binding symbol names to constants before compiling values
        // so the let handler can find them at known indices
        if (bindingsExpr == .list) {
            const listExpr = bindingsExpr.list;
            var i: usize = 0;
            while (i < listExpr.len) {
                if (listExpr[i] == .symbol) {
                    _ = try self.emitConstRef(listExpr[i].symbol);
                }
                i += 1;
            }
        }

        // Compile binding values and push them
        if (bindingsExpr == .list) {
            const listExpr = bindingsExpr.list;
            var i: usize = 0;
            while (i < listExpr.len) {
                try self.compileExpr(listExpr[i + 1], env, vm);
                i += 2;
            }
        }

        // Emit let opcode with starting constant index and count
        const bindingCount: u32 = if (bindingsExpr == .list) @intCast(bindingsExpr.list.len / 2) else 0;
        try self.emitLet(startIdx, bindingCount);

        // Compile body
        var i: usize = 0;
        while (i < bodyExprs.len) {
            try self.compileExpr(bodyExprs[i], env, vm);
            i += 1;
        }
    }

    fn compileDo(self: *Bytecode, items: []Expr, env: *Environment, vm: *Vm) !void {
        // (do expr ...)
        const count = if (items.len > 1) @as(u32, @intCast(items.len - 1)) else 0;
        try self.emitDo(count);
        var i: usize = 1;
        while (i < items.len) {
            try self.compileExpr(items[i], env, vm);
            i += 1;
        }
    }

    fn compileFn(self: *Bytecode, paramsExpr: Expr, bodyExprs: []Expr, env: *Environment, vm: *Vm) !void {
        // Compile body into a separate bytecode array

        // Note current position and body index
        const bodyStartIdx: u32 = @intCast(self.closure_bodies.items.len);
        const opsStart: usize = self.ops.items.len;

        // Compile each body expression into self.ops
        var i: usize = 0;
        while (i < bodyExprs.len) {
            try self.compileExpr(bodyExprs[i], env, vm);
            i += 1;
        }

        // Copy body bytes into closure_bodies, then truncate self.ops
        // so body opcodes don't execute inline in the main stream
        const bodyLen = self.ops.items.len - opsStart;
        const bodyBytes = try self.allocator.alloc(u8, bodyLen);
        @memcpy(bodyBytes, self.ops.items[opsStart..]);
        self.closure_bodies.appendAssumeCapacity(std.ArrayList(u8).fromOwnedSlice(bodyBytes));
        self.ops.shrinkRetainingCapacity(opsStart);

        // Create param name chain for closure
        var paramChain: ?*LispObject = null;
        if (paramsExpr == .list) {
            var pi: usize = paramsExpr.list.len;
            while (pi > 0) {
                pi -= 1;
                const param = paramsExpr.list[pi];
                if (param == .symbol) {
                    const paramObj = try self.allocator.create(LispObject);
                    vm.gcRegister(paramObj);
                    paramObj.* = LispObject.symbolObj(param.symbol);
                    paramObj.next = paramChain;
                    paramChain = paramObj;
                }
            }
        }

        // Create closure object: next -> bodyIdx, next.next -> paramChain
        const bodyIdxObj = try self.allocator.create(LispObject);
        vm.gcRegister(bodyIdxObj);
        bodyIdxObj.* = LispObject.numberObj(@as(i64, bodyStartIdx));
        if (paramChain) |pc| {
            bodyIdxObj.next = pc;
        }

        // Create a Closure struct with params, body, and env
        const closure = try self.allocator.create(Closure);
        closure.* = Closure{
            .params = if (paramsExpr == .list) blk: {
                var syms: [16]*Symbol = undefined;
                var count: usize = 0;
                for (paramsExpr.list) |p| {
                    if (p == .symbol and count < 16) {
                        syms[count] = p.symbol;
                        count += 1;
                    }
                }
                break :blk syms[0..count];
            } else &[_]*Symbol{},
            .body = bodyExprs,
            .env = env,
            .is_macro = false,
        };

        const clObj = try self.allocator.create(LispObject);
        vm.gcRegister(clObj);
        clObj.* = LispObject{
            .type = .closure,
            .value = .{ .closure = closure },
            .next = bodyIdxObj,
            .marked = false,
        };
        vm.push(clObj);
    }

    fn compileCall(self: *Bytecode, items: []Expr, env: *Environment, vm: *Vm) !void {
        // (func arg1 arg2 ...)
        // Compile arguments first (right-to-left for stack order)
        // Compile arguments left-to-right so the first arg is at the bottom of the stack
        var i: usize = 1;
        while (i < items.len) {
            try self.compileExpr(items[i], env, vm);
            i += 1;
        }

        // Compile function (head) - for symbols that are builtins, emit as builtin reference
        const head = items[0];
        switch (head) {
            .symbol => |sym| {
                // Check if this is a known builtin via dispatch table
                var clean: []const u8 = sym.name[0..];
                while (clean.len > 0 and clean[clean.len - 1] == 0) clean = clean[0 .. clean.len - 1];
                debugPrint("compileCall: checking builtin '{s}'\n", .{clean});
                if (vm.dispatch_table.get(clean)) |_| {
                    // It's a builtin - add to bytecode constants, emit as symbol lookup
                    const nameIdx = try self.emitConstRef(sym);
                    debugPrint("emitConstRef: added symbol '{s}' at idx {d}\n", .{ sym.name[0..], nameIdx });
                    try self.emitSymbol(nameIdx);
                } else {
                    // Not a builtin — regular symbol lookup
                    debugPrint("compileCall: '{s}' not found in dispatch_table\n", .{clean});
                    try self.compileExpr(head, env, vm);
                }
            },
            else => {
                try self.compileExpr(head, env, vm);
            },
        }

        // Emit call with arg count
        const argCount = if (items.len > 1) @as(u8, @intCast(items.len - 1)) else 0;
        try self.emitCall(argCount);
    }
};

/// Builtin dispatch enum — avoids function pointer circular references.
pub const Vm = struct {
    pub const Error = error{OutOfMemory, ImportRequiresArg, ImportInvalidArg, LoadRequiresArg, LoadInvalidArg};

    stack: std.ArrayList(*LispObject),
    allocator: Allocator,
    rootEnv: *Environment,
    macroArgs: std.StringHashMap(Expr),
    dispatch_table: *std.StringHashMap(BuiltinKind),
    packageTable: std.StringHashMap([]const u8),
    gcHeap: std.ArrayList(*LispObject),
    bytecode_constants: std.ArrayList(*LispObject),
    bytecode_compile_constants: std.ArrayList(*LispObject),

pub fn init(allocator: Allocator, env: *Environment) !Vm {
        const dt = try allocator.create(std.StringHashMap(BuiltinKind));
        dt.* = std.StringHashMap(BuiltinKind).init(allocator);
        errdefer allocator.destroy(dt);

        var vm = Vm{
            .stack = try std.ArrayList(*LispObject).initCapacity(allocator, 256),
            .allocator = allocator,
            .rootEnv = env,
            .macroArgs = std.StringHashMap(Expr).init(allocator),
            .dispatch_table = dt,
            .packageTable = std.StringHashMap([]const u8).init(allocator),
            .gcHeap = try std.ArrayList(*LispObject).initCapacity(allocator, 64),
            .bytecode_constants = try std.ArrayList(*LispObject).initCapacity(allocator, 64),
            .bytecode_compile_constants = try std.ArrayList(*LispObject).initCapacity(allocator, 64),
        };

        // Register all builtins
        try vm._registerBuiltin("+", .add);
        try vm._registerBuiltin("-", .sub);
        try vm._registerBuiltin("*", .mul);
        try vm._registerBuiltin("/", .div);
        try vm._registerBuiltin("=", .eq);
        try vm._registerBuiltin("<", .lt);
        try vm._registerBuiltin(">", .gt);
        try vm._registerBuiltin("<=", .le);
        try vm._registerBuiltin(">=", .ge);
        try vm._registerBuiltin("rem", .rem);
        try vm._registerBuiltin("bit-and", .bit_and);
        try vm._registerBuiltin("bit-or", .bit_or);
        try vm._registerBuiltin("bit-not", .bit_not);
        try vm._registerBuiltin("bit-shl", .bit_shl);
        try vm._registerBuiltin("bit-shr", .bit_shr);
        try vm._registerBuiltin("cons", .cons);
        try vm._registerBuiltin("car", .car);
        try vm._registerBuiltin("cdr", .cdr);
        try vm._registerBuiltin("print", .print);
        try vm._registerBuiltin("null?", .null);
        try vm._registerBuiltin("not", .not);
        try vm._registerBuiltin("symbol?", .symbol);
        try vm._registerBuiltin("number?", .number);
        try vm._registerBuiltin("list?", .list);
        try vm._registerBuiltin("length", .length);
        try vm._registerBuiltin("append", .append);
        try vm._registerBuiltin("reverse", .reverse);
        try vm._registerBuiltin("member", .member);
        try vm._registerBuiltin("assoc", .assoc);
        try vm._registerBuiltin("map", .map);
        try vm._registerBuiltin("filter", .filter);
        try vm._registerBuiltin("println", .println);
        try vm._registerBuiltin("load", .load);
        try vm._registerBuiltin("import", .import);
        // Predicate builtins
        try vm._registerBuiltin("equal?", .equal);
        try vm._registerBuiltin("even?", .even);
        try vm._registerBuiltin("odd?", .odd);
        try vm._registerBuiltin("positive?", .positive);
        try vm._registerBuiltin("negative?", .negative);
        try vm._registerBuiltin("type-of", .type_of);
        // String builtins
        try vm._registerBuiltin("str", .str);
        try vm._registerBuiltin("str-cat", .str_cat);
        try vm._registerBuiltin("str-len", .str_len);
        try vm._registerBuiltin("str=?", .str_eq);
        try vm._registerBuiltin("substr", .substr);
        // IO
        try vm._registerBuiltin("read-line", .read_line);
        try vm._registerBuiltin("writeln", .writeln);

        return vm;
    }

    fn _registerBuiltin(self: *Vm, name: []const u8, kind: BuiltinKind) !void {
        const key = try self.allocator.dupe(u8, name);
        const e = self.dispatch_table.getOrPut(key) catch return error.OutOfMemory;
        e.value_ptr.* = kind;

        // Also register as a "builtin" LispObject in rootEnv so it can be
        // referenced as a value (e.g., passed to `call` or stored in a closure).
        const obj = try self.allocator.create(LispObject);
        self.gcRegister(obj);
        obj.type = .builtin;
        obj.value = .{ .builtin = key };
        try self.rootEnv.bind(key, obj);
    }

    pub fn deinit(self: *Vm) void {
        self.stack.deinit(self.allocator);
        self.gcHeap.deinit(self.allocator);
        self.macroArgs.deinit();
        self.bytecode_constants.deinit(self.allocator);
        self.bytecode_compile_constants.deinit(self.allocator);
        var it = self.dispatch_table.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.dispatch_table.deinit();
        self.allocator.destroy(self.dispatch_table);
        var pit = self.packageTable.iterator();
        while (pit.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.packageTable.deinit();
    }

    /// Register a LispObject on the GC heap for tracking.
    pub fn gcRegister(self: *Vm, obj: *LispObject) void {
        if (self.gcHeap.items.len < self.gcHeap.capacity) {
            self.gcHeap.appendAssumeCapacity(obj);
        }
    }

    /// Allocate a LispObject and register it on the GC heap.
    pub fn gcAlloc(self: *Vm) !*LispObject {
        const obj = try self.allocator.create(LispObject);
        obj.* = LispObject.nilObj(); // Initialize with nil
        self.gcRegister(obj);
        return obj;
    }

    /// Mark-and-sweep GC: mark reachable objects, sweep unreachable ones.
    pub fn gcCollect(self: *Vm) void {
        // Step 1: Clear all marked flags
        var i: usize = 0;
        while (i < self.gcHeap.items.len) : (i += 1) {
            self.gcHeap.items[i].marked = false;
        }

        // Step 2: Root scan — mark all objects reachable from stack + rootEnv
        var si: usize = 0;
        while (si < self.stack.items.len) : (si += 1) {
            self._gcMark(self.stack.items[si]);
        }
        self._gcMarkEnv(self.rootEnv);

        // Step 3: Sweep — free all unmarked objects
        var free_list = try std.ArrayList(*LispObject).initCapacity(self.allocator, 8);
        defer free_list.deinit();
        i = 0;
        while (i < self.gcHeap.items.len) : (i += 1) {
            if (!self.gcHeap.items[i].marked) {
                free_list.append(self.gcHeap.items[i]) catch {};
            }
        }

        // Free unmarked objects
        i = 0;
        while (i < free_list.items.len) : (i += 1) {
            const obj = free_list.items[i];
            // Free cons cells
            if (obj.type == .cons) {
                // Free the cons cell itself (car and cdr are tracked separately)
                self.allocator.destroy(obj.value.cons);
            }
            self.allocator.destroy(obj);
        }

        // Step 4: Compact gcHeap — keep only marked objects
        var write_idx: usize = 0;
        i = 0;
        while (i < self.gcHeap.items.len) : (i += 1) {
            if (self.gcHeap.items[i].marked) {
                self.gcHeap.items[write_idx] = self.gcHeap.items[i];
                write_idx += 1;
            }
        }
        self.gcHeap.shrinkRetainingCapacity(write_idx);
    }

    /// Mark an object and all its children recursively.
    fn _gcMark(self: *Vm, obj: *LispObject) void {
        if (obj.marked) return; // Already marked
        obj.marked = true;

        // Mark children based on type
        switch (obj.value) {
            .cons => |cell| {
                self._gcMark(cell.car);
                self._gcMark(cell.cdr);
            },
            .closure => |cl| {
                // Mark symbols in closure params
                var pi: usize = 0;
                while (pi < cl.params.len) : (pi += 1) {
                    self._gcMarkSymbol(cl.params[pi]);
                }
            },
            else => {}, // nil, number, symbol, builtin, err have no children to mark
        }
    }

    /// Mark a symbol (symbols are shared, not freed by GC).
    fn _gcMarkSymbol(_: *Vm, _sym: *Symbol) void {
        _ = _sym; // Symbols are in the arena, not on GC heap
    }

    /// Mark all objects reachable from an environment and its parents.
    fn _gcMarkEnv(self: *Vm, env: *Environment) void {
        var it = env.bindings.iterator();
        while (it.next()) |entry| {
            self._gcMark(entry.value_ptr.*);
        }
        if (env.parent != null) {
            self._gcMarkEnv(env.parent.?);
        }
    }

    /// Add a LispObject to the bytecode constant pool and return its index
    pub fn _addConstant(self: *Vm, val: *LispObject) u32 {
        const idx = @as(u32, @intCast(self.bytecode_constants.items.len));
        self.bytecode_constants.appendAssumeCapacity(val);
        return idx;
    }

    /// Add a Symbol to the bytecode constant pool and return its index
fn _addConstantStr(self: *Vm, s: []const u8) !u32 {
        const copy = try self.allocator.alloc(u8, s.len);
        @memcpy(copy, s);
        const obj = try self.allocator.create(LispObject);
        self.gcRegister(obj);
        obj.* = LispObject.stringObj(copy);
        const idx: u32 = @intCast(self.bytecode_compile_constants.items.len);
        self.bytecode_compile_constants.appendAssumeCapacity(obj);
        return idx;
    }

    /// Add an Expr converted to a LispObject constant and return its index
    pub fn _addConstantExpr(self: *Vm, expr: Expr) !u32 {
        const obj = try self.allocator.create(LispObject);
        switch (expr) {
            .nil => {
                obj.* = LispObject.nilObj();
            },
            .number => |n| {
                obj.* = LispObject.numberObj(n);
            },
            .symbol => |sym| {
                obj.* = LispObject.symbolObj(sym);
            },
            .string => |s| {
                const copy = try self.allocator.dupe(u8, s);
                self.gcRegister(obj);
                obj.* = LispObject.stringObj(copy);
            },
            .list => |items| {
                // Convert AST list to a ConsCell chain, returning a LispObject of type .cons
                if (items.len == 0) {
                    obj.* = LispObject.nilObj();
                } else {
                    // Build from bottom (end of list) up
                    var tail: *LispObject = obj;
                    tail.* = LispObject.nilObj();
                    var i: usize = items.len;
                    while (i > 0) {
                        i -= 1;
                        const cell_obj = try self.allocator.create(LispObject);
                        self.gcRegister(cell_obj);
                        const cell = try self.allocator.create(ConsCell);

                        const car_val: *LispObject = switch (items[i]) {
                            .nil => blk: {
                                const o = try self.allocator.create(LispObject);
                                self.gcRegister(o);
                                o.* = LispObject.nilObj();
                                break :blk o;
                            },
                            .number => |n| blk: {
                                const o = try self.allocator.create(LispObject);
                                self.gcRegister(o);
                                o.* = LispObject.numberObj(n);
                                break :blk o;
                            },
                            .symbol => blk: {
                                const o = try self.allocator.create(LispObject);
                                self.gcRegister(o);
                                o.* = LispObject.nilObj();
                                break :blk o;
                            },
                            .list => blk: {
                                const o = try self.allocator.create(LispObject);
                                self.gcRegister(o);
                                o.* = LispObject.nilObj();
                                break :blk o;
                            },
                            .string => blk: {
                                const o = try self.allocator.create(LispObject);
                                self.gcRegister(o);
                                o.* = LispObject.nilObj();
                                break :blk o;
                            },
                        };

                        cell.* = ConsCell.init(car_val, tail);
                        cell_obj.* = LispObject{
                            .type = .cons,
                            .value = .{ .cons = cell },
                            .next = tail,
                            .marked = false,
                        };
                        tail = cell_obj;
                    }
                    obj.* = tail.*;
                }
            },
        }
        const idx = @as(u32, @intCast(self.bytecode_constants.items.len));
        self.bytecode_constants.appendAssumeCapacity(obj);
        return idx;
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
        self.gcRegister(result);
        self.push(result);
    }

    pub fn primSub(self: *Vm) !void {
        const right = self.pop() orelse return error.StackUnderflow;
        const left = self.pop() orelse return error.StackUnderflow;
        if (left.type != .number or right.type != .number) return error.TypeError;
        const result = self.allocator.create(LispObject) catch return error.OutOfMemory;
        result.* = LispObject.numberObj(left.value.number - right.value.number);
        self.gcRegister(result);
        self.push(result);
    }

    pub fn primMul(self: *Vm) !void {
        const b = self.pop() orelse return error.StackUnderflow;
        const a = self.pop() orelse return error.StackUnderflow;
        if (a.type != .number or b.type != .number) return error.TypeError;
        const result = self.allocator.create(LispObject) catch return error.OutOfMemory;
        result.* = LispObject.numberObj(a.value.number * b.value.number);
        self.gcRegister(result);
        self.push(result);
    }

    pub fn primDiv(self: *Vm) !void {
        const right = self.pop() orelse return error.StackUnderflow;
        const left = self.pop() orelse return error.StackUnderflow;
        if (left.type != .number or right.type != .number) return error.TypeError;
        if (right.value.number == 0) return error.DivisionByZero;
        const result = self.allocator.create(LispObject) catch return error.OutOfMemory;
        result.* = LispObject.numberObj(@divTrunc(left.value.number, right.value.number));
        self.gcRegister(result);
        self.push(result);
    }

    pub fn primRem(self: *Vm) !void {
        const right = self.pop() orelse return error.StackUnderflow;
        const left = self.pop() orelse return error.StackUnderflow;
        if (left.type != .number or right.type != .number) return error.TypeError;
        if (right.value.number == 0) return error.DivisionByZero;
        const result = self.allocator.create(LispObject) catch return error.OutOfMemory;
        result.* = LispObject.numberObj(@mod(left.value.number, right.value.number));
        self.gcRegister(result);
        self.push(result);
    }

    /// (bit-and a b) — bitwise AND
    pub fn primBitAnd(self: *Vm) !void {
        const b = self.pop() orelse return error.StackUnderflow;
        const a = self.pop() orelse return error.StackUnderflow;
        if (a.type != .number or b.type != .number) return error.TypeError;
        const result = try self.allocator.create(LispObject);
        self.gcRegister(result);
        result.* = LispObject.numberObj(a.value.number & b.value.number);
        self.push(result);
    }

    /// (bit-or a b) — bitwise OR
    pub fn primBitOr(self: *Vm) !void {
        const b = self.pop() orelse return error.StackUnderflow;
        const a = self.pop() orelse return error.StackUnderflow;
        if (a.type != .number or b.type != .number) return error.TypeError;
        const result = try self.allocator.create(LispObject);
        self.gcRegister(result);
        result.* = LispObject.numberObj(a.value.number | b.value.number);
        self.push(result);
    }

    /// (bit-not n) — bitwise NOT
    pub fn primBitNot(self: *Vm) !void {
        const obj = self.pop() orelse return error.StackUnderflow;
        if (obj.type != .number) return error.TypeError;
        const result = try self.allocator.create(LispObject);
        self.gcRegister(result);
        result.* = LispObject.numberObj(~obj.value.number);
        self.push(result);
    }

    /// (bit-shl n count) — bitwise shift left
    pub fn primBitShl(self: *Vm) !void {
        const count = self.pop() orelse return error.StackUnderflow;
        const obj = self.pop() orelse return error.StackUnderflow;
        if (obj.type != .number or count.type != .number) return error.TypeError;
        const result = try self.allocator.create(LispObject);
        self.gcRegister(result);
        result.* = LispObject.numberObj(obj.value.number << @intCast(count.value.number));
        self.push(result);
    }

    /// (bit-shr n count) — bitwise shift right (arithmetic)
    pub fn primBitShr(self: *Vm) !void {
        const count = self.pop() orelse return error.StackUnderflow;
        const obj = self.pop() orelse return error.StackUnderflow;
        if (obj.type != .number or count.type != .number) return error.TypeError;
        const result = try self.allocator.create(LispObject);
        self.gcRegister(result);
        result.* = LispObject.numberObj(obj.value.number >> @intCast(count.value.number));
        self.push(result);
    }

    pub fn primEq(self: *Vm) !void {
        const b = self.pop() orelse return error.StackUnderflow;
        const a = self.pop() orelse return error.StackUnderflow;
        const result = self.allocator.create(LispObject) catch return error.OutOfMemory;
        self.gcRegister(result);
        result.* = if (a.type == .number and b.type == .number)
            LispObject.numberObj(if (a.value.number == b.value.number) 1 else 0)
        else
            LispObject.numberObj(0);
        self.push(result);
    }

    pub fn primLt(self: *Vm) !void {
        const right = self.pop() orelse return error.StackUnderflow;
        const left = self.pop() orelse return error.StackUnderflow;
        const result = self.allocator.create(LispObject) catch return error.OutOfMemory;
        self.gcRegister(result);
        result.* = if (left.type == .number and right.type == .number)
            LispObject.numberObj(if (left.value.number < right.value.number) 1 else 0)
        else
            LispObject.numberObj(0);
        self.push(result);
    }

    pub fn primGt(self: *Vm) !void {
        const right = self.pop() orelse return error.StackUnderflow;
        const left = self.pop() orelse return error.StackUnderflow;
        const result = self.allocator.create(LispObject) catch return error.OutOfMemory;
        self.gcRegister(result);
        result.* = if (left.type == .number and right.type == .number)
            LispObject.numberObj(if (left.value.number > right.value.number) 1 else 0)
        else
            LispObject.numberObj(0);
        self.push(result);
    }

    pub fn primLe(self: *Vm) !void {
        const right = self.pop() orelse return error.StackUnderflow;
        const left = self.pop() orelse return error.StackUnderflow;
        const result = self.allocator.create(LispObject) catch return error.OutOfMemory;
        self.gcRegister(result);
        result.* = if (left.type == .number and right.type == .number)
            LispObject.numberObj(if (left.value.number <= right.value.number) 1 else 0)
        else
            LispObject.numberObj(0);
        self.push(result);
    }

    pub fn primGe(self: *Vm) !void {
        const right = self.pop() orelse return error.StackUnderflow;
        const left = self.pop() orelse return error.StackUnderflow;
        const result = self.allocator.create(LispObject) catch return error.OutOfMemory;
        self.gcRegister(result);
        result.* = if (left.type == .number and right.type == .number)
            LispObject.numberObj(if (left.value.number >= right.value.number) 1 else 0)
        else
            LispObject.numberObj(0);
        self.push(result);
    }

    /// (cons a b) — create ConsCell(a, b)
    pub fn primCons(self: *Vm) !void {
        const cdr = self.pop() orelse return error.StackUnderflow;
        const car = self.pop() orelse return error.StackUnderflow;
        const cell = try self.allocator.create(ConsCell);
        cell.* = ConsCell.init(car, cdr);
        const obj = try self.allocator.create(LispObject);
        self.gcRegister(obj);
        obj.* = LispObject{
            .type = .cons,
            .value = .{ .cons = cell },
            .next = null,
            .marked = false,
        };
        self.push(obj);
    }

    /// (car x) — get first element of ConsCell
    pub fn primCar(self: *Vm) !void {
        const obj = self.pop() orelse return error.StackUnderflow;
        if (obj.type != .cons) return error.TypeError;
        self.push(obj.value.cons.car);
    }

    /// (cdr x) — get rest of ConsCell
    pub fn primCdr(self: *Vm) !void {
        const obj = self.pop() orelse return error.StackUnderflow;
        if (obj.type != .cons) return error.TypeError;
        self.push(obj.value.cons.cdr);
    }

    /// (print x) — format and print LispObject to stdout, return nil
    pub fn primPrint(self: *Vm) !void {
        const obj = self.pop() orelse return error.StackUnderflow;
        const formatted = try self.formatLispObject(obj);
        debugPrint("{s}\n", .{formatted});
        self.allocator.free(formatted);
        const nil_obj = try self.allocator.create(LispObject);
        self.gcRegister(nil_obj);
        nil_obj.* = LispObject.nilObj();
        self.push(nil_obj);
    }

    /// Type predicates: null?(x) → returns 1 if nil, 0 otherwise
    pub fn primNullQ(self: *Vm) !void {
        const obj = self.pop() orelse return error.StackUnderflow;
        const result = try self.allocator.create(LispObject);
        self.gcRegister(result);
        if (obj.type == .nil) {
            result.* = LispObject.numberObj(1);
        } else {
            result.* = LispObject.numberObj(0);
        }
        self.push(result);
    }

    /// (not x) — returns 1 if x is nil, 0 otherwise
    pub fn primNot(self: *Vm) !void {
        const obj = self.pop() orelse return error.StackUnderflow;
        const result = try self.allocator.create(LispObject);
        self.gcRegister(result);
        result.* = if (obj.type == .nil) LispObject.numberObj(1) else LispObject.numberObj(0);
        self.push(result);
    }

    /// Type predicates: symbol?(x) → returns 1 if symbol, 0 otherwise
    pub fn primSymbolQ(self: *Vm) !void {
        const obj = self.pop() orelse return error.StackUnderflow;
        const result = try self.allocator.create(LispObject);
        self.gcRegister(result);
        if (obj.type == .symbol) {
            result.* = LispObject.numberObj(1);
        } else {
            result.* = LispObject.numberObj(0);
        }
        self.push(result);
    }

    /// Type predicates: number?(x) → returns 1 if number, 0 otherwise
    pub fn primNumberQ(self: *Vm) !void {
        const obj = self.pop() orelse return error.StackUnderflow;
        const result = try self.allocator.create(LispObject);
        self.gcRegister(result);
        if (obj.type == .number) {
            result.* = LispObject.numberObj(1);
        } else {
            result.* = LispObject.numberObj(0);
        }
        self.push(result);
    }

    /// Type predicates: list?(x) → returns 1 if ConsCell or nil, 0 otherwise
    pub fn primListQ(self: *Vm) !void {
        const obj = self.pop() orelse return error.StackUnderflow;
        const result = try self.allocator.create(LispObject);
        self.gcRegister(result);
        if (obj.type == .cons or obj.type == .nil) {
            result.* = LispObject.numberObj(1);
        } else {
            result.* = LispObject.numberObj(0);
        }
        self.push(result);
    }

    /// (equal? a b) — recursive structural equality
    pub fn primEqual(self: *Vm) !void {
        const b = self.pop() orelse return error.StackUnderflow;
        const a = self.pop() orelse return error.StackUnderflow;
        const result = try self.allocator.create(LispObject);
        self.gcRegister(result);
        result.* = LispObject.numberObj(if (self._equal(a, b)) 1 else 0);
        self.push(result);
    }

    fn _equal(self: *Vm, a: *LispObject, b: *LispObject) bool {
        if (a.type != b.type) return false;
        return switch (a.type) {
            .nil => true,
            .number => a.value.number == b.value.number,
            .symbol => std.mem.eql(u8, a.value.symbol.name, b.value.symbol.name),
            .string => std.mem.eql(u8, a.value.string, b.value.string),
            .cons => self._equal(a.value.cons.car, b.value.cons.car) and
                     self._equal(a.value.cons.cdr, b.value.cons.cdr),
            .builtin => std.mem.eql(u8, a.value.builtin, b.value.builtin),
            .closure => a == b, // pointer equality
            else => false,
        };
    }

    /// (even? n) — 1 if n is even
    pub fn primEven(self: *Vm) !void {
        const obj = self.pop() orelse return error.StackUnderflow;
        const result = try self.allocator.create(LispObject);
        self.gcRegister(result);
        if (obj.type == .number) {
            result.* = LispObject.numberObj(if (@rem(obj.value.number, 2) == 0) 1 else 0);
        } else {
            result.* = LispObject.numberObj(0);
        }
        self.push(result);
    }

    /// (odd? n) — 1 if n is odd
    pub fn primOdd(self: *Vm) !void {
        const obj = self.pop() orelse return error.StackUnderflow;
        const result = try self.allocator.create(LispObject);
        self.gcRegister(result);
        if (obj.type == .number) {
            result.* = LispObject.numberObj(if (@rem(obj.value.number, 2) != 0) 1 else 0);
        } else {
            result.* = LispObject.numberObj(0);
        }
        self.push(result);
    }

    /// (positive? n) — 1 if n > 0
    pub fn primPositive(self: *Vm) !void {
        const obj = self.pop() orelse return error.StackUnderflow;
        const result = try self.allocator.create(LispObject);
        self.gcRegister(result);
        if (obj.type == .number) {
            result.* = LispObject.numberObj(if (obj.value.number > 0) 1 else 0);
        } else {
            result.* = LispObject.numberObj(0);
        }
        self.push(result);
    }

    /// (negative? n) — 1 if n < 0
    pub fn primNegative(self: *Vm) !void {
        const obj = self.pop() orelse return error.StackUnderflow;
        const result = try self.allocator.create(LispObject);
        self.gcRegister(result);
        if (obj.type == .number) {
            result.* = LispObject.numberObj(if (obj.value.number < 0) 1 else 0);
        } else {
            result.* = LispObject.numberObj(0);
        }
        self.push(result);
    }

    /// (type-of x) — return symbol: nil, number, symbol, list, builtin, closure
    pub fn primTypeOf(self: *Vm) !void {
        const obj = self.pop() orelse return error.StackUnderflow;
        const result = try self.allocator.create(LispObject);
        self.gcRegister(result);
        const name = switch (obj.type) {
            .nil => "nil",
            .number => "number",
            .symbol => "symbol",
            .cons => "list",
            .builtin => "builtin",
            .closure => "closure",
            .string => "string",
            else => "unknown",
        };
        const copy = try self.allocator.alloc(u8, name.len);
        @memcpy(copy, name);
        result.* = LispObject.stringObj(copy);
        self.push(result);
    }

    /// (str val...) — concatenate all arguments into a single string
    pub fn primStr(self: *Vm) !void {
        var args: [16]*LispObject = undefined;
        const count = self.stack.items.len;
        if (count == 0) {
            const obj = try self.allocator.create(LispObject);
            self.gcRegister(obj);
            obj.* = LispObject.stringObj("");
            self.push(obj);
            return;
        }
        var i: usize = 0;
        while (i < count) : (i += 1) {
            args[count - 1 - i] = self.pop() orelse return error.StackUnderflow;
        }
        var totalLen: usize = 0;
        i = 0;
        while (i < count) : (i += 1) {
            switch (args[i].value) {
                .string => |s| totalLen += s.len,
                .number => |n| totalLen += i64ToBufLen(n),
                .nil => {},
                .symbol => |sym| totalLen += sym.name.len,
                else => {},
            }
        }
        const buf = try self.allocator.alloc(u8, totalLen);
        var pos: usize = 0;
        i = 0;
        while (i < count) : (i += 1) {
            switch (args[i].value) {
                .string => |s| {
                    if (pos + s.len <= buf.len) {
                        @memcpy(buf[pos .. pos + s.len], s);
                        pos += s.len;
                    }
                },
                .number => |n| {
                    const s = i64ToBuf(n);
                    if (pos + s.len <= buf.len) {
                        @memcpy(buf[pos .. pos + s.len], s);
                        pos += s.len;
                    }
                },
                .nil => {},
                .symbol => |sym| {
                    const s = sym.name[0..];
                    if (pos + s.len <= buf.len) {
                        @memcpy(buf[pos .. pos + s.len], s);
                        pos += s.len;
                    }
                },
                else => {},
            }
        }
        const result = try self.allocator.create(LispObject);
        self.gcRegister(result);
        result.* = LispObject.stringObj(buf);
        self.push(result);
    }

    /// (str+ a b) — alias for concatenation (same as str with 2 args)
    pub fn primStrCat(self: *Vm) !void {
        try self.primStr(); // reuse the same logic for 2-argument concatenation
    }

    /// (str-len s) — return length of string as number
    pub fn primStrLen(self: *Vm) !void {
        const obj = self.pop() orelse return error.StackUnderflow;
        const result = try self.allocator.create(LispObject);
        self.gcRegister(result);
        const len: i64 = switch (obj.value) {
            .string => |s| @intCast(s.len),
            else => 0,
        };
        result.* = LispObject.numberObj(len);
        self.push(result);
    }

    /// (str=? a b) — compare two strings for equality, return 1 or 0
    pub fn primStrEq(self: *Vm) !void {
        const b = self.pop() orelse return error.StackUnderflow;
        const a = self.pop() orelse return error.StackUnderflow;
        const result = try self.allocator.create(LispObject);
        self.gcRegister(result);
        const eq = if (a.type == .string and b.type == .string)
            std.mem.eql(u8, a.value.string, b.value.string)
        else
            false;
        result.* = LispObject.numberObj(if (eq) 1 else 0);
        self.push(result);
    }

    /// (substr s start [end]) — extract substring from start to end (or end of string)
    pub fn primSubstr(self: *Vm) !void {
        const count = self.stack.items.len;
        if (count < 2) {
            const obj = try self.allocator.create(LispObject);
            self.gcRegister(obj);
            obj.* = LispObject.errorObj("substr: need >=2 args");
            self.push(obj);
            return;
        }
        
        // Pop and reverse args so args[0] = string, args[1] = start, args[2] = end
        var args: [16]*LispObject = undefined;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            args[count - 1 - i] = self.pop() orelse return error.StackUnderflow;
        }

        const strObj = args[0];
        const startObj = args[1];

        var start: usize = 0;
        var end: usize = 0;

        if (strObj.type != .string) {
            const obj = try self.allocator.create(LispObject);
            self.gcRegister(obj);
            obj.* = LispObject.errorObj("substr: first arg must be string");
            self.push(obj);
            return;
        }
        
        const str = strObj.value.string;

        if (startObj.type == .number) {
            start = if (startObj.value.number < 0) 0 else @intCast(startObj.value.number);
            if (start > str.len) start = str.len;

            if (count >= 3 and args[2].type == .number) {
                end = @intCast(args[2].value.number);
                if (end > str.len) end = str.len;
            } else {
                end = str.len;
            }
        } else {
            const obj = try self.allocator.create(LispObject);
            self.gcRegister(obj);
            obj.* = LispObject.errorObj("substr: start must be number");
            self.push(obj);
            return;
        }

        if (start > end) {
            start = end;
        }

        const len = if (end > start) end - start else 0;
        const copy = try self.allocator.alloc(u8, len);
        if (len > 0) {
            @memcpy(copy, str[start..end]);
        }
        const result = try self.allocator.create(LispObject);
        self.gcRegister(result);
        result.* = LispObject.stringObj(copy);
        self.push(result);
    }

    fn i64ToBuf(n: i64) []const u8 {
        var buf: [32]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}", .{n}) catch "";
        return s;
    }

    fn i64ToBufLen(n: i64) usize {
        var buf: [32]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}", .{n}) catch "";
        return s.len;
    }

    /// length(lst) — count cons cells in a list
    pub fn primLength(self: *Vm) !void {
        const obj = self.pop() orelse return error.StackUnderflow;
        var n: usize = 0;
        var curr: *LispObject = obj;
        while (curr.type == .cons) {
            curr = curr.value.cons.cdr;
            n += 1;
        }
        const result = try self.allocator.create(LispObject);
        self.gcRegister(result);
        result.* = LispObject.numberObj(@intCast(n));
        self.push(result);
    }

    /// (append list1 list2 ...) — concatenate lists into a new list
    pub fn primAppend(self: *Vm) !void {
        const count = self.stack.items.len;
        if (count == 0) return error.StackUnderflow;

        // Create a shared nil object for all list terminators
        const nil_obj = try self.allocator.create(LispObject);
        self.gcRegister(nil_obj);
        nil_obj.* = LispObject.nilObj();

        // Collect all list heads
        var heads = try self.allocator.alloc(*LispObject, count);
        defer self.allocator.free(heads);
        var i: usize = 0;
        var has_any_list = false;
        while (i < count) : (i += 1) {
            const obj = self.stack.items[i];
            if (obj.type == .cons or obj.type == .nil) {
                has_any_list = true;
            }
            heads[i] = obj;
        }
        if (!has_any_list) return error.TypeError;

        // Build result by copying elements from all lists
        var result: ?*LispObject = null;
        var tail: ?*LispObject = null;

        i = 0;
        while (i < count) : (i += 1) {
            var curr: *LispObject = heads[i];
            while (curr.type == .cons) {
                const car = curr.value.cons.car;
                const cons_cell = try self.allocator.create(ConsCell);
                cons_cell.* = ConsCell.init(car, nil_obj);
                const new_obj = try self.allocator.create(LispObject);
                self.gcRegister(new_obj);
                new_obj.* = LispObject{
                    .type = .cons,
                    .value = .{ .cons = cons_cell },
                    .next = null,
                    .marked = false,
                };
                if (result == null) {
                    result = new_obj;
                } else {
                    tail.?.value.cons.cdr = new_obj;
                }
                tail = new_obj;
                curr = curr.value.cons.cdr;
            }
        }

        if (result == null) {
            self.push(nil_obj);
        } else {
            tail.?.value.cons.cdr = nil_obj;
            self.push(result.?);
        }
    }

    /// (reverse list) — return a new list with elements in reverse order
    pub fn primReverse(self: *Vm) !void {
        const obj = self.pop() orelse return error.StackUnderflow;
        if (obj.type != .cons) return error.TypeError;

        // Create a shared nil object for list terminators
        const nil_obj = try self.allocator.create(LispObject);
        self.gcRegister(nil_obj);
        nil_obj.* = LispObject.nilObj();

        // Collect elements
        var elements = try std.ArrayList(*LispObject).initCapacity(self.allocator, 16);
        defer elements.deinit(self.allocator);
        var curr: *LispObject = obj;
        while (curr.type == .cons) {
            elements.appendAssumeCapacity(curr.value.cons.car);
            curr = curr.value.cons.cdr;
        }

        // Build reversed list by appending to front
        var result: ?*LispObject = null;
        var i: usize = elements.items.len;
        while (i > 0) {
            i -= 1;
            const cons_cell = try self.allocator.create(ConsCell);
            cons_cell.* = ConsCell.init(elements.items[i], nil_obj);
            const new_obj = try self.allocator.create(LispObject);
            new_obj.* = LispObject{
                .type = .cons,
                .value = .{ .cons = cons_cell },
                .next = null,
                .marked = false,
            };
            if (result == null) {
                result = new_obj;
            } else {
                // Find tail
                var tail_ptr: ?*LispObject = result;
                while (tail_ptr.?.type == .cons and tail_ptr.?.value.cons.cdr != nil_obj) {
                    tail_ptr = tail_ptr.?.value.cons.cdr;
                }
                tail_ptr.?.value.cons.cdr = new_obj;
            }
        }

        if (result == null) {
            self.push(nil_obj);
        } else {
            var tail_ptr: ?*LispObject = result;
            while (tail_ptr.?.type == .cons and tail_ptr.?.value.cons.cdr != nil_obj) {
                tail_ptr = tail_ptr.?.value.cons.cdr;
            }
            if (tail_ptr != null and tail_ptr.?.type == .cons) {
                tail_ptr.?.value.cons.cdr = nil_obj;
            }
            self.push(result.?);
        }
    }

    /// (member x list) — check if x is an element of list, return sublist or nil
    pub fn primMember(self: *Vm) !void {
        const list_obj = self.pop() orelse return error.StackUnderflow;
        const x = self.pop() orelse return error.StackUnderflow;
        if (list_obj.type != .cons and list_obj.type != .nil) return error.TypeError;

        var curr: *LispObject = list_obj;
        while (curr.type == .cons) {
            const car = curr.value.cons.car;
            if (car.type == x.type) {
                switch (x.type) {
                    .number => if (car.value.number == x.value.number) break,
                    .nil => break,
                    .symbol => if (std.mem.eql(u8, car.value.symbol.name, x.value.symbol.name)) break,
                    else => {},
                }
            }
            curr = curr.value.cons.cdr;
        }

        if (curr.type == .cons) {
            self.push(curr);
        } else {
            const nil_obj = try self.allocator.create(LispObject);
            self.gcRegister(nil_obj);
            nil_obj.* = LispObject.nilObj();
            self.push(nil_obj);
        }
    }

    /// (assoc key alist) — look up key in association list, return value or nil
    pub fn primAssoc(self: *Vm) !void {
        const alist_obj = self.pop() orelse return error.StackUnderflow;
        const key = self.pop() orelse return error.StackUnderflow;
        if (alist_obj.type != .cons and alist_obj.type != .nil) return error.TypeError;

        var curr: *LispObject = alist_obj;
        while (curr.type == .cons) {
            const car = curr.value.cons.car;
            if (car.type == .cons) {
                const pair_key = car.value.cons.car;
                if (pair_key.type == key.type) {
                    var matched: bool = false;
                    switch (key.type) {
                        .number => matched = pair_key.value.number == key.value.number,
                        .nil => matched = true,
                        .symbol => matched = std.mem.eql(u8, pair_key.value.symbol.name, key.value.symbol.name),
                        else => {},
                    }
                    if (matched) {
                        self.push(car.value.cons.cdr);
                        return;
                    }
                }
            }
            curr = curr.value.cons.cdr;
        }

        const nil_obj = try self.allocator.create(LispObject);
        self.gcRegister(nil_obj);
        nil_obj.* = LispObject.nilObj();
        self.push(nil_obj);
    }

    /// (map fn list) — apply fn to each element, return list of results
    pub fn primMap(self: *Vm) !void {
        const list_obj = self.pop() orelse return error.StackUnderflow;
        const fn_obj = self.pop() orelse return error.StackUnderflow;
        if (list_obj.type != .cons and list_obj.type != .nil) return error.TypeError;
        if (fn_obj.type != .closure and fn_obj.type != .builtin) return error.TypeError;

        // Create a shared nil object
        const nil_obj = try self.allocator.create(LispObject);
        self.gcRegister(nil_obj);
        nil_obj.* = LispObject.nilObj();

        var result: ?*LispObject = null;
        var tail: ?*LispObject = null;
        var curr: *LispObject = list_obj;

        while (curr.type == .cons) {
            self.push(curr.value.cons.car);
            var applied: ?*LispObject = null;
            switch (fn_obj.value) {
                .closure => |cl| {
                    // Convert LispObject to Expr for the closure arg
                    const elem = curr.value.cons.car;
                    const argExpr: Expr = switch (elem.type) {
                        .number => Expr{.number = elem.value.number},
                        .nil => Expr{.nil = {}},
                        .symbol => Expr{.symbol = elem.value.symbol},
                        else => Expr{.nil = {}},
                    };
                    const args_expr = try self.allocator.alloc(Expr, 1);
                    args_expr[0] = argExpr;
                    applied = try self.applyClosure(cl, args_expr, self.rootEnv);
                    self.allocator.free(args_expr);
                },
                .builtin => {
                    const result_obj = try self.allocator.create(LispObject);
                    result_obj.* = LispObject.nilObj();
                    applied = result_obj;
                },
                else => {},
            }

            const cons_cell = try self.allocator.create(ConsCell);
            cons_cell.* = ConsCell.init(applied.?, nil_obj);
            const new_obj = try self.allocator.create(LispObject);
            new_obj.* = LispObject{
                .type = .cons,
                .value = .{ .cons = cons_cell },
                .next = null,
                .marked = false,
            };
            if (result == null) {
                result = new_obj;
            } else {
                tail.?.value.cons.cdr = new_obj;
            }
            tail = new_obj;
            curr = curr.value.cons.cdr;
        }

        if (result == null) {
            self.push(nil_obj);
        } else {
            tail.?.value.cons.cdr = nil_obj;
            self.push(result.?);
        }
    }

    /// (filter pred list) — keep elements where pred returns true
    pub fn primFilter(self: *Vm) !void {
        const list_obj = self.pop() orelse return error.StackUnderflow;
        const pred_obj = self.pop() orelse return error.StackUnderflow;
        if (list_obj.type != .cons and list_obj.type != .nil) return error.TypeError;
        if (pred_obj.type != .closure and pred_obj.type != .builtin) return error.TypeError;

        // Create a shared nil object
        const nil_obj = try self.allocator.create(LispObject);
        self.gcRegister(nil_obj);
        nil_obj.* = LispObject.nilObj();

        var result: ?*LispObject = null;
        var tail: ?*LispObject = null;
        var curr: *LispObject = list_obj;

        while (curr.type == .cons) {
            self.push(curr.value.cons.car);
            var pred_result: ?*LispObject = null;
            switch (pred_obj.value) {
                .closure => |cl| {
                    // Convert LispObject to Expr for the closure arg
                    const elem = curr.value.cons.car;
                    const argExpr: Expr = switch (elem.type) {
                        .number => Expr{.number = elem.value.number},
                        .nil => Expr{.nil = {}},
                        .symbol => Expr{.symbol = elem.value.symbol},
                        else => Expr{.nil = {}},
                    };
                    const args_expr = try self.allocator.alloc(Expr, 1);
                    args_expr[0] = argExpr;
                    pred_result = try self.applyClosure(cl, args_expr, self.rootEnv);
                    self.allocator.free(args_expr);
                },
                else => {},
            }

            if (pred_result != null and pred_result.?.type != .nil) {
                const cons_cell = try self.allocator.create(ConsCell);
                cons_cell.* = ConsCell.init(curr.value.cons.car, nil_obj);
                const new_obj = try self.allocator.create(LispObject);
                new_obj.* = LispObject{
                    .type = .cons,
                    .value = .{ .cons = cons_cell },
                    .next = null,
                    .marked = false,
                };
                if (result == null) {
                    result = new_obj;
                } else {
                    tail.?.value.cons.cdr = new_obj;
                }
                tail = new_obj;
            }
            curr = curr.value.cons.cdr;
        }

        if (result == null) {
            self.push(nil_obj);
        } else {
            tail.?.value.cons.cdr = nil_obj;
            self.push(result.?);
        }
    }

    /// Format a LispObject as a readable string.
    fn formatLispObject(self: *Vm, obj: *LispObject) ![]u8 {
        var buf = try self.allocator.alloc(u8, 512);
        errdefer self.allocator.free(buf);
        var pos: usize = 0;
        try self._formatToString(buf, &pos, obj);
        const result = try self.allocator.dupe(u8, buf[0..pos]);
        self.allocator.free(buf);
        return result;
    }

    fn _formatToString(self: *Vm, buf: []u8, pos: *usize, obj: *LispObject) !void {
        switch (obj.value) {
            .nil => { const s = "nil"; std.mem.copyForwards(u8, buf[pos.*..], s); pos.* += s.len; },
            .number => |n| {
                var tmp: [32]u8 = undefined;
                const s = std.fmt.bufPrint(&tmp, "{d}", .{n}) catch return error.FormatFailed;
                if (pos.* + s.len <= buf.len) {
                    std.mem.copyForwards(u8, buf[pos.*..], s); pos.* += s.len;
                }
            },
            .symbol => |sym| {
                const name = sym.name[0..];
                std.mem.copyForwards(u8, buf[pos.*..], name); pos.* += name.len;
            },
            .cons => |cell| {
                _ = cell;
                const max_elems: usize = 64;
                const elem_buf = try self.allocator.alloc(*LispObject, max_elems);
                defer self.allocator.free(elem_buf);
                var elem_count: usize = 0;
                var curr: *LispObject = obj;
                while (curr.type == .cons and elem_count < max_elems) {
                    elem_buf[elem_count] = curr.value.cons.car;
                    curr = curr.value.cons.cdr;
                    elem_count += 1;
                }
                if (elem_count > 0 and curr.type == .nil) {
                    if (pos.* + 1 + elem_count * 32 + elem_count + 1 > buf.len) return error.FormatTooLong;
                    buf[pos.*] = '('; pos.* += 1;
                    var ei: usize = 0;
                    while (ei < elem_count) : (ei += 1) {
                        if (ei > 0) { buf[pos.*] = ' '; pos.* += 1; }
                        try self._formatToString(buf, pos, elem_buf[ei]);
                    }
                    if (pos.* < buf.len) { buf[pos.*] = ')'; pos.* += 1; }
                } else if (elem_count > 0) {
                    if (pos.* + 1 + elem_count * 32 + elem_count + 4 > buf.len) return error.FormatTooLong;
                    buf[pos.*] = '('; pos.* += 1;
                    var ei: usize = 0;
                    while (ei < elem_count) : (ei += 1) {
                        if (ei > 0) { buf[pos.*] = ' '; pos.* += 1; }
                        try self._formatToString(buf, pos, elem_buf[ei]);
                    }
                    const dot = " . ";
                    if (pos.* + 3 <= buf.len) {
                        std.mem.copyForwards(u8, buf[pos.*..], dot); pos.* += dot.len;
                    }
                    try self._formatToString(buf, pos, curr);
                    if (pos.* < buf.len) { buf[pos.*] = ')'; pos.* += 1; }
                } else {
                    const empty = "()";
                    std.mem.copyForwards(u8, buf[pos.*..], empty); pos.* += empty.len;
                }
            },
            .closure => { const s = "#<closure>"; std.mem.copyForwards(u8, buf[pos.*..], s); pos.* += s.len; },
            .string => |s| { std.mem.copyForwards(u8, buf[pos.*..], s); pos.* += s.len; },
            .builtin => { const s = "#<builtin>"; std.mem.copyForwards(u8, buf[pos.*..], s); pos.* += s.len; },
            .err => |msg| { std.mem.copyForwards(u8, buf[pos.*..], msg); pos.* += msg.len; },
        }
    }

    /// (println arg...) — print multiple args space-separated, each on its own line.
    pub fn primPrintln(self: *Vm) !void {
        // Collect all remaining stack items (bottom to top)
        var items = try self.allocator.alloc(*LispObject, self.stack.items.len);
        defer self.allocator.free(items);
        var i: usize = 0;
        while (i < self.stack.items.len) : (i += 1) {
            items[i] = self.stack.items[i];
        }
        self.stack.clearRetainingCapacity();

        // Print each arg on its own line
        i = 0;
        while (i < items.len) : (i += 1) {
            var buf: [512]u8 = undefined;
            var pos: usize = 0;
            const obj = items[i];
            try self._formatToString(&buf, &pos, obj);
            debugPrint("{s}\n", .{buf[0..pos]}); 
        }

        self.allocator.free(items);

        // Return nil
        const nil_obj = try self.allocator.create(LispObject);
        self.gcRegister(nil_obj);
        nil_obj.* = LispObject.nilObj();
        self.push(nil_obj);
    }

    /// (writeln arg...) — write args space-separated to stdout, then a newline.
    pub fn primWriteln(self: *Vm) !void {
        var items = try self.allocator.alloc(*LispObject, self.stack.items.len);
        defer self.allocator.free(items);
        var i: usize = 0;
        while (i < self.stack.items.len) : (i += 1) {
            items[i] = self.stack.items[i];
        }
        self.stack.clearRetainingCapacity();

        var first = true;
        i = 0;
        while (i < items.len) : (i += 1) {
            var buf: [512]u8 = undefined;
            var pos: usize = 0;
            try self._formatToString(&buf, &pos, items[i]);
            if (!first) {
                _ = os.linux.write(posix.STDOUT_FILENO, " ".ptr, 1);
            }
            _ = os.linux.write(posix.STDOUT_FILENO, buf[0..pos].ptr, pos);
            first = false;
        }
        _ = os.linux.write(posix.STDOUT_FILENO, "\n".ptr, 1);

        const nil_obj = try self.allocator.create(LispObject);
        self.gcRegister(nil_obj);
        nil_obj.* = LispObject.nilObj();
        self.push(nil_obj);
    }

    /// (read-line) — read a line from stdin, return it as a string.
    pub fn primReadLine(self: *Vm) !void {
        var line = std.ArrayList(u8).initCapacity(self.allocator, 64) catch return error.OutOfMemory;
        errdefer line.deinit(self.allocator);
        var ch: [1]u8 = .{0};
        while (true) {
            const n = posix.read(posix.STDIN_FILENO, &ch) catch break;
            if (n == 0) break;
            if (ch[0] == '\n') break;
            try line.append(self.allocator, ch[0]);
        }

        const copy = try self.allocator.dupe(u8, line.items);
        const obj = try self.allocator.create(LispObject);
        self.gcRegister(obj);
        obj.* = LispObject.stringObj(copy);
        self.push(obj);
    }

    /// Read an entire file into a heap-allocated buffer.
    /// Uses std.Io which works in both test and non-test modes.
    fn readFile(self: *Vm, path: []const u8) ![]u8 {
        const io = std.Io.Threaded.io(std.Io.Threaded.global_single_threaded);
        var dir = std.Io.Dir.cwd();
        var file = try dir.openFile(io, path, .{});
        defer file.close(io);

        const file_size = try file.length(io);
        const buf = try self.allocator.alloc(u8, file_size);
        _ = try file.readPositionalAll(io, buf, 0);
        return buf;
    }

    /// (import "pkg-name") — load a package file and evaluate its definitions.
    /// Reads file, tokenizes, parses, and evaluates each top-level form.
    pub fn primImport(self: *Vm) anyerror!void {
        // Pop the package/file name from the stack
        const nameObj = self.pop() orelse return error.ImportRequiresArg;
        defer self.allocator.destroy(nameObj);

        var filename: []const u8 = "";
        switch (nameObj.value) {
            .symbol => |sym| {
                filename = sym.name[0..];
                while (filename.len > 0 and filename[filename.len - 1] == 0) {
                    filename = filename[0 .. filename.len - 1];
                }
            },
            .nil => {
                // Import nil is a no-op
                const nil_obj = try self.allocator.create(LispObject);
                nil_obj.* = LispObject.nilObj();
                self.push(nil_obj);
                return;
            },
            else => return error.ImportInvalidArg,
        }

        // Read file contents using std.Io
        const contents = try self.readFile(filename);
        defer self.allocator.free(contents);

        // Tokenize
        var lexer = Lexer.init(contents);
        var texts_list = try std.ArrayList([]const u8).initCapacity(self.allocator, 16);
        errdefer texts_list.deinit(self.allocator);
        var tokens = try std.ArrayList(Token).initCapacity(self.allocator, 16);
        errdefer tokens.deinit(self.allocator);

        while (true) {
            const tok = lexer.nextToken() orelse break;
            switch (tok) {
                .eof => break,
                else => {
                    try tokens.append(self.allocator, tok);
                    try texts_list.append(self.allocator, lexer.current_text);
                },
            }
        }

        // Create a temporary symbol table for parsing this file
        var tempArena = std.heap.ArenaAllocator.init(self.allocator);
        defer tempArena.deinit();
        var tempSymtab = SymbolTable.init(self.allocator, &tempArena);

        // Build null-separated text buffer
        var total_len: usize = 0;
        for (texts_list.items) |t| { total_len += t.len + 1; }
        const all_texts = try self.allocator.alloc(u8, total_len);
        defer self.allocator.free(all_texts);
        var ti: usize = 0;
        for (texts_list.items) |t| {
            @memcpy(all_texts[ti..ti + t.len], t);
            ti += t.len;
            all_texts[ti] = 0;
            ti += 1;
        }

        var parser = Parser.init(tokens.items, all_texts, &tempArena, &tempSymtab);

        // Evaluate each top-level expression
        while (true) {
            const expr = parser.parseSExpr(0) catch break;
            if (self.eval(expr, self.rootEnv)) |_| {} else |err| {
                debugPrint("import error: {any}\n", .{err});
            }
        }

        // Return nil
        const nil_obj = try self.allocator.create(LispObject);
        nil_obj.* = LispObject.nilObj();
        self.push(nil_obj);
    }

    /// Load a .lisp file: parse and evaluate all top-level forms,
    /// returning the result of the last form.
    pub fn _load(self: *Vm, items: []Expr) anyerror!void {
        if (items.len < 2) {
            const nil_obj = try self.allocator.create(LispObject);
            nil_obj.* = LispObject.nilObj();
            self.push(nil_obj);
            return;
        }

        // Don't eval the filename - just use the symbol directly.
        // eval() would look up the symbol in the env, which fails for arbitrary string-valued symbols.
        var filename: []const u8 = "";
        switch (items[1]) {
            .symbol => |sym| {
                filename = sym.name[0..];
                while (filename.len > 0 and filename[filename.len - 1] == 0) {
                    filename = filename[0 .. filename.len - 1];
                }
            },
            else => {
                const nil_obj = try self.allocator.create(LispObject);
                nil_obj.* = LispObject.nilObj();
                self.push(nil_obj);
                return;
            },
        }

        // Read file contents using std.Io
        const io = std.Io.Threaded.io(std.Io.Threaded.global_single_threaded);
        var dir = std.Io.Dir.cwd();
        var file = try dir.openFile(io, filename, .{});
        defer file.close(io);

        const file_size = try file.length(io);
        const file_buf = try self.allocator.alloc(u8, file_size);
        _ = try file.readPositionalAll(io, file_buf, 0);
        defer self.allocator.free(file_buf);

        // Tokenize
        var lexer = Lexer.init(file_buf);
        var texts_list = try std.ArrayList([]const u8).initCapacity(self.allocator, 16);
        errdefer texts_list.deinit(self.allocator);
        var tokens = try std.ArrayList(Token).initCapacity(self.allocator, 16);
        errdefer tokens.deinit(self.allocator);

        while (true) {
            const tok = lexer.nextToken() orelse break;
            switch (tok) {
                .eof => break,
                else => {
                    try tokens.append(self.allocator, tok);
                    try texts_list.append(self.allocator, lexer.current_text);
                },
            }
        }

        // Create a temporary symbol table for parsing this file
        var tempArena = std.heap.ArenaAllocator.init(self.allocator);
        defer tempArena.deinit();
        var tempSymtab = SymbolTable.init(self.allocator, &tempArena);

        // Build null-separated text buffer
        var total_len: usize = 0;
        for (texts_list.items) |t| { total_len += t.len + 1; }
        const all_texts = try self.allocator.alloc(u8, total_len);
        defer self.allocator.free(all_texts);
        var ti: usize = 0;
        for (texts_list.items) |t| {
            @memcpy(all_texts[ti..ti + t.len], t);
            ti += t.len;
            all_texts[ti] = 0;
            ti += 1;
        }

        var parser = Parser.init(tokens.items, all_texts, &tempArena, &tempSymtab);

        // Evaluate each top-level expression, return last result
        var result_obj: ?*LispObject = null;
        errdefer {
            if (result_obj) |obj| self.allocator.destroy(obj);
        }

        while (true) {
            const expr = parser.parseSExpr(0) catch break;
            switch (expr) {
                .nil => break,
                else => |e| {
                    const evaluated = try self.eval(e, self.rootEnv);
                    // Destroy old result before replacing
                    if (result_obj) |old| self.allocator.destroy(old);
                    result_obj = evaluated;
                },
            }
        }

        if (result_obj == null) {
            const nil_obj = try self.allocator.create(LispObject);
            nil_obj.* = LispObject.nilObj();
            self.push(nil_obj);
            return;
        }
        // Push result onto stack
        self.push(result_obj.?);
    }

    /// Print a value for REPL output.
    pub fn printValue(self: *Vm, obj: *LispObject) void {
        const formatted = self.formatLispObject(obj) catch |err| {
            debugPrint("format error: {any}\n", .{err});
            return;
        };
        debugPrint("{s}\n", .{formatted});
        self.allocator.free(formatted);
    }

    /// Evaluate a single (non-list) Expr into a LispObject.
    pub fn evalAtom(self: *Vm, expr: Expr, env: *Environment) !*LispObject {
        switch (expr) {
            .nil => {
                const obj = try self.allocator.create(LispObject);
                self.gcRegister(obj);
                obj.* = LispObject.nilObj();
                return obj;
            },
            .number => |n| {
                const obj = try self.allocator.create(LispObject);
                self.gcRegister(obj);
                obj.* = LispObject.numberObj(n);
                return obj;
            },
            .string => |s| {
                const obj = try self.allocator.create(LispObject);
                self.gcRegister(obj);
                obj.* = LispObject.stringObj(s);
                return obj;
            },
            .symbol => |sym| {
                // Use sym.name directly — StringHashMap handles the null terminator
                if (env.lookup(sym.name)) |v| return v;
                if (self.rootEnv.lookup(sym.name)) |v| return v;
                const obj = try self.allocator.create(LispObject);
                self.gcRegister(obj);
                obj.* = LispObject.nilObj();
                return obj;
            },
            .list => return error.ListExprNotHandledByEvalAtom,
        }
    }

    /// Convert an Expr into a *LispObject.
    fn _exprToObj(self: *Vm, expr: Expr) !*LispObject {
        return switch (expr) {
            .nil => blk: {
                const o = try self.allocator.create(LispObject);
                self.gcRegister(o);
                o.* = LispObject.nilObj();
                break :blk o;
            },
            .number => |n| blk: {
                const o = try self.allocator.create(LispObject);
                self.gcRegister(o);
                o.* = LispObject.numberObj(n);
                break :blk o;
            },
            .string => blk: {
                const o_num = try self.allocator.create(LispObject);
                self.gcRegister(o_num);
                o_num.* = LispObject.stringObj(expr.string);
                break :blk o_num;
            },
            .symbol => blk: {
                const o = try self.allocator.create(LispObject);
                self.gcRegister(o);
                o.* = LispObject.nilObj();
                break :blk o;
            },
            .list => blk: {
                const o = try self.allocator.create(LispObject);
                self.gcRegister(o);
                o.* = LispObject.nilObj();
                break :blk o;
            },
        };
    }

    /// Build a ConsCell chain from an Expr list, bottom-up.
    fn _buildConsList(self: *Vm, ast: []Expr) !*LispObject {
        if (ast.len == 0) {
            const obj = try self.allocator.create(LispObject);
            self.gcRegister(obj);
            obj.* = LispObject.nilObj();
            return obj;
        }
        var tail: *LispObject = try self.allocator.create(LispObject);
        self.gcRegister(tail);
        tail.* = LispObject.nilObj();

        var i: usize = ast.len;
        while (i > 0) : (i -= 1) {
            const cell = try self.allocator.create(LispObject);
            self.gcRegister(cell);
            const cons_cell = try self.allocator.create(ConsCell);

            const car_val = switch (ast[i - 1]) {
                .nil => blk: {
                    const o = try self.allocator.create(LispObject);
                    self.gcRegister(o);
                    o.* = LispObject.nilObj();
                    break :blk o;
                },
                .number => |n| blk: {
                    const o = try self.allocator.create(LispObject);
                    self.gcRegister(o);
                    o.* = LispObject.numberObj(n);
                    break :blk o;
                },
                .symbol => blk: {
                    const o = try self.allocator.create(LispObject);
                    self.gcRegister(o);
                    o.* = LispObject.nilObj();
                    break :blk o;
                },
                .list => blk: {
                    const o = try self.allocator.create(LispObject);
                    self.gcRegister(o);
                    o.* = LispObject.nilObj();
                    break :blk o;
                },
                .string => blk: {
                    const o = try self.allocator.create(LispObject);
                    self.gcRegister(o);
                    const duped = try self.allocator.dupe(u8, ast[i - 1].string);
                    o.* = LispObject.stringObj(duped);
                    break :blk o;
                },
            };

            cons_cell.* = ConsCell{
                .car = car_val,
                .cdr = tail,
            };
            cell.* = LispObject{
                .type = .cons,
                .value = .{ .cons = cons_cell },
                .next = null,
                .marked = false,
            };
            tail = cell;
        }
        return tail;
    }

    /// (quote arg) — return arg unevaluated
    fn _evalQuote(self: *Vm, items: []Expr, env: *Environment) anyerror!*LispObject {
        _ = env;
        if (items.len < 2) return error.QuoteRequiresOneArg;
        const arg = items[1];

        switch (arg) {
            .nil => {
                const obj = try self.allocator.create(LispObject);
                self.gcRegister(obj);
                obj.* = LispObject.nilObj();
                return obj;
            },
            .number => |n| {
                const obj = try self.allocator.create(LispObject);
                self.gcRegister(obj);
                obj.* = LispObject.numberObj(n);
                return obj;
            },
            .symbol => |sym| {
                const obj = try self.allocator.create(LispObject);
                self.gcRegister(obj);
                obj.* = LispObject.symbolObj(sym);
                return obj;
            },
            .list => {
                return try self._buildConsList(arg.list);
            },
            .string => |s| {
                const obj = try self.allocator.create(LispObject);
                self.gcRegister(obj);
                const duped = try self.allocator.dupe(u8, s);
                obj.* = LispObject.stringObj(duped);
                return obj;
            },
        }
    }

    /// (do expr ...) — evaluate all, return last.
    /// TCO: eval() is a while-loop so no recursion stack needed.
    pub fn _evalDo(self: *Vm, items: []Expr, env: *Environment) !*LispObject {
        if (items.len < 2) {
            const obj = try self.allocator.create(LispObject);
            self.gcRegister(obj);
            obj.* = LispObject.nilObj();
            return obj;
        }
        // Evaluate all except last, discard
        var i: usize = 1;
        while (i < items.len - 1) : (i += 1) {
            const res = try self._evalDoAtom(items[i], env);
            self.allocator.destroy(res);
        }
        // Return last value
        return self._evalDoAtom(items[items.len - 1], env);
    }

    /// Internal helper for _evalDo: evaluates an atom without inference-loop risk.
    fn _evalDoAtom(self: *Vm, expr: Expr, env: *Environment) anyerror!*LispObject {
        return self.eval(expr, env);
    }

    /// Error set for _evalCall — explicitly named to avoid circular error union inference
    /// with Vm.eval, which eventually calls _evalCall again.
    pub const CallError = error{OutOfMemory, CallRequiresSymbol, StackUnderflow};

    /// (call func arg1 arg2 ...) — call a function by name without evaluating it first.
    /// Used to dispatch builtins (like <) or closures stored in variables.
    pub fn _evalCall(self: *Vm, items: []Expr, env: *Environment) CallError!*LispObject {
        if (items.len < 2) {
            const obj = try self.allocator.create(LispObject);
            self.gcRegister(obj);
            obj.* = LispObject.nilObj();
            return obj;
        }

        // Get the function expression (NOT evaluated — it's the reference)
        const funcExpr = items[1];
        var funcName: []const u8 = undefined;
        switch (funcExpr) {
            .symbol => |sym| {
                var n: []const u8 = sym.name[0..];
                while (n.len > 0 and n[n.len - 1] == 0) n = n[0 .. n.len - 1];
                funcName = n;
            },
            else => return error.CallRequiresSymbol,
        }

        // Evaluate all remaining args
        const argCount = items.len - 2;
        var evaluatedArgs: [](*LispObject) = (self.allocator.alloc(*LispObject, argCount) catch return error.OutOfMemory);
        defer self.allocator.free(evaluatedArgs);
        var ai: usize = 0;
        while (ai < argCount) : (ai += 1) {
            evaluatedArgs[ai] = (self.eval(items[2 + ai], env) catch return error.OutOfMemory);
        }

        // Try dispatch_table for builtins
        if (self.dispatch_table.get(funcName)) |kind| {
            // Push evaluated args onto stack, then call primitive
            var i: usize = 0;
            while (i < argCount) : (i += 1) {
                self.push(evaluatedArgs[i]);
            }
            // Execute primitive dispatch — catch all errors from anyerror-returning primitives
            switch (kind) {
                .add => { _ = self.primAdd() catch {}; },
                .sub => { _ = self.primSub() catch {}; },
                .mul => { _ = self.primMul() catch {}; },
                .div => { _ = self.primDiv() catch {}; },
                .rem => { _ = self.primRem() catch {}; },
                .bit_and => { _ = self.primBitAnd() catch {}; },
                .bit_or => { _ = self.primBitOr() catch {}; },
                .bit_not => { _ = self.primBitNot() catch {}; },
                .bit_shl => { _ = self.primBitShl() catch {}; },
                .bit_shr => { _ = self.primBitShr() catch {}; },
                .eq => { _ = self.primEq() catch {}; },
                .lt => { _ = self.primLt() catch {}; },
                .gt => { _ = self.primGt() catch {}; },
                .le => { _ = self.primLe() catch {}; },
                .ge => { _ = self.primGe() catch {}; },
                .cons => { _ = self.primCons() catch {}; },
                .car => { _ = self.primCar() catch {}; },
                .cdr => { _ = self.primCdr() catch {}; },
                .print => { _ = self.primPrint() catch {}; },
                .null => { _ = self.primNullQ() catch {}; },
                .not => { _ = self.primNot() catch {}; },
                .symbol => { _ = self.primSymbolQ() catch {}; },
                .number => { _ = self.primNumberQ() catch {}; },
                .list => { _ = self.primListQ() catch {}; },
                .length => { _ = self.primLength() catch {}; },
                .append => { _ = self.primAppend() catch {}; },
                .reverse => { _ = self.primReverse() catch {}; },
                .member => { _ = self.primMember() catch {}; },
                .assoc => { _ = self.primAssoc() catch {}; },
                .map => { _ = self.primMap() catch {}; },
                .filter => { _ = self.primFilter() catch {}; },
                .println => { _ = self.primPrintln() catch {}; },
                .read_line => { _ = self.primReadLine() catch {}; },
                .writeln => { _ = self.primWriteln() catch {}; },
                .load => { _ = self._load(items) catch {}; },
                .import => { _ = self.primImport() catch {}; },
                // Predicate builtins
                .equal => { _ = self.primEqual() catch {}; },
                .even => { _ = self.primEven() catch {}; },
                .odd => { _ = self.primOdd() catch {}; },
                .positive => { _ = self.primPositive() catch {}; },
                .negative => { _ = self.primNegative() catch {}; },
                .type_of => { _ = self.primTypeOf() catch {}; },
                .str => { _ = self.primStr() catch {}; },
                .str_cat => { _ = self.primStrCat() catch {}; },
                .str_len => { _ = self.primStrLen() catch {}; },
                .str_eq => { _ = self.primStrEq() catch {}; },
                .substr => { _ = self.primSubstr() catch {}; },
            }
            return self.pop() orelse {
                const obj = try self.allocator.create(LispObject);
                obj.* = LispObject.nilObj();
                return obj;
            };
        }

        // Try env for a closure or builtin stored in a variable
        const fnVal = env.lookup(funcName) orelse self.rootEnv.lookup(funcName);
        if (fnVal != null) {
            switch (fnVal.?.type) {
                .closure => {
                    const cl = fnVal.?.value.closure;
                    // Manually apply closure with pre-evaluated args (like _applyClosure but without re-evaluating)
                    const childArena = (self.allocator.create(std.heap.ArenaAllocator) catch return error.OutOfMemory);
                    childArena.* = std.heap.ArenaAllocator.init(self.allocator);
                    const childEnv = (self.allocator.create(Environment) catch return error.OutOfMemory);
                    childEnv.* = Environment.init(cl.env, childArena.allocator());
                    errdefer childArena.deinit();
                    errdefer {
                        childEnv.deinit();
                        self.allocator.destroy(childEnv);
                    }

                    // Bind parameters
                    const bindCount = if (cl.params.len < argCount) cl.params.len else argCount;
                    var bi: usize = 0;
                    while (bi < bindCount) : (bi += 1) {
                        var paramName: []const u8 = cl.params[bi].name[0..];
                        while (paramName.len > 0 and paramName[paramName.len - 1] == 0) {
                            paramName = paramName[0 .. paramName.len - 1];
                        }
                        _ = childEnv.bind(paramName, evaluatedArgs[bi]) catch {};
                    }

                    // Evaluate body
                    var result: *LispObject = (self.allocator.create(LispObject) catch return error.OutOfMemory);
                    result.* = LispObject.nilObj();
                    var i: usize = 0;
                    while (i < cl.body.len) : (i += 1) {
                        if (i > 0) self.allocator.destroy(result);
                        result = (self.eval(cl.body[i], childEnv) catch return error.OutOfMemory);
                    }
                    return result;
                },
                .builtin => {
                    // A builtin was stored in a variable (e.g., passing < to a higher-order function)
                    const builtinName = fnVal.?.value.builtin;
                    if (self.dispatch_table.get(builtinName)) |kind| {
                        var i: usize = 0;
                        while (i < argCount) : (i += 1) {
                            self.push(evaluatedArgs[i]);
                        }
                        switch (kind) {
                            .add => { _ = self.primAdd() catch {}; },
                            .sub => { _ = self.primSub() catch {}; },
                            .mul => { _ = self.primMul() catch {}; },
                            .div => { _ = self.primDiv() catch {}; },
                            .rem => { _ = self.primRem() catch {}; },
                            .bit_and => { _ = self.primBitAnd() catch {}; },
                            .bit_or => { _ = self.primBitOr() catch {}; },
                            .bit_not => { _ = self.primBitNot() catch {}; },
                            .bit_shl => { _ = self.primBitShl() catch {}; },
                            .bit_shr => { _ = self.primBitShr() catch {}; },
                            .eq => { _ = self.primEq() catch {}; },
                            .lt => { _ = self.primLt() catch {}; },
                            .gt => { _ = self.primGt() catch {}; },
                            .le => { _ = self.primLe() catch {}; },
                            .ge => { _ = self.primGe() catch {}; },
                            .cons => { _ = self.primCons() catch {}; },
                            .car => { _ = self.primCar() catch {}; },
                            .cdr => { _ = self.primCdr() catch {}; },
                            .print => { _ = self.primPrint() catch {}; },
                            .null => { _ = self.primNullQ() catch {}; },
                            .not => { _ = self.primNot() catch {}; },
                            .symbol => { _ = self.primSymbolQ() catch {}; },
                            .number => { _ = self.primNumberQ() catch {}; },
                            .list => { _ = self.primListQ() catch {}; },
                            .length => { _ = self.primLength() catch {}; },
                            .append => { _ = self.primAppend() catch {}; },
                            .reverse => { _ = self.primReverse() catch {}; },
                            .member => { _ = self.primMember() catch {}; },
                            .assoc => { _ = self.primAssoc() catch {}; },
                            .map => { _ = self.primMap() catch {}; },
                            .filter => { _ = self.primFilter() catch {}; },
                            .println => { _ = self.primPrintln() catch {}; },
                            .read_line => { _ = self.primReadLine() catch {}; },
                            .writeln => { _ = self.primWriteln() catch {}; },
                            .load => { _ = self._load(items) catch {}; },
                            .import => { _ = self.primImport() catch {}; },
                            // Predicate builtins
                            .equal => { _ = self.primEqual() catch {}; },
                            .even => { _ = self.primEven() catch {}; },
                            .odd => { _ = self.primOdd() catch {}; },
                            .positive => { _ = self.primPositive() catch {}; },
                            .negative => { _ = self.primNegative() catch {}; },
                            .type_of => { _ = self.primTypeOf() catch {}; },
                            .str => { _ = self.primStr() catch {}; },
                            .str_cat => { _ = self.primStrCat() catch {}; },
                            .str_len => { _ = self.primStrLen() catch {}; },
                            .str_eq => { _ = self.primStrEq() catch {}; },
                            .substr => { _ = self.primSubstr() catch {}; },
                        }
                        return self.pop() orelse {
                            const obj = try self.allocator.create(LispObject);
                            obj.* = LispObject.nilObj();
                            return obj;
                        };
                    }
                },
                else => {},
            }
        }

        // Not found — return nil (like missing symbol lookup)
        const obj = try self.allocator.create(LispObject);
        self.gcRegister(obj);
        obj.* = LispObject.nilObj();
        return obj;
    }

    /// (if test then else?) — conditional dispatch.
    /// TCO: eval() is a while-loop so no recursion stack needed.
    pub fn _evalIf(self: *Vm, items: []Expr, env: *Environment) !*LispObject {
        if (items.len < 3) return error.IfRequiresAtLeastTwoArgs;
        const testVal = try self._evalIfAtom(items[1], env);
        defer self.allocator.destroy(testVal);
        const taken = testVal.type != .nil and !(testVal.type == .number and testVal.value.number == 0);
        if (taken) {
            if (items.len > 2) return self._evalIfAtom(items[2], env);
            const obj = try self.allocator.create(LispObject);
            self.gcRegister(obj);
            obj.* = LispObject.nilObj();
            return obj;
        } else {
            if (items.len > 3) return self._evalIfAtom(items[3], env);
            const obj = try self.allocator.create(LispObject);
            self.gcRegister(obj);
            obj.* = LispObject.nilObj();
            return obj;
        }
    }

    fn _evalIfAtom(self: *Vm, expr: Expr, env: *Environment) anyerror!*LispObject {
        return self.eval(expr, env);
    }

    /// (cond (test expr) (test expr) ...) — sequential matching.
    /// TCO: eval() is a while-loop so no recursion stack needed.
    pub fn _evalCond(self: *Vm, items: []Expr, env: *Environment) !*LispObject {
        var i: usize = 1;
        while (i + 1 < items.len) {
            const testVal = try self._evalCondAtom(items[i], env);
            defer self.allocator.destroy(testVal);
            if (testVal.type != .nil and !(testVal.type == .number and testVal.value.number == 0)) {
                return self._evalCondAtom(items[i + 1], env);
            }
            i += 2;
        }
        const obj = try self.allocator.create(LispObject);
        self.gcRegister(obj);
        obj.* = LispObject.nilObj();
        return obj;
    }

    fn _evalCondAtom(self: *Vm, expr: Expr, env: *Environment) anyerror!*LispObject {
        return self.eval(expr, env);
    }

    /// (let ((name val) ...) body...) — sequential local bindings.
    /// Creates a child environment with a dedicated arena for automatic cleanup.
    pub fn _evalLet(self: *Vm, items: []Expr, env: *Environment) anyerror!*LispObject {
        if (items.len < 3) return error.LetRequiresBindingsAndBody;

        const bindingsExpr = items[1];
        const bodyExprs = items[2..];

        // Bindings must be a list: ((name val) (name val) ...)
        switch (bindingsExpr) {
            .list => |bindingsList| {
                // Allocate a dedicated arena for this let scope
                const childArena = try self.allocator.create(std.heap.ArenaAllocator);
                childArena.* = std.heap.ArenaAllocator.init(self.allocator);
                errdefer self.allocator.destroy(childArena);

                // Create child environment
                const childEnv = try self.allocator.create(Environment);
                childEnv.* = Environment.init(env, childArena.allocator());
                errdefer self.allocator.destroy(childEnv);

                // Evaluate bindings sequentially (each binding sees previous ones)
                var bi: usize = 0;
                while (bi < bindingsList.len) : (bi += 1) {
                    const pairExpr = bindingsList[bi];
                    switch (pairExpr) {
                        .list => |pair| {
                            if (pair.len >= 2) {
                                switch (pair[0]) {
                                    .symbol => |sym| {
                                        var name: []const u8 = sym.name[0..];
                                        while (name.len > 0 and name[name.len - 1] == 0) {
                                            name = name[0 .. name.len - 1];
                                        }
                                        // Evaluate value in current let env
                                        const valObj = try self.eval(pair[1], childEnv);
                                        errdefer self.allocator.destroy(valObj);
                                        try childEnv.bind(name, valObj);
                                    },
                                    else => {},
                                }
                            }
                        },
                        else => {},
                    }
                }

                // Evaluate body
                const result: *LispObject = try self.allocator.create(LispObject);
                result.* = LispObject.nilObj();
                var i: usize = 0;
                while (i < bodyExprs.len) : (i += 1) {
                    if (i + 1 < bodyExprs.len) {
                        const tmp = try self.eval(bodyExprs[i], childEnv);
                        self.allocator.destroy(tmp);
                    } else {
                        result.* = (try self.eval(bodyExprs[i], childEnv)).*;
                    }
                }

                // Cleanup
                childEnv.deinit();
                self.allocator.destroy(childEnv);
                childArena.deinit();
                self.allocator.destroy(childArena);

                return result;
            },
            else => return error.LetBindingsMustBeList,
        }
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
        const body = try self.deepCopyExprList(bodyExprs);

        // Create closure
        const closure = try self.allocator.create(Closure);
        closure.* = Closure{
            .params = paramArr,
            .body = body,
            .env = env,
            .is_macro = false,
        };

        // Wrap in LispObject
        const obj = try self.allocator.create(LispObject);
        self.gcRegister(obj);
        obj.* = LispObject{
            .type = .closure,
            .value = .{ .closure = closure },
            .next = null,
            .marked = false,
        };
        return obj;
    }

    /// Deep copy an Expr list to page_allocator. Handles nested lists.
    pub fn deepCopyExprList(self: *Vm, exprs: []Expr) ![]Expr {
        const copy = try self.allocator.alloc(Expr, exprs.len);
        var i: usize = 0;
        while (i < exprs.len) {
            const e = exprs[i];
            switch (e) {
                .nil => copy[i] = Expr.nilExpr(),
                .number => |n| copy[i] = Expr{ .number = n },
                .symbol => |s| copy[i] = Expr{ .symbol = s },
                .list => |items| {
                    const nested = try self.deepCopyExprList(items);
                    copy[i] = Expr{ .list = nested };
                },
                .string => |s| {
                    copy[i] = Expr{ .string = s };
                },
            }
            i += 1;
        }
        return copy;
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

    /// (defmacro name (params...) body...) — like defn but creates a macro.
    pub fn evalDefmacro(self: *Vm, items: []Expr, env: *Environment) !*LispObject {
        if (items.len < 4) return error.DefmacroRequiresNameParamsAndBody;

        const paramsExpr = items[2];
        const bodyExprs = items[3..];

        // Build fn-like items: [fn, params, body1, body2, ...]
        const fnItems: []Expr = try self.allocator.alloc(Expr, 2 + bodyExprs.len);
        defer self.allocator.free(fnItems);

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

        // Create the closure via evalFn
        const closureObj = try self.evalFn(fnItems, env);
        closureObj.value.closure.is_macro = true;

        // Bind to environment
        var name: []const u8 = items[1].symbol.name[0..];
        while (name.len > 0 and name[name.len - 1] == 0) {
            name = name[0 .. name.len - 1];
        }
        try self.rootEnv.bind(name, closureObj);
        return closureObj;
    }

    /// (defpackage pkg-name) — register a package in the package table.
    /// The name is a symbol; e.g., (defpackage my-pkg).
    pub fn evalDefpackage(self: *Vm, items: []Expr) anyerror!*LispObject {
        if (items.len < 2) return error.DefpackageRequiresName;

        // Extract the package name from the second item (must be a symbol)
        var pkgName: []const u8 = "";
        switch (items[1]) {
            .symbol => |sym| {
                pkgName = sym.name[0..];
                while (pkgName.len > 0 and pkgName[pkgName.len - 1] == 0) {
                    pkgName = pkgName[0 .. pkgName.len - 1];
                }
            },
            else => return error.DefpackageRequiresSymbol,
        }

        // Store the package name in the package table
        const dupedName = try self.allocator.dupe(u8, pkgName);
        try self.packageTable.put(dupedName, dupedName);

        // Create a nil LispObject to return
        const obj = try self.allocator.create(LispObject);
        self.gcRegister(obj);
        obj.* = LispObject.nilObj();
        return obj;
    }

    /// Apply a closure: create child env, bind params, evaluate body.
    /// Uses anyerror wrapper to break eval <-> applyClosure inference loop.
    pub fn applyClosure(self: *Vm, cl: *Closure, args: []Expr, env: *Environment) !*LispObject {
        return self._applyClosure(cl, args, env);
    }

    fn _applyClosure(self: *Vm, cl: *Closure, args: []Expr, env: *Environment) anyerror!*LispObject {
        // Evaluate args first
        const argCount = if (args.len > cl.params.len) cl.params.len else args.len;
        const evaluatedArgs = try self.allocator.alloc(*LispObject, argCount);
        defer self.allocator.free(evaluatedArgs);
        var ai: usize = 0;
        while (ai < argCount) : (ai += 1) {
            evaluatedArgs[ai] = try self.eval(args[ai], env);
        }

        // Create child environment
        const childArena = try self.allocator.create(std.heap.ArenaAllocator);
        childArena.* = std.heap.ArenaAllocator.init(self.allocator);
        const childEnv = try self.allocator.create(Environment);
        childEnv.* = Environment.init(cl.env, childArena.allocator());
        errdefer childArena.deinit();
        errdefer {
            childEnv.deinit();
            self.allocator.destroy(childEnv);
        }

        // Bind parameters
        var ai2: usize = 0;
        while (ai2 < cl.params.len and ai2 < argCount) : (ai2 += 1) {
            var paramName: []const u8 = cl.params[ai2].name[0..];
            while (paramName.len > 0 and paramName[paramName.len - 1] == 0) {
                paramName = paramName[0 .. paramName.len - 1];
            }
            try childEnv.bind(paramName, evaluatedArgs[ai2]);
        }

        // Evaluate body sequentially, return last value
        var result: *LispObject = try self.allocator.create(LispObject);
        result.* = LispObject.nilObj();
        var i: usize = 0;
        while (i < cl.body.len) : (i += 1) {
            if (i > 0) self.allocator.destroy(result);
            result = try self.eval(cl.body[i], childEnv);
        }
        
        return result;
    }

    /// Apply a macro: create child env, bind unevaluated args as Expr, evaluate body.
    /// Returns the unevaluated result Expr (for TCO re-entry into eval loop).
    pub fn applyMacro(self: *Vm, cl: *Closure, args: []Expr, env: *Environment) !Expr {
        return self._applyMacro(cl, args, env);
    }

    fn _applyMacro(self: *Vm, cl: *Closure, args: []Expr, env: *Environment) anyerror!Expr {
        // Store macro args in Vm.macroArgs for evalAtom to find
        var ai: usize = 0;
        while (ai < cl.params.len and ai < args.len) : (ai += 1) {
            var paramName: []const u8 = cl.params[ai].name[0..];
            while (paramName.len > 0 and paramName[paramName.len - 1] == 0) {
                paramName = paramName[0 .. paramName.len - 1];
            }
            // Deep copy the Expr so it survives macro args clearing
            const copied = try self.arenaDupExpr(args[ai]);
            try self.macroArgs.put(paramName, copied);
        }
        defer self.macroArgs.clearRetainingCapacity();

        // Evaluate body sequentially in the macro's parent environment
        var result: Expr = Expr.nilExpr();
        var i: usize = 0;
        while (i < cl.body.len) : (i += 1) {
            // Evaluate this body expression
            const obj = try self.eval(cl.body[i], env);
            defer self.allocator.destroy(obj);
            result = try self._lispObjToExpr(obj);
        }

        return result;
    }

    /// Deep-copy an Expr into heap-allocated memory.
    fn arenaDupExpr(self: *Vm, expr: Expr) !Expr {
        return switch (expr) {
            .nil => Expr.nilExpr(),
            .number => |n| Expr{ .number = n },
            .symbol => |sym| Expr{ .symbol = sym },
            .string => |s| Expr{ .string = s },
            .list => |items| blk: {
                const duped = try self.allocator.dupe(Expr, items);
                break :blk Expr{ .list = duped };
            },
        };
    }

    /// Convert a LispObject into an Expr for macro expansion.
    fn _lispObjToExpr(self: *Vm, obj: *LispObject) anyerror!Expr {
        return switch (obj.value) {
            .nil => Expr.nilExpr(),
            .number => |n| Expr{ .number = n },
            .symbol => |sym| Expr{ .symbol = sym },
            .cons => blk: {
                var list = try std.ArrayList(Expr).initCapacity(self.allocator, 4);
                errdefer list.deinit(self.allocator);
                var cur: *LispObject = obj;
                while (cur.type == .cons) {
                    const cell = cur.value.cons;
                    const car_expr = try self._lispObjToExpr(cell.car);
                    try list.append(self.allocator, car_expr);
                    cur = cell.cdr;
                }
                // If cdr is not nil (dotted list), append it as the last element
                if (cur.type != .nil) {
                    const expr = try self._lispObjToExpr(cur);
                    try list.append(self.allocator, expr);
                }
                const owned = try list.toOwnedSlice(self.allocator);
                break :blk Expr{ .list = owned };
            },
            else => Expr.nilExpr(),
        };
    }

    /// Full eval with tail-call optimization via while-loop.
    /// Replaces the recursive eval with a while-loop: all self.eval() calls
    /// re-enter the same loop instead of pushing new stack frames.
    pub fn eval(self: *Vm, expr: Expr, env: *Environment) !*LispObject {
        var current: Expr = expr;
        while (true) {
            switch (current) {
                .nil => {
                    const obj = try self.allocator.create(LispObject);
                    self.gcRegister(obj);
                    obj.* = LispObject.nilObj();
                    return obj;
                },
                .number => |n| {
                    const obj = try self.allocator.create(LispObject);
                    self.gcRegister(obj);
                    obj.* = LispObject.numberObj(n);
                    return obj;
                },
                .string => |s| {
                    const obj = try self.allocator.create(LispObject);
                    self.gcRegister(obj);
                    obj.* = LispObject.stringObj(s);
                    return obj;
                },
                .symbol => |sym| {
                    // Check macroArgs first (for macro parameter expansion)
                    var macroName: []const u8 = sym.name[0..];
                    while (macroName.len > 0 and macroName[macroName.len - 1] == 0) {
                        macroName = macroName[0 .. macroName.len - 1];
                    }
                    if (self.macroArgs.get(macroName)) |argExpr| {
                        return try self._exprToObj(argExpr);
                    }
                    if (env.lookup(sym.name)) |v| return v;
                    if (self.rootEnv.lookup(sym.name)) |v| return v;
                    const obj = try self.allocator.create(LispObject);
                    self.gcRegister(obj);
                    obj.* = LispObject.nilObj();
                    return obj;
                },
                .list => |items| {
                    if (items.len == 0) {
                        const obj = try self.allocator.create(LispObject);
                        self.gcRegister(obj);
                        obj.* = LispObject.nilObj();
                        return obj;
                    }
                    const head = items[0];
                    const headName = switch (head) {
                        .symbol => |sym| sym.name,
                        else => "",
                    };
                    // Strip nulls for comparison
                    var clean: []const u8 = headName[0..];
                    while (clean.len > 0 and clean[clean.len - 1] == 0) clean = clean[0 .. clean.len - 1];

                    // --- Special forms (exact match) ---
                    const isDef = std.mem.eql(u8, clean, "def");
                    const isDefn = std.mem.eql(u8, clean, "defn");
                    const isDo = std.mem.eql(u8, clean, "do");
                    const isFn = std.mem.eql(u8, clean, "fn");
                    const isIf = std.mem.eql(u8, clean, "if");
                    const isCond = std.mem.eql(u8, clean, "cond");
                    const isQuote = std.mem.eql(u8, clean, "quote");
                    const isLet = std.mem.eql(u8, clean, "let");
                    const isDefmacro = std.mem.eql(u8, clean, "defmacro");
                    const isDefpackage = std.mem.eql(u8, clean, "defpackage");

                    if (isDef) {
                        if (items.len < 3) return error.DefRequiresTwoArgs;
                        const name: []const u8 = switch (items[1]) {
                            .symbol => |sym| sym.name,
                            else => return error.DefInvalidName,
                        };
                        const val = try self.eval(items[2], env);
                        try self.rootEnv.bind(name, val);
                        return val;
                    }
                    if (isFn) return try self.evalFn(items, env);
                    if (isDefn) return try self.evalDefn(items, env);
                    if (isDefpackage) return try self.evalDefpackage(items);

                    if (isDo) return try self._evalDo(items, env);
                    if (isIf) return try self._evalIf(items, env);
                    if (isCond) return try self._evalCond(items, env);
                    if (isQuote) return try self._evalQuote(items, env);
                    if (isLet) return try self._evalLet(items, env);
                    if (isDefmacro) return try self.evalDefmacro(items, env);
                    if (std.mem.eql(u8, clean, "call")) return try self._evalCall(items, env);

                    // --- Closure application (TCO) ---
                    var closureResult: ?*LispObject = null;
                    var macroExpandedExpr: ?Expr = null;
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
                                const cl = fnVal.?.value.closure;
                                if (cl.is_macro) {
                                    // Macro: pass UNEVALUATED args, get back an Expr
                                    macroExpandedExpr = try self.applyMacro(cl, argExprs, env);
                                } else {
                                    closureResult = try self.applyClosure(cl, argExprs, env);
                                }
                            }
                        },
                        else => {},
                    }

                    // TCO for macro expansion: if a macro returned an Expr, loop with it
                    if (macroExpandedExpr) |expanded| {
                        current = expanded;
                        continue;
                    }

                    if (closureResult) |cr| {
                        // We already have a LispObject result from applyClosure
                        // But for TCO we want to loop through the body.
                        // Since applyClosure already evaluated the body, just return.
                        return cr;
                    }

                    // --- Primitives: push evaluated args, dispatch via O(1) table lookup ---
                    var ai: usize = 1;
                    while (ai < items.len) : (ai += 1) {
                        const arg = try self.eval(items[ai], env);
                        self.push(arg);
                    }

                    // O(1) dispatch: hash map replaces 22+ string comparisons
                    if (clean.len > 0) {
    
                        if (self.dispatch_table.get(clean)) |kind| {
                            switch (kind) {
                                .add => try self.primAdd(),
                                .sub => try self.primSub(),
                                .mul => try self.primMul(),
                                .div => try self.primDiv(),
                                .rem => try self.primRem(),
                                .bit_and => try self.primBitAnd(),
                                .bit_or => try self.primBitOr(),
                                .bit_not => try self.primBitNot(),
                                .bit_shl => try self.primBitShl(),
                                .bit_shr => try self.primBitShr(),
                                .eq => try self.primEq(),
                                .lt => try self.primLt(),
                                .gt => try self.primGt(),
                                .le => try self.primLe(),
                                .ge => try self.primGe(),
                                .cons => try self.primCons(),
                                .car => try self.primCar(),
                                .cdr => try self.primCdr(),
                                .print => try self.primPrint(),
                                .null => try self.primNullQ(),
                                .not => try self.primNot(),
                                .symbol => try self.primSymbolQ(),
                                .number => try self.primNumberQ(),
                                .list => try self.primListQ(),
                                .length => try self.primLength(),
                                .append => try self.primAppend(),
                                .reverse => try self.primReverse(),
                                .member => try self.primMember(),
                                .assoc => try self.primAssoc(),
                                .map => try self.primMap(),
                                .filter => try self.primFilter(),
                                .println => try self.primPrintln(),
                                .writeln => try self.primWriteln(),
                                .read_line => try self.primReadLine(),
                                .load => try self._load(items),
                                .import => try self.primImport(),
                                // Predicate builtins
                                .equal => try self.primEqual(),
                                .even => try self.primEven(),
                                .odd => try self.primOdd(),
                                .positive => try self.primPositive(),
                                .negative => try self.primNegative(),
.type_of => try self.primTypeOf(),
                            .str => try self.primStr(),
                            .str_cat => try self.primStrCat(),
                            .str_len => try self.primStrLen(),
                            .str_eq => try self.primStrEq(),
                            .substr => try self.primSubstr(),
                        }
                        return self.pop() orelse {
                            const obj = try self.allocator.create(LispObject);
                            obj.* = LispObject.nilObj();
                            return obj;
                        };
                    }
                }

                // Unknown function — pop args that were pushed

                    ai = 1;
                    while (ai < items.len) : (ai += 1) {
                        const top = self.pop();
                        if (top) |t| self.allocator.destroy(t);
                    }
                    const obj = try self.allocator.create(LispObject);
                    obj.* = LispObject.nilObj();
                    return obj;
                },
            }
        }
    }

    /// Execute bytecode and return the result
    pub fn executeBytecode(self: *Vm, bc: *Bytecode, env: *Environment) !*LispObject {
        var pc: usize = 0;
        var current_env = env;

        while (pc < bc.ops.items.len) {
            const op = @as(Opcode, @enumFromInt(bc.ops.items[pc]));
            pc += 1;

            switch (op) {
                .nil => {
                    const obj = try self.allocator.create(LispObject);
                    self.gcRegister(obj);
                    obj.* = LispObject.nilObj();
                    self.push(obj);
                },
                .number => {
                    const n: i64 = @as(i64, bc.ops.items[pc]) |
                        (@as(i64, bc.ops.items[pc + 1]) << 8) |
                        (@as(i64, bc.ops.items[pc + 2]) << 16) |
                        (@as(i64, bc.ops.items[pc + 3]) << 24) |
                        (@as(i64, bc.ops.items[pc + 4]) << 32) |
                        (@as(i64, bc.ops.items[pc + 5]) << 40) |
                        (@as(i64, bc.ops.items[pc + 6]) << 48) |
                        (@as(i64, bc.ops.items[pc + 7]) << 56);
                    pc += 8;
                    const obj = try self.allocator.create(LispObject);
                    self.gcRegister(obj);
                    obj.* = LispObject.numberObj(n);
                    self.push(obj);
                },
                .symbol => {
                    const idx: u32 = @as(u32, bc.ops.items[pc]) |
                        (@as(u32, bc.ops.items[pc + 1]) << 8) |
                        (@as(u32, bc.ops.items[pc + 2]) << 16) |
                        (@as(u32, bc.ops.items[pc + 3]) << 24);
                    pc += 4;
                    // Push the constant value (symbol or builtin reference)
                    const symObj = bc.getConstant(idx);
                    if (symObj == null) {
                        debugPrint("const_val: constant not found at idx {d}\n", .{idx});
                        const obj = try self.allocator.create(LispObject);
                        self.gcRegister(obj);
                        obj.* = LispObject.nilObj();
                        self.push(obj);
                        continue;
                    }
                    debugPrint("const_val: found constant, type={s}\n", .{@tagName(symObj.?.type)});
                    // If it's a builtin name, push the builtin object
                    if (self.dispatch_table.get(symObj.?.value.symbol.name[0..])) |_| {
                        debugPrint("const_val: creating builtin object for '{s}'\n", .{symObj.?.value.symbol.name[0..]});
                        const builtinObj = try self.allocator.create(LispObject);
                        self.gcRegister(builtinObj);
                        builtinObj.* = LispObject{
                            .type = .builtin,
                            .value = .{ .builtin = symObj.?.value.symbol.name[0..] },
                            .next = null,
                            .marked = false,
                        };
                        self.push(builtinObj);
                    } else {
                        // Regular symbol — look up in environment
                        if (current_env.lookup(symObj.?.value.symbol.name[0..])) |val| {
                            self.push(val);
                        } else if (self.rootEnv.lookup(symObj.?.value.symbol.name[0..])) |val| {
                            self.push(val);
                        } else {
                            const obj = try self.allocator.create(LispObject);
                            self.gcRegister(obj);
                            obj.* = LispObject.nilObj();
                            self.push(obj);
                        }
                    }
                },
                .const_val => {
                    const idx: u32 = @as(u32, bc.ops.items[pc]) | (@as(u32, bc.ops.items[pc + 1]) << 8) |
                        (@as(u32, bc.ops.items[pc + 2]) << 16) | (@as(u32, bc.ops.items[pc + 3]) << 24);
                    pc += 4;
                    debugPrint("const_val: idx={d}, bc.constants.items.len={d}\n", .{ idx, bc.constants.items.len });
                    const val: ?*LispObject = if (idx < self.bytecode_compile_constants.items.len)
                        self.bytecode_compile_constants.items[idx]
                    else
                        null;
                    if (val == null) {
                        debugPrint("const_val: constant not found at idx {d}\n", .{idx});
                        const obj = try self.allocator.create(LispObject);
                        self.gcRegister(obj);
                        obj.* = LispObject.nilObj();
                        self.push(obj);
                        continue;
                    }
                    if (val) |v| {
                        self.push(v);
                    }
                },
                .jump => {
                    const offset = @as(u32, bc.ops.items[pc]) | (@as(u32, bc.ops.items[pc + 1]) << 8) | (@as(u32, bc.ops.items[pc + 2]) << 16) | (@as(u32, bc.ops.items[pc + 3]) << 24);
                    pc += 4;
                    pc = offset;
                },
                .jump_if_false => {
                    const offset = @as(u32, bc.ops.items[pc]) | (@as(u32, bc.ops.items[pc + 1]) << 8) | (@as(u32, bc.ops.items[pc + 2]) << 16) | (@as(u32, bc.ops.items[pc + 3]) << 24);
                    pc += 4;
                    const top = self.peek();
                    if (top == null or top.?.type == .nil) {
                        pc = offset;
                    }
                },
                .def => {
                    const idx = @as(u32, bc.ops.items[pc]) | (@as(u32, bc.ops.items[pc + 1]) << 8) | (@as(u32, bc.ops.items[pc + 2]) << 16) | (@as(u32, bc.ops.items[pc + 3]) << 24);
                    pc += 4;
                    const val = self.pop() orelse return error.StackUnderflow;
                    const symObj = bc.getConstant(idx) orelse return error.UndefinedVariable;
                    try current_env.bind(symObj.value.symbol.name[0..], val);
                },
                .defn => {
                    const idx = @as(u32, bc.ops.items[pc]) | (@as(u32, bc.ops.items[pc + 1]) << 8) | (@as(u32, bc.ops.items[pc + 2]) << 16) | (@as(u32, bc.ops.items[pc + 3]) << 24);
                    pc += 4;
                    const val = self.pop() orelse return error.StackUnderflow;
                    const symObj = if (idx < self.bytecode_constants.items.len)
                        self.bytecode_constants.items[idx]
                    else
                        bc.getConstant(idx);
                    if (symObj == null) return error.UndefinedVariable;
                    debugPrint("DEFN: binding {s} = type={s}\n", .{
                        symObj.?.value.symbol.name[0..],
                        @tagName(val.type),
                    });
                    try current_env.bind(symObj.?.value.symbol.name[0..], val);
                },
                .let => {
                    const startIdx = @as(u32, bc.ops.items[pc]) | (@as(u32, bc.ops.items[pc + 1]) << 8) | (@as(u32, bc.ops.items[pc + 2]) << 16) | (@as(u32, bc.ops.items[pc + 3]) << 24);
                    const count = @as(u32, bc.ops.items[pc + 4]) | (@as(u32, bc.ops.items[pc + 5]) << 8) | (@as(u32, bc.ops.items[pc + 6]) << 16) | (@as(u32, bc.ops.items[pc + 7]) << 24);
                    pc += 8;
                    // Create child environment
                    var childEnv = current_env.child(self.allocator);
                    errdefer childEnv.deinit();
                    // Pop values and bind them using the stored constant indices
                    var i: u32 = 0;
                    while (i < count) : (i += 1) {
                        const val = self.pop() orelse return error.StackUnderflow;
                        const symObj = bc.getConstant(startIdx + i) orelse return error.UndefinedVariable;
                        try childEnv.bind(symObj.value.symbol.name[0..], val);
                    }
                    current_env = &childEnv;
                },
                .iff => {
                    const elseOffset = @as(u32, bc.ops.items[pc]) | (@as(u32, bc.ops.items[pc + 1]) << 8) | (@as(u32, bc.ops.items[pc + 2]) << 16) | (@as(u32, bc.ops.items[pc + 3]) << 24);
                    pc += 4;
                    const top = self.peek();
                    if (top == null or top.?.type == .nil) {
                        pc = @as(usize, elseOffset);
                    }
                },
                .quote => {
                    const idx: usize = @as(u32, bc.ops.items[pc]) | (@as(u32, bc.ops.items[pc + 1]) << 8) | (@as(u32, bc.ops.items[pc + 2]) << 16) | (@as(u32, bc.ops.items[pc + 3]) << 24);
                    pc += 4;
                    const val = if (idx < self.bytecode_constants.items.len)
                        self.bytecode_constants.items[idx]
                    else
                        bc.getConstant(@as(u32, @intCast(idx)));
                    if (val == null) {
                        const obj = try self.allocator.create(LispObject);
                        self.gcRegister(obj);
                        obj.* = LispObject.nilObj();
                        self.push(obj);
                        continue;
                    }
                    self.push(val.?);
                },
                .do => {
                    const count = @as(u32, bc.ops.items[pc]) | (@as(u32, bc.ops.items[pc + 1]) << 8) | (@as(u32, bc.ops.items[pc + 2]) << 16) | (@as(u32, bc.ops.items[pc + 3]) << 24);
                    pc += 4;
                    // Do is handled by the compiler — just skip the expressions
                    _ = count;
                },
                .call => {
                    const argCount: u8 = @intCast(bc.ops.items[pc]);
                    pc += 1;
                    // Pop function (it's on top of args)
                    const fnVal = self.pop() orelse return error.StackUnderflow;
                    debugPrint("EXEC call: fnVal.type={s}, argCount={d}\n", .{ @tagName(fnVal.type), argCount });
                    // Apply function
                    switch (fnVal.value) {
                        .builtin => |name| {
                            debugPrint("EXEC builtin name='{s}'\n", .{name[0..]});
                            // Dispatch to builtin
                            if (self.dispatch_table.get(name)) |kind| {
                                switch (kind) {
                                    .add => try self.primAdd(),
                                    .sub => try self.primSub(),
                                    .mul => try self.primMul(),
                                    .div => try self.primDiv(),
                                    .rem => try self.primRem(),
                                    .bit_and => try self.primBitAnd(),
                                    .bit_or => try self.primBitOr(),
                                    .bit_not => try self.primBitNot(),
                                    .bit_shl => try self.primBitShl(),
                                    .bit_shr => try self.primBitShr(),
                                    .eq => try self.primEq(),
                                    .lt => try self.primLt(),
                                    .gt => try self.primGt(),
                                    .le => try self.primLe(),
                                    .ge => try self.primGe(),
                                    .cons => try self.primCons(),
                                    .car => try self.primCar(),
                                    .cdr => try self.primCdr(),
                                    .print => try self.primPrint(),
                                    .null => try self.primNullQ(),
                                    .not => try self.primNot(),
                                    .symbol => try self.primSymbolQ(),
                                    .number => try self.primNumberQ(),
                                    .list => try self.primListQ(),
                                    .length => try self.primLength(),
                                    .append => try self.primAppend(),
                                    .reverse => try self.primReverse(),
                                    .member => try self.primMember(),
                                    .assoc => try self.primAssoc(),
                                    .map => try self.primMap(),
                                    .filter => try self.primFilter(),
                                    .equal => try self.primEqual(),
                                    .even => try self.primEven(),
                                    .odd => try self.primOdd(),
                                    .positive => try self.primPositive(),
                                    .negative => try self.primNegative(),
                                    .type_of => try self.primTypeOf(),
                                    .println => try self.primPrintln(),
                                    .writeln => try self.primWriteln(),
                                    .read_line => try self.primReadLine(),
                                    .str => try self.primStr(),
                                    .str_cat => try self.primStrCat(),
                                    .str_len => try self.primStrLen(),
                                    .str_eq => try self.primStrEq(),
                                    .substr => try self.primSubstr(),
                                    else => {},
                                }
                            }
                        },
                        .closure => {
                            // Extract body index and param chain from closure's next chain
                            const bodyIdxObj = fnVal.next;
                            const paramChain = if (bodyIdxObj) |bi| bi.next else null;
                            const bodyIdx: u32 = if (bodyIdxObj) |bi|
                                if (bi.type == .number) @intCast(bi.value.number)
                                else 0
                            else 0;

                            // Pop args
                            var args: [16]*LispObject = undefined;
                            var ai: usize = 0;
                            while (ai < argCount) : (ai += 1) {
                                args[argCount - 1 - ai] = self.pop() orelse return error.StackUnderflow;
                            }

                            // Create child env and bind args to params
                            var childEnv = current_env.child(self.allocator);
                            errdefer childEnv.deinit();
                            var paramPtr = paramChain;
                            var argIdx: usize = 0;
                            while (argIdx < argCount) {
                                if (paramPtr) |p| {
                                    const paramName = p.value.symbol.name[0..];
                                    debugPrint("  binding {s} = {s}\n", .{ paramName, @tagName(args[argIdx].type) });
                                    try childEnv.bind(paramName, args[argIdx]);
                                    paramPtr = p.next;
                                }
                                argIdx += 1;
                            }

                            // Execute body from separate bytecode array
                            // Execute body from separate bytecode array
                            if (bodyIdx < bc.closure_bodies.items.len) {
                                const bodyOps = &bc.closure_bodies.items[bodyIdx];
                                // Execute body opcodes
                                var bodyPc: usize = 0;
                                while (bodyPc < bodyOps.items.len) {
                                    const bodyOp = @as(Opcode, @enumFromInt(bodyOps.items[bodyPc]));
                                    bodyPc += 1;

                                    switch (bodyOp) {
                                        .nil => {
                                            const obj = try self.allocator.create(LispObject);
                                            self.gcRegister(obj);
                                            obj.* = LispObject.nilObj();
                                            self.push(obj);
                                        },
                                        .number => {
                                            const n: i64 = @as(i64, bodyOps.items[bodyPc]) |
                                                (@as(i64, bodyOps.items[bodyPc + 1]) << 8) |
                                                (@as(i64, bodyOps.items[bodyPc + 2]) << 16) |
                                                (@as(i64, bodyOps.items[bodyPc + 3]) << 24) |
                                                (@as(i64, bodyOps.items[bodyPc + 4]) << 32) |
                                                (@as(i64, bodyOps.items[bodyPc + 5]) << 40) |
                                                (@as(i64, bodyOps.items[bodyPc + 6]) << 48) |
                                                (@as(i64, bodyOps.items[bodyPc + 7]) << 56);
                                            bodyPc += 8;
                                            const obj = try self.allocator.create(LispObject);
                                            self.gcRegister(obj);
                                            obj.* = LispObject.numberObj(n);
                                            self.push(obj);
                                        },
                                        .symbol => {
                                            const idx: u32 = @as(u32, bodyOps.items[bodyPc]) |
                                                (@as(u32, bodyOps.items[bodyPc + 1]) << 8) |
                                                (@as(u32, bodyOps.items[bodyPc + 2]) << 16) |
                                                (@as(u32, bodyOps.items[bodyPc + 3]) << 24);
                                            bodyPc += 4;
                                             const symObj = bc.getConstant(idx);
                                            if (symObj) |so| {
                                                const name = so.value.symbol.name[0..];
                                                // Check if it's a builtin
                                                if (self.dispatch_table.get(name)) |_| {
                                                    const builtinObj = try self.allocator.create(LispObject);
                                                    self.gcRegister(builtinObj);
                                                    builtinObj.* = LispObject{
                                                        .type = .builtin,
                                                        .value = .{ .builtin = name },
                                                        .next = null,
                                                        .marked = false,
                                                    };
                                                    self.push(builtinObj);
                                                } else {
                                                    if (childEnv.lookup(name)) |val| {
                                                        self.push(val);
                                                    } else {
                                                        const obj = try self.allocator.create(LispObject);
                                                        self.gcRegister(obj);
                                                        obj.* = LispObject.nilObj();
                                                        self.push(obj);
                                                    }
                                                }
                                            } else {
                                                const obj = try self.allocator.create(LispObject);
                                                self.gcRegister(obj);
                                                obj.* = LispObject.nilObj();
                                                self.push(obj);
                                            }
                                        },
                                        .const_val => {
                                            const idx: u32 = @as(u32, bodyOps.items[bodyPc]) |
                                                (@as(u32, bodyOps.items[bodyPc + 1]) << 8) |
                                                (@as(u32, bodyOps.items[bodyPc + 2]) << 16) |
                                                (@as(u32, bodyOps.items[bodyPc + 3]) << 24);
                                            bodyPc += 4;
                                            const val = if (idx < self.bytecode_compile_constants.items.len)
                                                self.bytecode_compile_constants.items[idx]
                                            else
                                                null;
                                            if (val) |v| {
                                                self.push(v);
                                            } else {
                                                const obj = try self.allocator.create(LispObject);
                                                self.gcRegister(obj);
                                                obj.* = LispObject.nilObj();
                                                self.push(obj);
                                            }
                                        },
                                        .call => {
                                            // Nested call — handle recursively
                                            const nestedArgCount: u8 = @intCast(bodyOps.items[bodyPc]);
                                            bodyPc += 1;
                                            const nestedFnVal = self.pop() orelse return error.StackUnderflow;
                                            switch (nestedFnVal.value) {
                                                .builtin => |n| {
                                                    if (self.dispatch_table.get(n)) |kind| {
                                                        switch (kind) {
                                                            .add => try self.primAdd(),
                                                            .sub => try self.primSub(),
                                                            .mul => try self.primMul(),
                                                            .div => try self.primDiv(),
                                                            .bit_and => try self.primBitAnd(),
                                                            .bit_or => try self.primBitOr(),
                                                            .bit_not => try self.primBitNot(),
                                                            .bit_shl => try self.primBitShl(),
                                                            .bit_shr => try self.primBitShr(),
                                                            .eq => try self.primEq(),
                                                            .lt => try self.primLt(),
                                                            .gt => try self.primGt(),
                                                            .le => try self.primLe(),
                                                            .ge => try self.primGe(),
                                                            .cons => try self.primCons(),
                                                            .car => try self.primCar(),
                                                            .cdr => try self.primCdr(),
                                                            .print => try self.primPrint(),
                                                            .null => try self.primNullQ(),
                                                            .not => try self.primNot(),
                                                            .symbol => try self.primSymbolQ(),
                                                            .number => try self.primNumberQ(),
                                                            .list => try self.primListQ(),
                                                            .length => try self.primLength(),
                                                            .append => try self.primAppend(),
                                                            .reverse => try self.primReverse(),
                                                            .member => try self.primMember(),
                                                            .assoc => try self.primAssoc(),
                                                            .map => try self.primMap(),
                                                            .equal => try self.primEqual(),
                                                            .even => try self.primEven(),
                                                            .odd => try self.primOdd(),
                                                            .positive => try self.primPositive(),
                                                            .negative => try self.primNegative(),
                                                            .type_of => try self.primTypeOf(),
                                                            .filter => try self.primFilter(),
                                                            .println => try self.primPrintln(),
                                                            .writeln => try self.primWriteln(),
                                                            .read_line => try self.primReadLine(),
                                                            .str => try self.primStr(),
                                                            .str_cat => try self.primStrCat(),
                                                            .str_len => try self.primStrLen(),
                                                            .str_eq => try self.primStrEq(),
                                                            .substr => try self.primSubstr(),
                                                            else => {},
                                                        }
                                                    }
                                                },
                                                .closure => {
                                                    // Nested closure call — recursively execute
                                                    const nestedBodyIdxObj = nestedFnVal.next;
                                                    const nestedParamChain = if (nestedBodyIdxObj) |bi| bi.next else null;
                                                    const nestedBodyIdx: u32 = if (nestedBodyIdxObj) |bi|
                                                        if (bi.type == .number) @intCast(bi.value.number)
                                                        else 0
                                                    else 0;

                                                    var nestedArgs: [16]*LispObject = undefined;
                                                    var nai: usize = 0;
                                                    while (nai < nestedArgCount) : (nai += 1) {
                                                        nestedArgs[nestedArgCount - 1 - nai] = self.pop() orelse return error.StackUnderflow;
                                                    }

                                                    var nestedChildEnv = childEnv.child(self.allocator);
                                                    errdefer nestedChildEnv.deinit();
                                                    var nparamPtr = nestedParamChain;
                                                    var nargIdx: usize = 0;
                                                    while (nargIdx < nestedArgCount) {
                                                        if (nparamPtr) |p| {
                                                            const nparamName = p.value.symbol.name[0..];
                                                            try nestedChildEnv.bind(nparamName, nestedArgs[nargIdx]);
                                                            nparamPtr = p.next;
                                                        }
                                                        nargIdx += 1;
                                                    }

                                                    if (nestedBodyIdx < bc.closure_bodies.items.len) {
                                                        const nestedBodyOps = &bc.closure_bodies.items[nestedBodyIdx];
                                                        var nbPc: usize = 0;
                                                        while (nbPc < nestedBodyOps.items.len) {
                                                            const nbOp = @as(Opcode, @enumFromInt(nestedBodyOps.items[nbPc]));
                                                            nbPc += 1;
                                                            switch (nbOp) {
                                                                .nil => {
                                                                    const obj = try self.allocator.create(LispObject);
                                                                    self.gcRegister(obj);
                                                                    obj.* = LispObject.nilObj();
                                                                    self.push(obj);
                                                                },
                                                                .number => {
                                                                    const n: i64 = @as(i64, nestedBodyOps.items[nbPc]) |
                                                                        (@as(i64, nestedBodyOps.items[nbPc + 1]) << 8) |
                                                                        (@as(i64, nestedBodyOps.items[nbPc + 2]) << 16) |
                                                                        (@as(i64, nestedBodyOps.items[nbPc + 3]) << 24) |
                                                                        (@as(i64, nestedBodyOps.items[nbPc + 4]) << 32) |
                                                                        (@as(i64, nestedBodyOps.items[nbPc + 5]) << 40) |
                                                                        (@as(i64, nestedBodyOps.items[nbPc + 6]) << 48) |
                                                                        (@as(i64, nestedBodyOps.items[nbPc + 7]) << 56);
                                                                    nbPc += 8;
                                                                    const obj = try self.allocator.create(LispObject);
                                                                    self.gcRegister(obj);
                                                                    obj.* = LispObject.numberObj(n);
                                                                    self.push(obj);
                                                                },
                                                                .symbol => {
                                                                    const sidx: u32 = @as(u32, nestedBodyOps.items[nbPc]) |
                                                                        (@as(u32, nestedBodyOps.items[nbPc + 1]) << 8) |
                                                                        (@as(u32, nestedBodyOps.items[nbPc + 2]) << 16) |
                                                                        (@as(u32, nestedBodyOps.items[nbPc + 3]) << 24);
                                                                    nbPc += 4;
                                                                    const sobj = if (sidx < bc.constants.items.len) bc.constants.items[sidx] else null;
                                                                    if (sobj) |so| {
                                                                        if (nestedChildEnv.lookup(so.value.symbol.name[0..])) |val| {
                                                                            self.push(val);
                                                                        } else {
                                                                            const obj = try self.allocator.create(LispObject);
                                                                            self.gcRegister(obj);
                                                                            obj.* = LispObject.nilObj();
                                                                            self.push(obj);
                                                                        }
                                                                    } else {
                                                                        const obj = try self.allocator.create(LispObject);
                                                                        self.gcRegister(obj);
                                                                        obj.* = LispObject.nilObj();
                                                                        self.push(obj);
                                                                    }
                                                                },
                                                                .const_val => {
                                                                    const cidx: u32 = @as(u32, nestedBodyOps.items[nbPc]) |
                                                                        (@as(u32, nestedBodyOps.items[nbPc + 1]) << 8) |
                                                                        (@as(u32, nestedBodyOps.items[nbPc + 2]) << 16) |
                                                                        (@as(u32, nestedBodyOps.items[nbPc + 3]) << 24);
                                                                    nbPc += 4;
                                                                    const cval = if (cidx < self.bytecode_compile_constants.items.len)
                                                                        self.bytecode_compile_constants.items[cidx]
                                                                      else
                                                                        null;
                                                                    if (cval) |cv| {
                                                                        self.push(cv);
                                                                    } else {
                                                                        const obj = try self.allocator.create(LispObject);
                                                                        self.gcRegister(obj);
                                                                        obj.* = LispObject.nilObj();
                                                                        self.push(obj);
                                                                    }
                                                                },
                                                                else => {},
                                                            }
                                                        }
                                                    }
                                                },
                                                .symbol => {
                                                    // Check if it's a builtin name from const_val
                                                    const name = nestedFnVal.value.symbol.name[0..];
                                                    if (self.dispatch_table.get(name)) |kind| {
                                                        switch (kind) {
                                                            .add => try self.primAdd(),
                                                            .sub => try self.primSub(),
                                                            .mul => try self.primMul(),
                                                            .div => try self.primDiv(),
                                                            .bit_and => try self.primBitAnd(),
                                                            .bit_or => try self.primBitOr(),
                                                            .bit_not => try self.primBitNot(),
                                                            .bit_shl => try self.primBitShl(),
                                                            .bit_shr => try self.primBitShr(),
                                                            .eq => try self.primEq(),
                                                            .lt => try self.primLt(),
                                                            .gt => try self.primGt(),
                                                            .le => try self.primLe(),
                                                            .ge => try self.primGe(),
                                                            .cons => try self.primCons(),
                                                            .car => try self.primCar(),
                                                            .cdr => try self.primCdr(),
                                                            .print => try self.primPrint(),
                                                            .null => try self.primNullQ(),
                                                            .not => try self.primNot(),
                                                            .symbol => try self.primSymbolQ(),
                                                            .number => try self.primNumberQ(),
                                                            .list => try self.primListQ(),
                                                            .length => try self.primLength(),
                                                            .append => try self.primAppend(),
                                                            .reverse => try self.primReverse(),
                                                            .member => try self.primMember(),
                                                            .assoc => try self.primAssoc(),
                                                            .equal => try self.primEqual(),
                                                            .even => try self.primEven(),
                                                            .odd => try self.primOdd(),
                                                            .positive => try self.primPositive(),
                                                            .negative => try self.primNegative(),
                                                            .type_of => try self.primTypeOf(),
                                                            .filter => try self.primFilter(),
                                                            .println => try self.primPrintln(),
                                                            .writeln => try self.primWriteln(),
                                                            .read_line => try self.primReadLine(),
                                                            .str => try self.primStr(),
                                                            .str_cat => try self.primStrCat(),
                                                            .str_len => try self.primStrLen(),
                                                            .str_eq => try self.primStrEq(),
                                                            .substr => try self.primSubstr(),
                                                            else => {},
                                                        }
                                                    } else {
                                                        const obj = try self.allocator.create(LispObject);
                                                        self.gcRegister(obj);
                                                        obj.* = LispObject.nilObj();
                                                        self.push(obj);
                                                    }
                                                },
                                                else => {
                                                    const obj = try self.allocator.create(LispObject);
                                                    self.gcRegister(obj);
                                                    obj.* = LispObject.nilObj();
                                                    self.push(obj);
                                                },
                                            }
                                        },
                                        .jump => {
                                            const offset = @as(u32, bodyOps.items[bodyPc]) |
                                                (@as(u32, bodyOps.items[bodyPc + 1]) << 8) |
                                                (@as(u32, bodyOps.items[bodyPc + 2]) << 16) |
                                                (@as(u32, bodyOps.items[bodyPc + 3]) << 24);
                                            bodyPc += 4;
                                            bodyPc = @as(usize, offset);
                                        },
                                        .jump_if_false => {
                                            const offset = @as(u32, bodyOps.items[bodyPc]) |
                                                (@as(u32, bodyOps.items[bodyPc + 1]) << 8) |
                                                (@as(u32, bodyOps.items[bodyPc + 2]) << 16) |
                                                (@as(u32, bodyOps.items[bodyPc + 3]) << 24);
                                            bodyPc += 4;
                                            const top = self.peek();
                                            if (top == null or top.?.type == .nil) {
                                                bodyPc = @as(usize, offset);
                                            }
                                        },
                                        .def => {
                                            const idx: u32 = @as(u32, bodyOps.items[bodyPc]) |
                                                (@as(u32, bodyOps.items[bodyPc + 1]) << 8) |
                                                (@as(u32, bodyOps.items[bodyPc + 2]) << 16) |
                                                (@as(u32, bodyOps.items[bodyPc + 3]) << 24);
                                            bodyPc += 4;
                                            const val = self.pop() orelse return error.StackUnderflow;
                                            const symObj = if (idx < bc.constants.items.len) bc.constants.items[idx] else null;
                                            if (symObj) |so| {
                                                try childEnv.bind(so.value.symbol.name[0..], val);
                                            }
                                        },
                                        .defn => {
                                            const idx: u32 = @as(u32, bodyOps.items[bodyPc]) |
                                                (@as(u32, bodyOps.items[bodyPc + 1]) << 8) |
                                                (@as(u32, bodyOps.items[bodyPc + 2]) << 16) |
                                                (@as(u32, bodyOps.items[bodyPc + 3]) << 24);
                                            bodyPc += 4;
                                            const val = self.pop() orelse return error.StackUnderflow;
                                            const symObj = if (idx < bc.constants.items.len) bc.constants.items[idx] else null;
                                            if (symObj) |so| {
                                                try childEnv.bind(so.value.symbol.name[0..], val);
                                            }
                                        },
                                        .let => {
                                            const startIdx: u32 = @as(u32, bodyOps.items[bodyPc]) |
                                                (@as(u32, bodyOps.items[bodyPc + 1]) << 8) |
                                                (@as(u32, bodyOps.items[bodyPc + 2]) << 16) |
                                                (@as(u32, bodyOps.items[bodyPc + 3]) << 24);
                                            bodyPc += 4;
                                            const count: u32 = @as(u32, bodyOps.items[bodyPc]) |
                                                (@as(u32, bodyOps.items[bodyPc + 1]) << 8) |
                                                (@as(u32, bodyOps.items[bodyPc + 2]) << 16) |
                                                (@as(u32, bodyOps.items[bodyPc + 3]) << 24);
                                            bodyPc += 4;
                                            var letChildEnv = childEnv.child(self.allocator);
                                            errdefer letChildEnv.deinit();
                                            var li: usize = 0;
                                            while (li < count) : (li += 1) {
                                                const val = self.pop() orelse return error.StackUnderflow;
                                                const symObj = if (startIdx + li < bc.constants.items.len) bc.constants.items[startIdx + li] else null;
                                                if (symObj) |so| {
                                                    try letChildEnv.bind(so.value.symbol.name[0..], val);
                                                }
                                            }
                                            current_env = &letChildEnv;
                                        },
                                        .iff => {
                                            const elseOffset = @as(u32, bodyOps.items[bodyPc]) |
                                                (@as(u32, bodyOps.items[bodyPc + 1]) << 8) |
                                                (@as(u32, bodyOps.items[bodyPc + 2]) << 16) |
                                                (@as(u32, bodyOps.items[bodyPc + 3]) << 24);
                                            bodyPc += 4;
                                            const top = self.peek();
                                            if (top == null or top.?.type == .nil) {
                                                bodyPc = @as(usize, elseOffset);
                                            }
                                        },
                                        .quote => {
                                            const idx: u32 = @as(u32, bodyOps.items[bodyPc]) |
                                                (@as(u32, bodyOps.items[bodyPc + 1]) << 8) |
                                                (@as(u32, bodyOps.items[bodyPc + 2]) << 16) |
                                                (@as(u32, bodyOps.items[bodyPc + 3]) << 24);
                                            bodyPc += 4;
                                            const val = if (idx < bc.constants.items.len) bc.constants.items[idx] else null;
                                            if (val) |v| {
                                                self.push(v);
                                            } else {
                                                const obj = try self.allocator.create(LispObject);
                                                self.gcRegister(obj);
                                                obj.* = LispObject.nilObj();
                                                self.push(obj);
                                            }
                                        },
                                        .do => {
                                            _ = bodyOps.items[bodyPc];
                                            bodyPc += 4;
                                        },
                                        else => {},
                                    }
                                }
                                // Pop the result of the last expression in the body
                                const resultVal = self.pop() orelse return error.StackUnderflow;
                                                              // Push result back as the function call return value
                                self.push(resultVal);
                                                          }
                        },
                        else => {
                            const obj = try self.allocator.create(LispObject);
                            self.gcRegister(obj);
                            obj.* = LispObject.nilObj();
                            self.push(obj);
                        },
                    }
                },
                .tailcall => {
                    // Tail call — same as call but without pushing a new frame
                    // For now, just treat it like a regular call
                    const argCount = bc.ops.items[pc];
                    pc += 1;
                    var args: [16]*LispObject = undefined;
                    var i: usize = 0;
                    while (i < argCount) : (i += 1) {
                        args[argCount - 1 - i] = self.pop() orelse return error.StackUnderflow;
                    }
                    const fnVal = self.pop() orelse return error.StackUnderflow;
                    switch (fnVal.value) {
                        .builtin => |name| {
                            if (self.dispatch_table.get(name)) |kind| {
                                switch (kind) {
                                    .add => try self.primAdd(),
                                    .sub => try self.primSub(),
                                    .mul => try self.primMul(),
                                    .div => try self.primDiv(),
                                    .rem => try self.primRem(),
                                    .bit_and => try self.primBitAnd(),
                                    .bit_or => try self.primBitOr(),
                                    .bit_not => try self.primBitNot(),
                                    .bit_shl => try self.primBitShl(),
                                    .bit_shr => try self.primBitShr(),
                                    .eq => try self.primEq(),
                                    .lt => try self.primLt(),
                                    .gt => try self.primGt(),
                                    .le => try self.primLe(),
                                    .ge => try self.primGe(),
                                    .cons => try self.primCons(),
                                    .car => try self.primCar(),
                                    .cdr => try self.primCdr(),
                                    .print => try self.primPrint(),
                                    .null => try self.primNullQ(),
                                    .not => try self.primNot(),
                                    .symbol => try self.primSymbolQ(),
                                    .number => try self.primNumberQ(),
                                    .list => try self.primListQ(),
                                    .length => try self.primLength(),
                                    .append => try self.primAppend(),
                                    .reverse => try self.primReverse(),
                                    .member => try self.primMember(),
                                    .equal => try self.primEqual(),
                                    .even => try self.primEven(),
                                    .odd => try self.primOdd(),
                                    .positive => try self.primPositive(),
                                    .negative => try self.primNegative(),
                                    .type_of => try self.primTypeOf(),
                                    .map => try self.primMap(),
                                    .filter => try self.primFilter(),
                                    .println => try self.primPrintln(),
                                    .writeln => try self.primWriteln(),
                                    .read_line => try self.primReadLine(),
                                    .str => try self.primStr(),
                                    .str_cat => try self.primStrCat(),
                                    .str_len => try self.primStrLen(),
                                    .str_eq => try self.primStrEq(),
                                    .substr => try self.primSubstr(),
                                    else => {},
                                }
                            }
                        },
                        else => {
                            const obj = try self.allocator.create(LispObject);
                            self.gcRegister(obj);
                            obj.* = LispObject.nilObj();
                            self.push(obj);
                        },
                    }
                },
                .pop => {
                    _ = self.pop();
                },
                .dup => {
                    const top = self.peek();
                    if (top != null) {
                        self.push(top.?);
                    } else {
                        const obj = try self.allocator.create(LispObject);
                        self.gcRegister(obj);
                        obj.* = LispObject.nilObj();
                        self.push(obj);
                    }
                },
            }
        }

        // Return the top of the stack
        return self.pop() orelse {
            const obj = try self.allocator.create(LispObject);
            self.gcRegister(obj);
            obj.* = LispObject.nilObj();
            return obj;
        };
    }

    /// Call a primitive by name. Pushes the result onto the stack.
    pub fn callPrim(self: *Vm, name: []const u8) !void {
        if (std.mem.eql(u8, name, "+")) return try self.primAdd();
        if (std.mem.eql(u8, name, "-")) return try self.primSub();
        if (std.mem.eql(u8, name, "*")) return try self.primMul();
        if (std.mem.eql(u8, name, "/")) return try self.primDiv();
        if (std.mem.eql(u8, name, "=")) return try self.primEq();
        if (std.mem.eql(u8, name, "<")) return try self.primLt();
        if (std.mem.eql(u8, name, ">")) return try self.primGt();
        if (std.mem.eql(u8, name, "<=")) return try self.primLe();
        if (std.mem.eql(u8, name, ">=")) return try self.primGe();
        if (std.mem.eql(u8, name, "rem")) return try self.primRem();
        if (std.mem.eql(u8, name, "bit-and")) return try self.primBitAnd();
        if (std.mem.eql(u8, name, "bit-or")) return try self.primBitOr();
        if (std.mem.eql(u8, name, "bit-not")) return try self.primBitNot();
        if (std.mem.eql(u8, name, "bit-shl")) return try self.primBitShl();
        if (std.mem.eql(u8, name, "bit-shr")) return try self.primBitShr();
        if (std.mem.eql(u8, name, "cons")) return try self.primCons();
        if (std.mem.eql(u8, name, "car")) return try self.primCar();
        if (std.mem.eql(u8, name, "cdr")) return try self.primCdr();
        if (std.mem.eql(u8, name, "print")) return try self.primPrint();
        if (std.mem.eql(u8, name, "null?")) return try self.primNullQ();
        if (std.mem.eql(u8, name, "not")) return try self.primNot();
        if (std.mem.eql(u8, name, "symbol?")) return try self.primSymbolQ();
        if (std.mem.eql(u8, name, "number?")) return try self.primNumberQ();
        if (std.mem.eql(u8, name, "list?")) return try self.primListQ();
        if (std.mem.eql(u8, name, "length")) return try self.primLength();
        if (std.mem.eql(u8, name, "append")) return try self.primAppend();
        if (std.mem.eql(u8, name, "reverse")) return try self.primReverse();
        if (std.mem.eql(u8, name, "member")) return try self.primMember();
        if (std.mem.eql(u8, name, "assoc")) return try self.primAssoc();
        return error.UnknownPrimitive;
    }
};
