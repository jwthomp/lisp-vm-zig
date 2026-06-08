# Lisp VM — Minimal Bytecode Interpreter in Zig

A minimal Lisp VM written in Zig 0.16.0, featuring a stack-based bytecode interpreter with first-class macros, tail-call optimization, and a package system.

## Status

**89/89 tests passing.** All core features implemented.

## Features

| Category | Details |
|----------|---------|
| **Language** | S-expression parser, homoiconic AST, `quote`/`'` sugar |
| **Functions** | `fn`, `defn`, closures with lexical scoping |
| **Macros** | `defmacro`, `when`/`unless`, nested expansion |
| **TCO** | Tail-call optimization via while-loop eval (no stack overflow) |
| **Scoping** | `let` with sequential bindings, parent-chain env, shadowing |
| **Primitives** | `+`, `-`, `*`, `/`, `=`, `<`, `>`, `cons`, `car`, `cdr` |
| **Predicates** | `null?`, `symbol?`, `number?`, `list?` |
| **Sequence** | `length`, `quote`, `print`, `println` |
| **Package System** | `defpackage`, `import`, `load` |
| **Standard Lib** | `stdlib.lisp` — `append`, `reverse`, `member`, `assoc`, `map`, `filter`, `flatten`, `every?`, `some?`, `not`, `atom?`, `sum` |

## Project Structure

```
├── src/root.zig       — Lexer, parser, compiler, VM, REPL, tests
├── DESIGN.md          — Architecture docs, eval/apply model, milestone table
├── stdlib.lisp        — Pure-Lisp standard library functions
├── examples/          — Example .lisp programs (fib, factorial, quicksort, etc.)
├── .beads/            — Issue tracking database (local dev, gitignored)
├── AGENTS.md          — Agent workflow instructions (br/beads commands)
└── README.md          — This file
```

## Build & Test

```bash
zig build               # Compile (requires Zig 0.16.0)
zig test src/root.zig   # Run all 89 tests
zig build -Doptimize=ReleaseFast  # Optimized build
```

## Architecture

```
Source ──► Lexer ──► []Token ──► Parser ──► Expr (AST)
                                      │
                           SymbolTable (internment)
                                      │
                          ┌───────────┴───────────┐
                          │    Vm.eval() loop     │
                          └───────────┬───────────┘
                                      │
                     ┌────────────────┼────────────────┐
                     │                │                 │
              Environment       LispObject          Primitives
              (parent chain)    (GC heap)           (stack ops)
```

**Eval/Apply** — `eval(expr, env)` traverses the AST. Lists are calls: `(f a b)` evaluates `f` to a function value, then applies it with evaluated arguments. `defn` is syntactic sugar for `def` + `fn`.

**TCO** — The eval loop is a `while(true)` that re-enters on function calls instead of pushing stack frames. Recursive functions up to 1000+ levels run without overflow.

## Known Issues

1. **Recursive self-call crash** — Closures calling themselves by name (e.g., `fib`) may crash due to closure lookup in child environments.
2. **`std.fs` unavailable in test harness** — `load` builtin works in REPL but not in tests (Zig 0.16 stdlib limitation).
3. **`std.debug.print` crashes in test mode** — Forces stdout-based formatting workaround.

## Issue Tracking

Issues are tracked via [beads_rust](https://github.com/Dicklesworthstone/beads_rust) (`br`). The SQLite database lives in `.beads/` and is gitignored for local dev state.

```bash
br ready              # View actionable issues
br create --title="..." --type=bug --priority=0
br close <id>         # Mark complete
br sync --flush-only  # Export changes to JSONL
```

See `AGENTS.md` for full workflow instructions.
