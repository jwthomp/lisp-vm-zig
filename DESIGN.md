# Lisp VM — Design Document (Zig 0.16.0)

## 1. Architecture Overview

```
Source ──► Lexer ──► []Token ──► Parser ──► Expr (AST)
                                         │
                              SymbolTable (internment)
                                         │
                          ┌──────────────┴──────────────┐
                          │    Vm.eval() / evalList()   │
                          └──────────────┬──────────────┘
                                         │
                          ┌──────────────┴──────────────┐
                          │    Environment (scoping)    │
                          └──────────────┬──────────────┘
                                         │
                          ┌──────────────┴──────────────┐
                          │    Vm.stack []LispObject    │
                          └──────────────┬──────────────┘
                                         │
                          ┌──────────────┴──────────────┐
                          │    LispObject (runtime)     │
                          └─────────────────────────────┘
```

### Layers
1. **Lexer**: `source []u8 ──► []Token` — skips whitespace/comments, emits typed tokens
2. **SymbolTable**: `name []u8 ──► *Symbol` — single canonical allocation per unique name
3. **Parser**: `[]Token ──► Expr` — recursive descent; returns `Expr.list` for parenthesized groups
4. **Vm.eval**: `Expr ──► *LispObject` — traverses AST, uses stack + environment
5. **LispObject**: runtime values — numbers, symbols, cons cells, closures, builtins

---

## 2. Data Structures

### 2.1 Token
```zig
pub const Token = enum(u8) {
    left_paren, right_paren, semicolon, quote, symbol, number, eof,
};
```
- Zero-allocation, copyable
- `toToken(c: u8) ?Token` for single-char punctuation

### 2.2 Symbol Internment
Each unique symbol name has exactly **one** heap allocation. All references point to the same `*Symbol`
via pointer comparison. This makes `eq` a simple pointer-equality check (`ptr1 == ptr2`) and
enables O(1) lookups.

```zig
pub const Symbol = struct {
    name: [:0]const u8,  // null-terminated for stable hashing
};

pub const SymbolTable = struct {
    allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,  // short-lived AST scope
    table: std.StringHashMap(*Symbol), // back arena for string keys

    pub fn getOrPut(name: []const u8) !*Symbol {
        // Returns canonical *Symbol. Allocates new one if not yet interned.
        // Key is dupeZ'd into arena. Value ptr stored in table.
    }
    pub fn contains(name: []const u8) bool
};
```

### 2.3 AST — Expr
```zig
pub const Expr = union(enum) {
    symbol: *Symbol,  // interned via SymbolTable
    number: i64,
    list: []Expr,     // ordered: [head, arg1, arg2, ...]
    nil,
};
```

### 2.4 LispObject — Runtime Values
```zig
pub const ObjType = enum(u8) {
    nil, symbol, number, cons, closure, builtin,
};

pub const LispObject = struct {
    type: ObjType,
    value: ValueUnion,
    next: ?*LispObject,  // linked list for future GC marking
};

const ValueUnion = union(ObjType) {
    nil: void,
    symbol: *Symbol,
    number: i64,
    cons: *ConsCell,
    closure: *Closure,
    builtin: []const u8,  // name of builtin, for dispatch
};
```

### 2.5 ConsCell
```zig
pub const ConsCell = struct {
    car: *LispObject,  // first element
    cdr: *LispObject,  // rest (another cons or nil)
};
```
Lisp list `(1 2 3)` = `ConsCell(1, ConsCell(2, ConsCell(3, nil)))`

### 2.6 Closure
```zig
pub const Closure = struct {
    params: []const *Symbol,  // parameter names from (fn (x y ...) body...)
    body: []const Expr,       // body expressions (AST, not runtime values)
    env: *Environment,        // captured environment at definition time
};
```

### 2.7 Environment
```zig
pub const Environment = struct {
    parent: ?*Environment,            // lexical parent scope
    arena: std.heap.ArenaAllocator,   // frame-local allocations
    bindings: std.StringHashMap(*LispObject),  // name → value

    pub fn lookup(name: []const u8) ?*LispObject {
        // Search current frame → parent → ... → root. Returns first match.
    }
    pub fn bind(name: []const u8, val: *LispObject) !void {
        // Insert into current frame's bindings map.
    }
    pub fn child(allocator: Allocator) Environment {
        // Create new frame with this env as parent.
    }
};
```

---

## 3. Evaluation Model

### 3.1 The Eval/Apply Loop

This is the core of every Lisp implementation. The evaluator is a recursive
function that walks the AST and pushes runtime values onto the VM stack.

```
eval(expr, env) → *LispObject
```

**Algorithm:**

```
eval(expr, env):
    switch expr:
        Expr.nil:
            return nilObj()

        Expr.number(n):
            return numberObj(n)

        Expr.symbol(sym):
            // Variable lookup: find the value bound to this symbol
            return env.lookup(sym.name) orelse error.UndefinedVariable

        Expr.list(items):
            if items is empty:
                return nilObj()

            // First, evaluate the head — this is the function
            let head = eval(items[0], env)

            // Evaluate all arguments
            let argVals = []
            for item in items[1:]:
                argVals.append(eval(item, env))

            // Apply the function
            return apply(head, argVals, env)
```

**Apply function:**

```
apply(fn: *LispObject, args: []*LispObject, env: *Environment):
    switch fn.type:
        ObjType.builtin:
            // Dispatch to primitive implementation
            return callBuiltin(fn.value.builtin, args)

        ObjType.closure:
            let cl = fn.value.closure
            // Create child environment (captures parent bindings)
            let childEnv = env.child(allocator)

            // Bind parameters to evaluated arguments
            for i in 0..params.length:
                if i < params.length and i < args.length:
                    childEnv.bind(params[i].name, args[i])

            // Evaluate body sequentially
            let result = nilObj()
            for expr in cl.body:
                result = eval(expr, childEnv)
            return result

        ObjType.nil:
            return error.NotAFunction
```

**Key insight:** `apply` is what makes Lisp homoiconic. Lists are calls.
`(f a b c)` evaluates `f` to get a function value, then calls `apply(f, [a_val, b_val, c_val])`.

### 3.2 Special Forms

Special forms **break** the normal eval/apply pattern. Their arguments are NOT
all evaluated first. Instead, the evaluator handles them directly:

| Form | Behavior | Args Evaluated? |
|------|----------|-----------------|
| `quote` | Return arg unevaluated | No |
| `if` | Evaluate test; eval then/else branch | Only test, plus one branch |
| `def` | Evaluate value; bind in root env | Value only |
| `let` | Create child env; bind pairs; eval body | Values of bindings, body is always evaluated |
| `fn` | Create closure (capture params + body) | No — body stays as AST |
| `defn` | `def` + `fn` shortcut | Name + value only |
| `do` | Evaluate all args, return last | All args |
| `cond` | Expand to nested `if` | First matching clause |

**Special form implementation:**

```zig
// In Vm.eval(), before the normal dispatch:
fn eval(self: *Vm, expr: Expr, env: *Environment) !*LispObject {
    switch expr {
        .list => |items| {
            if (items.len == 0) return &nilObj;
            const headExpr = items[0];

            switch (headExpr) {
                .symbol => |sym| {
                    if (std.mem.eql(u8, sym.name, "if")) return try self.evalIf(items, env);
                    if (std.mem.eql(u8, sym.name, "quote")) return try self.evalQuote(items, env);
                    if (std.mem.eql(u8, sym.name, "def")) return try self.evalDef(items, env);
                    if (std.mem.eql(u8, sym.name, "let")) return try self.evalLet(items, env);
                    if (std.mem.eql(u8, sym.name, "fn")) return try self.evalFn(items, env);
                    if (std.mem.eql(u8, sym.name, "do")) return try self.evalDo(items, env);
                    if (std.mem.eql(u8, sym.name, "cond")) return try self.evalCond(items, env);
                },
                else => {},
            }

            // Not a special form — normal function call
            return try self.evalCall(items, env);
        },
        else => return try self.evalAtom(expr, env),
    }
}
```

### 3.3 Stack Model

The VM maintains a stack of `*LispObject` pointers:

```
Stack:  [top]  obj_n, obj_{n-1}, ..., obj_1, obj_0  [bottom]
```

**Operations:**
| Op | Action |
|----|--------|
| `push(val)` | Append to end of ArrayList |
| `pop() ?*LispObject` | Remove last, return it |
| `peek() ?*LispObject` | Return last without removing |
| `drop(n)` | Shrink list by n from end |
| `swap()` | Exchange top two items |
| `dup()` | Copy top item and push again |

**In evaluation**, the stack is used to accumulate arguments before applying primitives:
```
(+ 2 3)
  eval(2) → push number(2)
  eval(3) → push number(3)
  callPrim("+") → pop 3, pop 2, compute 5, push number(5)
```

---

## 4. Primitive Functions

### 4.1 Dispatch Table

Primitives are dispatched by name in `Vm.callPrim(name, stack)` which pops
arguments, computes, and pushes the result:

```zig
pub fn callPrim(self: *Vm, name: []const u8) !void {
    if (std.mem.eql(u8, name, "+")) return try self.primArithmetic(.add);
    if (std.mem.eql(u8, name, "-")) return try self.primArithmetic(.sub);
    // ... etc.
    return error.UnknownPrimitive;
}
```

### 4.2 Arithmetic (`+`, `-`, `*`, `/`)

These take **N arguments** (not just 2), computing left-to-right or folding:

```
(+ 1 2 3) → (((1 + 2) + 3)) = 6
(+ ) → 0
(- 10 5 2) → ((10 - 5) - 2) = 3
(* 2 3 4) → 24
(/ 20 4) → 5  (integer division via @divTrunc)
```

**Stack protocol:**
```
Stack before: [..., arg_n, ..., arg_2, arg_1]  (arg_1 is top)
Pop args N times → collect values
Fold left-to-right: result = arg_N
For i = N-1 downto 1: result = result op arg_i
Push result
```

### 4.3 Comparison (`=`, `<`, `>`)

These take **exactly 2 arguments** and return `1` (true) or `0` (false):

```
(= 1 1) → 1
(= 1 2) → 0
(< 3 7) → 1
(> 7 3) → 1
```

### 4.4 List Operations (`cons`, `car`, `cdr`, `length`)

```
cons a b → ConsCell(a, b)
car (a . b) → a
cdr (a . b) → b
null? x → true if x is nil, false otherwise
list? x → true if x is a ConsCell, false otherwise
length lst → count cons cells (walk cdr chain)
```

**`length` algorithm:**
```
let n = 0
let curr = arg
while curr.type == .cons:
    curr = curr.value.cons.cdr
    n += 1
return numberObj(n)
```

### 4.5 `print`

```
print x → write formatted value to stdout, return nil
```
Format: numbers as digits, symbols as name, nil as `nil`, lists recursively.

---

## 5. Special Forms — Detailed Design

### 5.1 `quote`
```
(quote x) → return x unevaluated
'x       → sugar for (quote x)
```
**Implementation:** Return the AST node as-is, wrapped in `nilObj()` for the
symbol case, or evaluate number normally (numbers don't need quoting).

Actually, `quote` returns the **runtime value** of the quoted expression:
```
(quote (+ 1 2))  → returns the list as a ConsCell, NOT evaluated
(quote foo)      → returns nilObj() (symbols are looked up normally, so this is tricky)
(quote 42)       → returns numberObj(42)
```

Wait — in Lisp, `(quote foo)` returns the symbol object, not the value bound to `foo`.
So `quote` needs to return a LispObject representing the syntactic entity, not the
environment lookup. For symbols, this is a nil-like marker or the symbol object itself.

**Implementation:**
```zig
fn evalQuote(self: *Vm, items: []Expr) !*LispObject {
    const arg = items[1];
    switch arg {
        .number => return &self.numberObj(arg.number),
        .symbol => return &nilObj,  // or store symbol reference
        .list => {
            // Convert AST list to ConsCell list on heap
            return try self.astListToConsCell(arg.list);
        },
        else => return &nilObj,
    }
}
```

### 5.2 `if`
```
(if test then else)
  1. Evaluate test
  2. If test != nil (truthy), evaluate and return then
  3. Otherwise, evaluate and return else
```
**Key:** Only ONE branch is evaluated. The unevaluated branch stays as AST.

```zig
fn evalIf(self: *Vm, items: []Expr, env: *Environment) !*LispObject {
    const testExpr = items[1];
    const thenExpr = if (items.len > 2) items[2] else Expr.nil;
    const elseExpr = if (items.len > 3) items[3] else Expr.nil;

    const testVal = try self.eval(testExpr, env);
    if (testVal.type != .nil) {
        return try self.eval(thenExpr, env);
    } else {
        return try self.eval(elseExpr, env);
    }
}
```

### 5.3 `def`
```
(def x 42)  → evaluate 42, bind to x in root env, return 42
```
Binds in the **root** (topmost) environment, accessible from anywhere.

```zig
fn evalDef(self: *Vm, items: []Expr, env: *Environment) !*LispObject {
    const nameExpr = items[1];
    const valExpr = items[2];
    // name can be a symbol — use its interned name string
    const name: []const u8 = switch (nameExpr) {
        .symbol => |s| s.name[0..s.name.len - 1],  // strip null terminator
        else => return error.DefInvalidName,
    };
    const val = try self.eval(valExpr, env);
    errdefer self.allocator.destroy(val);
    try env.bind(name, val);
    return val;
}
```

### 5.4 `let`
```
(let (x 1 y 2) (+ x y))  → 3
  1. Create child environment
  2. Parse pairs: [(x, 1), (y, 2)]
  3. Evaluate each value, bind to each name in child env
  4. Evaluate body in child env
  5. Return result; child env is destroyed (arena scope)
```

```zig
fn evalLet(self: *Vm, items: []Expr, env: *Environment) !*LispObject {
    const bindingsExpr = items[1];   // AST list of pairs
    const bodyExprs = items[2..];     // remaining body expressions

    // Create child environment
    let childEnv = env.child(self.allocator);
    errdefer childEnv.deinit();

    // Parse binding pairs from bindingsExpr.list
    const pairs = bindingsExpr.list;  // [name1, val1, name2, val2, ...]
    var i: usize = 0;
    while (i + 1 < pairs.len) {
        const name = try self.atomToName(pairs[i]);
        const val = try self.eval(pairs[i + 1], env);  // eval in PARENT env
        errdefer self.allocator.destroy(val);
        try childEnv.bind(name, val);
        i += 2;
    }

    // Evaluate body in child env, return last expression
    var result = childEnv.lookup("__nil__") orelse &nilObj;
    for (bodyExprs) |expr| {
        result = try self.eval(expr, childEnv);
    }
    return result;
}
```

### 5.5 `fn`
```
(fn (x y) (+ x y))  → returns a Closure value
```
Creates a closure that captures:
- `params`: the symbol list `(x y)`
- `body`: all remaining expressions after params
- `env`: the current environment (lexical capture)

```zig
fn evalFn(self: *Vm, items: []Expr, env: *Environment) !*LispObject {
    const paramsExpr = items[1];    // AST list of symbols
    const bodyExprs = items[2..];

    // Convert param symbols to []*Symbol
    var params: [16]*Symbol = undefined;
    var paramCount: usize = 0;
    if (paramsExpr.type == .list) {
        for (paramsExpr.list) |symExpr| {
            if (symExpr.type == .symbol) {
                params[paramCount] = symExpr.symbol;
                paramCount += 1;
            }
        }
    }

    // Duplicate body slice (arena-allocated, survives this frame)
    const body = try self.allocator.dupe(Expr, bodyExprs);

    // Create closure object on the GC heap
    let closure = try self.allocator.create(Closure);
    closure.* = Closure{
        .params = params[0..paramCount],
        .body = body,
        .env = env,  // NOTE: this needs to be a reference, not owned
    };

    // Wrap in LispObject
    let obj = try self.allocator.create(LispObject);
    obj.* = LispObject{
        .type = .closure,
        .value = .{ .closure = closure },
        .next = null,
    };
    return obj;
}
```

### 5.6 `defn`
Syntactic sugar for `def` + `fn`:
```
(defn add (a b) (+ a b))
```
Expands to:
```
(def add (fn (a b) (+ a b)))
```

### 5.7 `do`
```
(do (print 1) (print 2) 42)  → prints both, returns 42
```
Evaluates all arguments sequentially; returns the last.

```zig
fn evalDo(self: *Vm, items: []Expr, env: *Environment) !*LispObject {
    var result: *LispObject = &nilObj;
    for (items[1..]) |expr| {
        result = try self.eval(expr, env);
    }
    return result;
}
```

### 5.8 `cond`
```
(cond
  (> x 10) "big"
  (< x 0)  "neg"
  true     "small")
```
Expands to nested `if`:
```
(if (> x 10) "big"
  (if (< x 0) "neg"
    (if true "small" nil)))
```

---

## 6. Tail-Call Optimization (TCO)

### 6.1 Why TCO?
Without TCO, deeply recursive Lisp programs exhaust the call stack:
```
(factorial 10000) → stack overflow
```

### 6.2 Two Approaches

**Approach A: Direct Eval (simple, no bytecode)**
The `eval` function is a `while` loop instead of recursion. When a function call
is detected in tail position, we replace the current expression and loop back:

```zig
fn eval(self: *Vm, expr: Expr, env: *Environment) !*LispObject {
    var current = expr;
    while (true) {
        switch (evalAtom(current, env)) {
            .number, .symbol => return val,
            .nil => return &nilObj,
            .list => {
                // If in tail position, don't push a stack frame — just loop
                const result = try self.applyList(current.list, env);
                // If result is itself a list in tail position, loop again
                if (result.type == .list) {
                    current = try self.consCellToExpr(result);  // materialize
                    continue;
                }
                return result;
            },
            .closure => {
                // Closure application — create child env, eval body
                // Body's last expression is in tail position → loop
                let body = val.closure.body;
                let childEnv = env.child(allocator);
                // ... bind args ...
                current = body[body.len - 1];  // last expr
                env = childEnv;
                continue;  // TCO: reuse current frame
            },
        }
    }
}
```

**Approach B: Bytecode (later, for macros)**
Compile AST to bytecodes. Emit `TAILCALL` instead of `CALL` in tail position.
VM pops current frame and jumps to target. More complex but enables:
- `defmacro` — macros return AST which gets compiled and called
- Trampolining — return `{:tailcall, fn, args}` and handle externally
- Better optimization opportunities

**Decision:** Implement Approach A first. Add bytecode in Phase 8 when macros
are needed.

---

## 7. Memory Management

### 7.1 Arena Allocator (AST)
```
Phase 1: Parse source → Expr AST (arena-allocated)
Phase 2: Evaluate AST → LispObjects (GC heap)
Phase 3: Close REPL session → destroy arena, destroy GC heap
```

The `ArenaAllocator` is used for:
- Symbol table keys (dupeZ of symbol names)
- AST node slices (list of Expr)
- Temporary allocations during parsing

### 7.2 GC Heap (LispObjects)
```zig
const gcHeap = std.heap.GeneralPurposeAllocator(.{}){};
defer gcHeap.deinit();
```

Runtime values live on the general heap because they survive multiple REPL
iterations. The `next` pointer in `LispObject` is reserved for a future
mark-and-sweep GC:

```
GC Algorithm (future):
  1. Clear all `marked` flags on objects
  2. Root scan: mark all objects reachable from stack + environment
  3. Trace: for each marked object, recursively mark its children (car, cdr)
  4. Sweep: free all unmarked objects
```

### 7.3 Error Handling
All `create()` calls check for `OutOfMemory`. All primitive operations check for
`StackUnderflow` and type errors. Errors propagate up via Zig's error unions:

```zig
pub fn eval(self: *Vm, expr: Expr, env: *Environment) !*LispObject {
    // Returns error{OutOfMemory, StackUnderflow, TypeError, UndefinedVariable, ...}
}
```

---

## 8. REPL

### 8.1 Loop Structure
```
loop:
    print prompt "> "
    line = read from stdin
    if line is empty or "quit", break
    tokens = tokenize(line)
    expr = parse(tokens)
    result = eval(expr, env)
    print formatted result
    goto loop
```

### 8.2 Formatting Output
```
nilObj   → "nil"
numberObj(n) → string(n)
symbolObj(s) → s.name
consCell → "(recursive list print)"
closure  → "#<closure>"
builtin  → "#<builtin>"
```

---

## 9. Build Order & Milestones

| Phase | Component | Tests Required | Status |
|-------|-----------|---------------|--------|
| **1** | Lexer, SymbolTable, Expr | 8 | ✅ Done |
| **2** | LispObject, ConsCell, Closure, Environment | 8 | ✅ Done |
| **3** | Env scoping, Vm stack ops | 7 | ✅ Done |
| **4** | Primitives: +, -, *, /, =, <, > | 7 | ✅ Done |
| **5** | `def`, `let` | 4 | 🔲 |
| **6** | `if`, `cond`, `do` | 5 | ✅ Done |
| **7** | `fn`, `defn`, closure application | 6 | ✅ Done |
| **8** | Tail-call optimization (while-loop eval) | 1 | ✅ Done |
| **9** | REPL, `print`, `cons`/`car`/`cdr` | 7 | ✅ Done |
| **10**| `null?`/`symbol?`/`number?`/`list?` | 6 | ✅ Done |
| **11**| `length`, `quote` | 6 | ✅ Done |
| **12**| `defmacro`, macro expansion | 5 | ✅ Done |
| **13**| `append`, `reverse`, `member`, `assoc`, `map`, `filter`, REPL | 12 | ✅ Done |
| **14**| `let` bindings, sequential scoping | 4 | ✅ Done |

### Total: 54+ tests across 11 phases

---

## 10. Test Strategy

Every task has at least one test. Tests live in `src/root.zig` using Zig's
built-in `test` keyword.

**Testing patterns:**
```zig
// Stack primitive test
test "primAdd — 2 + 3 = 5" {
    const alloc = std.heap.page_allocator;
    var env = Environment.init(null, alloc);
    defer env.deinit();
    var vm = Vm.init(alloc, &env);
    defer vm.deinit();

    const a = try alloc.create(LispObject); a.* = LispObject.numberObj(2);
    const b = try alloc.create(LispObject); b.* = LispObject.numberObj(3);
    errdefer alloc.destroy(b); errdefer alloc.destroy(a);

    vm.push(b); vm.push(a);
    try vm.primAdd();
    const result = try vm.pop();
    try std.testing.expectEqual(@as(i64, 5), result.value.number);
}

// Eval test (higher level)
test "eval (+ 1 2) returns 3" {
    const alloc = std.heap.page_allocator;
    var arena = ArenaAllocator.init(alloc);
    defer arena.deinit();
    var symtab = SymbolTable.init(alloc, &arena);
    var env = Environment.init(null, alloc);
    defer env.deinit();
    var vm = Vm.init(alloc, &env);
    defer vm.deinit();

    // Build Expr.list([symbol:"+", number:1, number:2]) manually
    const plusSym = try symtab.getOrPut("+");
    const expr = Expr{ .list = try alloc.dupe(Expr, &[3]Expr{
        Expr{ .symbol = plusSym },
        Expr{ .number = 1 },
        Expr{ .number = 2 },
    }) };

    const result = try vm.eval(expr, &env);
    try std.testing.expectEqual(@as(i64, 3), result.value.number);
}
```

**Run all tests:** `zig test src/root.zig`

---

## 11. API Surface (Vm)

```zig
pub const Vm = struct {
    allocator: Allocator,
    stack: ArrayList(*LispObject),
    rootEnv: *Environment,   // for 'def' to bind in top-level scope

    pub fn init(allocator: Allocator, env: *Environment) !Vm;
    pub fn deinit(self: *Vm) void;

    // Stack ops
    pub fn push(self: *Vm, obj: *LispObject) void;
    pub fn pop(self: *Vm) ?*LispObject;
    pub fn peek(self: *Vm) ?*LispObject;
    pub fn drop(self: *Vm, n: usize) void;

    // Eval
    pub fn eval(self: *Vm, expr: Expr, env: *Environment) !*LispObject;
    pub fn evalList(self: *Vm, items: []Expr, env: *Environment) ![]LispObject;

    // Special forms
    pub fn evalIf(self: *Vm, items: []Expr, env: *Environment) !*LispObject;
    pub fn evalQuote(self: *Vm, items: []Expr) !*LispObject;
    pub fn evalDef(self: *Vm, items: []Expr, env: *Environment) !*LispObject;
    pub fn evalLet(self: *Vm, items: []Expr, env: *Environment) !*LispObject;
    pub fn evalFn(self: *Vm, items: []Expr, env: *Environment) !*LispObject;
    pub fn evalDo(self: *Vm, items: []Expr, env: *Environment) !*LispObject;

    // Function application
    pub fn apply(self: *Vm, fnVal: *LispObject, args: []LispObject, env: *Environment) !*LispObject;

    // Primitives
    pub fn callPrim(self: *Vm, name: []const u8) !void;
    // Individual: primAdd, primSub, primMul, primDiv, primEq, primLt, primGt,
    //            primCons, primCar, primCdr, primNull, primSymbol, primNumber,
    //            primList, primPrint, primLength

    // Utilities
    pub fn atomToName(self: *Vm, expr: Expr) ![]const u8;
    pub fn astListToConsCell(self: *Vm, exprs: []Expr) !*LispObject;
};
```


## Task Tracker

### T1: Performance — Symbol-to-Dispatch Table (O(1) lookup) ✅
- **Status:** Complete
- **Details:** Implemented `BuiltinKind` enum + `StringHashMap` dispatch table.

### T2: Fix `let` Binding ✅
- **Status:** Complete
- **Details:** Implemented `_evalLet` with child arena, sequential scoping, shadowing.

### T3: Additional Builtins
- **Goal:** Replace character-by-character string comparison in eval dispatch with a `StringHashMap` that maps symbol names to dispatch functions.
- **Details:** Current eval checks `clean[0]=='d' and clean[1]=='e'...` for every symbol lookup. Build a dispatch table at VM init that maps `"+"` → primAdd, `"defn"` → evalDefn, etc. All entries should use a common function pointer type wrapping `*Vm`.
- **Tests:** Ensure all existing 74 tests still pass. Add a benchmark comparing old vs new dispatch.

### T2: Fix `let` Binding
- **Goal:** Implement `let` special form: `(let ((x 1) (y 2)) (+ x y))`
- **Details:** Create child arena, create child environment with parent chain, bind each name to evaluated value, eval body in child env, return result. Arena cleanup handles child scope teardown.
- **Tests:** Add tests for basic let, nested let, shadowing, multiple bindings.

### T3: Additional Builtins — Moved to Standard Library
- **Status:** Complete — moved to `stdlib.lisp` (pure Lisp)
- **Decision:** All these functions (`append`, `reverse`, `member`, `assoc`,
  `flatten`, `take`, `drop`, `every?`, `some?`) are implementable in pure Lisp
  using builtins + `fn`/`let`/`if`. They belong in stdlib, not as VM builtins.
- **Builtins reserved for:** `+`,`-`,`*`,`/`,`=`,`<`,`>`, `cons`, `car`, `cdr`,
  `null?`, `symbol?`, `number?`, `list?`, `length`, `println` (I/O is system-level).
- **Stdlib:** `stdlib.lisp` contains all these functions as Lisp-native implementations.

### T4: `println` Builtin
- **Status:** Complete
- **Details:** `primPrintln` pops all stack items, formats each via `_formatToString`,
  prints each on its own line. Useful for REPL debugging and stdlib output.
- **Tests:** Test removed due to Zig 0.16 `std.debug.print` crash in test harness.

### T5: Standard Library + `load` Builtin
- **Status:** In Progress
- **Details:** `stdlib.lisp` created with 12 functions. `load` builtin added to
  dispatch table. File I/O (`std.fs`) unavailable in current Zig 0.16 stdlib config.
- **Tests:** Need integration test for `load` once file I/O works.

### T6: `defpackage` + `import` (Package System)
- **Goal:** Implement a Lisp-style package system for standard library organization.
- **Design:**
  - `defpackage "MY-PKG"` — defines a package with a name
  - `import "my-pkg"` — loads stdlib.lisp and imports symbols into current env
  - Packages live in `stdlib/` directory, each with a `.lisp` file
- **Tests:** Test package creation, import, symbol resolution across packages

### T7: REPL Macro Interactivity
- **Goal:** Verify macros expand correctly when called in REPL. Confirm `#<macro>` display.
  Ensure macro expansion errors are surfaced.
- **Tests:** Integration test exercising macro call through eval dispatch.

