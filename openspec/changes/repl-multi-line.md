# Change: REPL Multi-Line Evaluation

- **Status**: Archived
- **Created**: 2026-06-08
- **Issue**: sqhn-006
- **Related**: sqhn-005 (REPL Stdin API Migration)

## Problem

The REPL only evaluates one line before exiting. After the user types an expression and presses Enter, the VM returns to the prompt but never reads any more input — it closes after the first line.

**Current behavior:**
```
$ ./zig-out/bin/lisp-vm
Lisp VM REPL — type 'quit' to exit
> (+ 1 2)
> 3
> Segmentation fault (or silent exit)
```

**Expected behavior:**
```
$ ./zig-out/bin/lisp-vm
Lisp VM REPL — type 'quit' to exit
> (+ 1 2)
> 3
> (+ 3 4)
> 7
> (defn double [x] (* x 2))
> #<closure>
> quit
```

## Root Cause

`replLoop()` in `src/root.zig` calls `posix.read()` **once** at the start to drain all available stdin:

```zig
const n = posix.read(posix.STDIN_FILENO, &buffer) catch {
    return;
};

if (n == 0) return;
```

For **piped input** this works correctly — all lines are available immediately. But for **interactive** use, the terminal is line-buffered: the first `posix.read()` returns only the first line (terminated by `\n`). After that, no more data is available, so the function processes one line and returns.

## Design

Replace the single-read approach with a **line-by-line read loop** that works for both piped and interactive input.

### Approach: Read one line at a time via blocking reads

```zig
pub fn replLoop(vm: *Vm, env: *Environment) void {
    var line_buf = std.ArrayList(u8).initCapacity(std.heap.page_allocator, 256) catch unreachable;
    errdefer line_buf.deinit(std.heap.page_allocator);

    debugPrint("Lisp VM REPL — type 'quit' to exit\n", .{});

    while (true) {
        // Read one line by polling stdin until \n or EOF
        line_buf.clearRetainingCapacity();
        var buf: [1]u8 = undefined;
        var any_read = false;
        
        while (true) {
            var n: usize = 0;
            const rc = posix.read(posix.STDIN_FILENO, &buf);
            if (rc == 0) break;           // EOF
            if (rc < 0) break;            // error
            n = @intCast(rc);
            any_read = true;
            
            if (buf[0] == '\n' or buf[0] == '\r') break;
            line_buf.append(buf[0]) catch unreachable;
        }

        // If nothing was read and no data appeared (non-interactive),
        // try one more read to handle EOF edge cases
        if (!any_read) {
            var check: [1]u8 = undefined;
            const rc2 = posix.read(posix.STDIN_FILENO, &check);
            if (rc2 == 0) break; // real EOF
            if (rc2 > 0) {
                line_buf.append(check[0]) catch unreachable;
            }
        }

        if (line_buf.items.len == 0) continue;

        const input = line_buf.items;
        var trimmed = input;
        while (trimmed.len > 0 and (trimmed[0] == ' ' or trimmed[0] == '\t')) trimmed = trimmed[1..];
        if (std.mem.eql(u8, trimmed, "quit")) break;

        debugPrint("> ", .{});
        // ... tokenize, parse, eval, print result (unchanged) ...
    }
}
```

### Key changes:
1. Move `while(true)` loop **outside** the read logic
2. Read one line at a time (up to `\n` or EOF) instead of all data at once
3. Keep all existing tokenize/parse/eval/print logic unchanged inside the loop
4. `"quit"` break condition unchanged

### Alternative considered: Non-blocking poll with retry

Using `fcntl(F_GETFL)` to set `O_NONBLOCK` and polling in a loop. Rejected because:
- Adds unnecessary complexity for a synchronous REPL
- Line-by-line blocking read is simpler and more predictable

## Acceptance Criteria

- [ ] Running `./zig-out/bin/lisp-vm` interactively reads and evaluates multiple lines until `quit`
- [ ] Piped multi-line input still works: `echo -e "(+ 1 2)\n(+ 3 4)\nquit" | ./zig-out/bin/lisp-vm`
- [ ] Each line prints a `> ` prompt and result
- [ ] Empty lines are ignored (no crash)
- [ ] No segfault or infinite loop on EOF or invalid input
- [ ] Existing 89 tests still pass

## Files to Modify

- `src/root.zig` — `replLoop()` function (line ~4598)
