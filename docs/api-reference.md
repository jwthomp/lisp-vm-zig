# Lisp VM — Built-in Functions API Reference

## Overview

The Lisp VM provides built-in functions compiled into the interpreter. They are called as function calls: `(func arg1 arg2 ...)`. All return values are `LispObject`s pushed to the stack; `print`/`println` return `nil`.

## Special Forms

Special forms are handled by the compiler/evaluator, not executed as regular functions.

| Form | Arity | Description | Notes |
| --- | --- | --- | --- |
| `def` | 2 | `(def name value)` | Bind `value` in current env |
| `defn` | N | `(defn name (params) body...)` | Define a function |
| `if` | 2-3 | `(if test then [else])` | Conditional |
| `cond` | N | `(cond pred action ... [else])` | Multi-way branch |
| `quote` | 1 | `(quote x)` | Return `x` unevaluated |
| `let` | N | `(let ((name val) ...) body...)` | Bind locals |
| `do` | N | `(do expr...)` | Sequential eval, returns last |
| `fn` | N | `(fn (params) body...)` | Create closure object |
| `defmacro` | N | `(defmacro name (args) body)` | Define macro |
| `defpackage` | N | `(defpackage name ...)` | Define package |

## Arithmetic

All arithmetic built-ins take integers. Non-number args return `TypeError` except comparisons which return `0`.

| Name | Arity | Returns | Notes |
| --- | --- | --- | --- |
| `+` | 2+ | `number` | Sum (2-argument only in VM) |
| `-` | 2 | `number` | `left - right` |
| `*` | 2+ | `number` | Product (2-argument only) |
| `/` | 2 | `number` | Truncated integer division |
| `rem` | 2 | `number` | Modulo / remainder |

**Error:** `/` and `rem` return `DivisionByZero` when divisor is `0`. All return `TypeError` on non-number args.

### Examples

```lisp
(= 2 2)       ; → 1  (equal?)
(= 1 2)       ; → 0  (not equal)

(+ 1 2 3)     ; → 6
(- 10 3)      ; → 7
(* 3 4)       ; → 12
(/ 7 3)       ; → 2  (truncated)
(rem 7 3)     ; → 1
```

## Comparison

| Name | Arity | Returns | Notes |
| --- | --- | --- | --- |
| `=` | 2 | `number` (1/0) | Numeric equality |
| `<` | 2 | `number` (1/0) | Numeric less-than |
| `>` | 2 | `number` (1/0) | Numeric greater-than |
| `<=` | 2 | `number` (1/0) | Numeric ≤ |
| `>=` | 2 | `number` (1/0) | Numeric ≥ |
| `equal?` | 2+ | `number` (1/0) | Deep structural equality |

**Note:** All comparisons return `0` (false) for non-numeric args (except `equal?` which handles types).

### `equal?` Examples

```lisp
(equal? 1 1)        ; → 1
(equal? 1 2)        ; → 0
(equal? "a" "a")    ; → 1  (string equality)
(equal? "a" "b")    ; → 0
(equal? nil nil)    ; → 1
```

## Bitwise

| Name | Arity | Returns | Notes |
| --- | --- | --- | --- |
| `bit-and` | 2 | `number` | Bitwise AND |
| `bit-or` | 2 | `number` | Bitwise OR |
| `bit-not` | 1 | `number` | Bitwise NOT (one's complement) |
| `bit-shl` | 2 | `number` | Shift left |
| `bit-shr` | 2 | `number` | Shift right (signed) |

## List Operations

| Name | Arity | Returns | Notes |
| --- | --- | --- | --- |
| `cons` | 2 | `list` | Create cons cell |
| `car` | 1 | `any` | Car of cons cell |
| `cdr` | 1 | `list` | Cdr of cons cell |
| `length` | 1 | `number` | Count cons cells in list |
| `append` | 2+ | `list` | Concatenate lists |
| `reverse` | 1 | `list` | Reverse list |
| `member` | 2 | `list`/`nil` | First sublist starting with `item`, or `nil` |
| `assoc` | 2 | `list`/`nil` | Find `item` in alist (car-comparison) |
| `map` | N | `list` | `(map fn val...)` — map function across lists |
| `filter` | N | `list` | `(filter pred list)` — keep items where pred is true |

### `cons`/`car`/`cdr`

```lisp
(cons 1 (cons 2 nil))  ; → (1 2)
(car (cons 1 2))       ; → 1
(cdr (cons 1 2))       ; → 2
```

### `length` / `append` / `reverse`

```lisp
(length (cons 1 (cons 2 nil)))  ; → 2
(append (cons 1 nil) (cons 2 nil))  ; → (1 2)
(reverse (cons 1 (cons 2 nil)))   ; → (2 1)
```

### `member` / `assoc`

```lisp
(member 2 (cons 1 (cons 2 (cons 3 nil))))  ; → (2 3)
(member 99 (cons 1 (cons 2 nil)))           ; → nil
(assoc 2 (cons (cons 1 nil) (cons (cons 2 nil) (cons (cons 3 nil) nil))))  ; → (2 . nil)
```

## Predicates

| Name | Arity | Returns | Notes |
| --- | --- | --- | --- |
| `null?` | 1 | `number` (1/0) | Returns `1` if arg is `nil` |
| `not` | 1 | `number` (1/0) | Logical NOT (nil→1, otherwise→0) |
| `symbol?` | 1 | `number` (1/0) | Type predicate |
| `number?` | 1 | `number` (1/0) | Type predicate |
| `list?` | 1 | `number` (1/0) | Type predicate (cons or nil) |
| `even?` | 1 | `number` (1/0) | `true` if negative/odd integer is even? |
| `odd?` | 1 | `number` (1/0) | `true` if odd integer |
| `positive?` | 1 | `number` (1/0) | `true` if value > 0 |
| `negative?` | 1 | `number` (1/0) | `true` if value < 0 |

### Examples

```lisp
(null? nil)    ; → 1
(null? 1)      ; → 0
(not nil)      ; → 1
(not 1)        ; → 0
(even? 4)      ; → 1  (even)
(even? 3)      ; → 0
(odd? 3)       ; → 1
(odd? 4)       ; → 0
(positive? 5)  ; → 1
(negative? -1) ; → 1
```

## String Functions

| Name | Arity | Returns | Notes |
| --- | --- | --- | --- |
| `str` | N | `string` | Convert all args to string and concatenate |
| `str-cat` | 2+ | `string` | Concatenate strings (alias for `str`) |
| `str-len` | 1 | `number` | Length of string in bytes |
| `str=?` | 2 | `number` (1/0) | String equality |
| `substr` | 2-3 | `string` | Extract substring `(substr s start [end])` |

### `str` / `str-cat`

Converts all arguments to strings and concatenates. Numbers, symbols, and strings all supported.

```lisp
(str "hello")      ; → "hello"
(str 42)            ; → "42"
(str "foo" "bar")   ; → "foobar"
(str "hello" " " "world")  ; → "hello world"
```

### `str-len` / `str=?`

```lisp
(str-len "hello")   ; → 5
(str-len "")        ; → 0
(str=? "abc" "abc")  ; → 1
(str=? "abc" "def")  ; → 0
```

### `substr`

Extract a substring. Args: string, start index, optional end index.

```lisp
(substr "hello world" 0 5)   ; → "hello"
(substr "hello world" 6)     ; → "world"
(substr "hello" 2 4)         ; → "ll"
(substr "hello" 3 3)         ; → "" (empty)
```

## Type Functions

| Name | Arity | Returns | Notes |
| --- | --- | --- | --- |
| `type-of` | 1 | `string` | Type name as string |

**Returns:** `"nil"`, `"number"`, `"symbol"`, `"list"`, `"string"`, `"builtin"`, `"closure"`, `"unknown"`.

```lisp
(type-of 42)        ; → "number"
(type-of "hello")   ; → "string"
(type-of nil)       ; → "nil"
(type-of (cons 1 nil))  ; → "list"
```

## I/O

| Name | Arity | Returns | Notes |
| --- | --- | --- | --- |
| `print` | 1 | `nil` | Print value, return `nil` |
| `println` | N | `nil` | Print args, newline-separated, return `nil` |
| `load` | 1 | `any` | Load and eval a `.lisp` file |
| `import` | 1 | `any` | Import a package |

## Error Behavior

### Error Types

| Error | Cause |
| --- | --- |
| `StackUnderflow` | Called with fewer args than required |
| `TypeError` | Wrong argument type for arithmetic ops |
| `DivisionByZero` | Divisor is zero in `/` or `rem` |
| `OutOfMemory` | Allocation failure |

### Error Propagation

Errors propagate from primitive implementations via Zig's error unions. When a builtin call fails, the error bubbles up through the VM's `callPrim` layer.

## Compilation Notes

Built-in functions are dispatched via hash map lookup (`dispatch_table`). The compiler uses `emitConstRef` + `emitSymbol` to push builtins as values, then `emitCall` with arg count. This is separate from direct builtin dispatch in interpreted execution.

The `bytecode_compile_constants` pool (strings) is separate from `bc.constants` (symbols/builtins) to avoid index collisions.

## API Reference Summary

### Complete Built-in List

```
+, -, *, /, rem
=, <, >, <=, >=
bit-and, bit-or, bit-not, bit-shl, bit-shr
cons, car, cdr, length, append, reverse, member, assoc, map, filter
print, println, load, import
null?, not, symbol?, number?, list?, even?, odd?, positive?, negative?
equal?
str, str-cat, str-len, str=?, substr
type-of
```

**Total:** 39 built-in functions across 10 categories.