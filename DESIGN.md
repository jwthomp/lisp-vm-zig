# Lisp VM — Design Document

## 1. Architecture Overview

```
Source Code ──► Lexer ──► Tokens ──► Parser ──► AST ──► Vm.eval ──► LispObject
                                        │                        ▲
                                        │                        │
                                   SymbolTable (internment)   Environment
```

### Layers
1. **Lexer**: `source ──► []Token` — skip whitespace, comments, recognize symbols/numbers/parens
2. **SymbolTable**: `symbol name ──► *Symbol` — one canonical allocation per unique symbol name
3. **Parser**: `[]Token ──► Expr` — recursive descent with depth limit
4. **Vm**: `Expr ──► LispObject` — stack-based evaluator with environment and closures
5. **LispObject**: runtime values — numbers, symbols, lists, closures, builtins

---

## 2. Data Structures

### 2.1 Token (done)
```zig
pub const Token = enum(u8) {
    left_paren, right_paren, semicolon, quote, symbol, number, eof,
};
```
- Zero-allocation, copyable
- `toToken(c: u8) ?Token` for single-char punctuation

### 2.2 Symbol Internment
Each unique symbol name has exactly one heap allocation. All references to the same symbol
name point to the same `*Symbol` struct via pointer comparison. This makes `eq` a simple
pointer equality check and enables O(1) symbol table lookups.

**Implementation:**
```zig
pub const SymbolTable = struct {
    arena: std.heap.ArenaAllocator,
    table: StringHashMap(*Symbol),
    allocator: Allocator,

    pub fn getOrPut(self: *SymbolTable, name: []const u8) !*Symbol
    // Returns the canonical *Symbol for this name.
    // Allocates a new one if not yet interned.
};

pub const Symbol = struct {
    name: [:0]const u8,  // null-terminated for C interop
};
```

### 2.3 AST — Expr (partially done)
Currently only stores `list: []Expr` and `nil`. Need to add:
```zig
pub const Expr = union(enum) {
    symbol: *Symbol,       // interned
    number: i64,
    list: []Expr,
    nil,
};
```

### 2.4 LispObject — runtime values
```zig
pub const ObjType = enum(u8) {
    nil, atom, number, cons, closure, builtin, macro,
};

pub const LispObject = struct {
    type: ObjType,
    value: ValueUnion,
    next: *LispObject,  // linked list for GC
};

const ValueUnion = union(ObjType) {
    nil: void,
    atom: []const u8,      // cached name string
    number: i64,
    cons: *ConsCell,
    closure: *Closure,
    builtin: []const u8,   // function name
    macro: *Macro,
};
```

### 2.5 Cons Cell (Lisp list node)
```zig
pub const ConsCell = struct {
    car: *LispObject,
    cdr: *LispObject,
};
```

### 2.6 Closure
```zig
pub const Closure = struct {
    parameters: []const *Symbol,
    body: []Expr,
    env: *Environment,
};
```

### 2.7 Environment (scoping)
```zig
pub const Environment = struct {
    parent: ?*Environment,
    arena: std.heap.ArenaAllocator,
    bindings: StringHashMap(*LispObject),

    pub fn lookup(self: *Environment, sym: *Symbol) ?*LispObject
    pub fn bind(self: *Environment, sym: *Symbol, val: *LispObject) void
    pub fn bindNew(self: *Environment, sym: *Symbol, val: *LispObject) void
};
```

---

## 3. Evaluation Model (stack-based)

The VM uses a call stack of LispObjects and a local variable environment.

```
Stack: [top] obj_n, obj_{n-1}, ..., obj_0 [bottom]
Env:   [top] frame_n → frame_{n-1} → ... → frame_0 → root
```

### 3.1 Stack Operations
- `push(val)` — push LispObject onto stack
- `pop() ?*LispObject` — remove and return top
- `peek() ?*LispObject` — return top without removing
- `drop(n)` — remove n items from top
- `swap()` — swap top two items
- `dup()` — duplicate top item

### 3.2 Call Model
```
EVAL expr → push(result)
APPLY fn [args] → pop fn, pop args, create closure frame, push result
TAILCALL fn [args] → same as APPLY but REUSE stack frame (no allocation)
```

### 3.3 Tail-Call Optimization
When the compiler emits a tailcall, the VM:
1. Pops the current function frame
2. Pushes new arguments onto the same stack
3. Jumps to the function body directly (no new stack frame)

---

## 4. Primitive Functions

Built-in functions that operate on LispObjects:

| Function | Stack before | Stack after | Description |
|----------|-------------|-------------|-------------|
| `+` | `a b` | `a+b` | Add two numbers |
| `-` | `a b` | `a-b` | Subtract |
| `*` | `a b` | `a*b` | Multiply |
| `/` | `a b` | `a/b` | Divide (integer) |
| `=` | `a b` | `true/false` | Equality |
| `<` | `a b` | `true/false` | Less than |
| `>` | `a b` | `true/false` | Greater than |
| `cons` | `a b` | `(a . b)` | Cons cell |
| `car` | `(a . b)` | `a` | First element |
| `cdr` | `(a . b)` | `b` | Rest of list |
| `null?` | `x` | `true/false` | Is nil? |
| `symbol?` | `x` | `true/false` | Is symbol? |
| `number?` | `x` | `true/false` | Is number? |
| `list?` | `x` | `true/false` | Is cons cell? |
| `print` | `x` | `nil` | Print to stdout |
| `length` | `lst` | `n` | List length |
| `quote` | `x` | `x` | Return unevaluated |

---

## 5. Build Order

### Phase 1: Symbol Internment (Foundation)
- [ ] **Task 1.1**: Implement `SymbolTable` with `getOrPut(name) -> *Symbol`
  - Test: same name returns same pointer
  - Test: different names return different pointers
- [ ] **Task 1.2**: Add `symbol: *Symbol` to `Expr` union
  - Test: parse `"foo"` produces `Expr.symbol` with canonical pointer

### Phase 2: Runtime Objects (LispObject)
- [ ] **Task 2.1**: Implement `LispObject` with `ObjType` union and GC linked list
  - Test: create nil/number/symbol/cons objects
- [ ] **Task 2.2**: Implement `ConsCell` with `car`/`cdr`
  - Test: build (1 2 3) as cons cells
- [ ] **Task 2.3**: Implement `Closure` with parameters, body, env
  - Test: create closure from defn AST

### Phase 3: Environment & Scoping
- [ ] **Task 3.1**: Implement `Environment` with parent chain and `StringHashMap` bindings
  - Test: bind + lookup in same frame
  - Test: lookup in parent frame
  - Test: shadowing (inner frame overrides outer)
- [ ] **Task 3.2**: Implement stack operations (push/pop/peek/drop/swapped/dup)
  - Test: push/pop roundtrip
  - Test: dup/swapped
  - Test: drop N items

### Phase 4: Primitives (Core Language)
- [ ] **Task 4.1**: Implement arithmetic (`+`, `-`, `*`, `/`)
  - Test: `(+) = 0`, `(+ 1 2) = 3`, `(+ 1 2 3) = 6`
  - Test: `(- 10 5) = 5`
  - Test: `(* 2 3 4) = 24`
  - Test: `(/ 10 2) = 5`
- [ ] **Task 4.2**: Implement comparison (`=`, `<`, `>`, `null?`)
  - Test: `(= 1 1) = true`, `(= 1 2) = false`
  - Test: `(< 1 2) = true`, `(> 3 2) = true`
  - Test: `(null? nil) = true`, `(null? 1) = false`
- [ ] **Task 4.3**: Implement list operations (`cons`, `car`, `cdr`, `null?`, `list?`)
  - Test: `(cons 1 nil) = (1)`
  - Test: `(car (1 2)) = 1`, `(cdr (1 2)) = (2)`
  - Test: `(length (1 2 3)) = 3`

### Phase 5: Variable Binding & Defn
- [ ] **Task 5.1**: Implement `def` special form
  - Test: `(def x 42) → set x to 42`
  - Test: `(def x 42) → x → 42`
- [ ] **Task 5.2**: Implement `let` special form
  - Test: `(let (x 1) (+ x 1)) = 2`
  - Test: `(let (x 1) (let (x 2) x)) = 2`

### Phase 6: Conditionals & Control Flow
- [ ] **Task 6.1**: Implement `if` special form
  - Test: `(if true 1 2) = 1`
  - Test: `(if false 1 2) = 2`
- [ ] **Task 6.2**: Implement `cond` special form
  - Test: multi-clause cond

### Phase 7: Functions & Closures
- [ ] **Task 7.1**: Implement `fn` special form (anonymous functions)
  - Test: `(fn (x) (+ x 1))` creates a closure
- [ ] **Task 7.2**: Implement function application
  - Test: `((fn (x) (+ x 1)) 5) = 6`
  - Test: nested calls
- [ ] **Task 7.3**: Implement `defn` special form (named functions)
  - Test: `(defn add (a b) (+ a b))` + call

### Phase 8: Tail-Call Optimization
- [ ] **Task 8.1**: Implement `tailcall` bytecode instruction
  - VM pops current frame and reuses stack for callee
- [ ] **Task 8.2**: Compiler detects tail calls
  - Test: recursive factorial uses constant stack

### Phase 9: REPL & Extras
- [ ] **Task 9.1**: Add REPL loop (read → eval → print)
- [ ] **Task 9.2**: Implement `print` primitive
- [ ] **Task 9.3**: Implement `macro` support (optional, later)

---

## 6. Test Strategy

Every task must have at least one test. Tests are added to `src/root.zig` using Zig's
built-in `test` keyword.

```zig
test "primitive + basic" {
    var vm = Vm.init(page_allocator);
    defer vm.deinit();
    
    const result = try vm.evalString("(+ 1 2 3)");
    const num = try asNumber(result);
    try std.testing.expectEqual(@as(i64, 6), num);
}
```

Run all tests: `zig test src/root.zig`

---

## 7. Known Constraints

- Zig 0.16.0: `ArrayList` requires allocator in `deinit()` and `toOwnedSlice()`
- ArenaAllocator is used for AST (short-lived); GC heap for runtime objects (long-lived)
- No garbage collector yet — objects are reference-counted via ArenaAllocator scope
- Symbol internment uses `StringHashMap` backed by ArenaAllocator
