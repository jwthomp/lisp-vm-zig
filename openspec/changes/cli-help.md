# Change: CLI Help and Argument Parsing

- **Status**: Archived
- **Created**: 2026-06-08
- **Issue**: sqhn-007

## Problem

The CLI has no argument parsing at all. Running `lisp-vm --help` or `lisp-vm -h` produces no output. There is no way to:
- See available options
- Load a file for batch execution
- See version information

**Current behavior:**
```
$ lisp-vm --help
(no output, goes into REPL)
$ lisp-vm
Lisp VM REPL — type 'quit' to exit
>
```

**Expected behavior:**
```
$ lisp-vm --help
Usage: lisp-vm [OPTIONS] [FILE]

A minimal Lisp bytecode VM.

Options:
  -h, --help      Show this help message
  -v, --version   Show version
  -f, --file FILE Load and execute a Lisp source file, then exit
                  (multiple -f flags execute in order)

Examples:
  lisp-vm                  Start interactive REPL
  lisp-vm --help           Show help
  lisp-vm -f program.lisp  Run a Lisp file
  lisp-vm -f stdlib.lisp -f program.lisp  Run multiple files
```

## Design

Add simple argument parsing in `main()` using `std.process.args`.

### Argument spec

| Flag | Long form | Description |
|------|-----------|-------------|
| `-h` | `--help` | Print usage help and exit |
| `-v` | `--version` | Print version and exit |
| `-f FILE` | `--file FILE` | Load and execute a Lisp source file (repeatable) |
| *(positional)* | `FILE` | Alternative to `-f`: load one file, then exit |

### Flag precedence

1. `--help` / `-h` — always first (print and exit)
2. `--version` / `-v` — always first (print and exit)
3. `-f FILE` / `--file FILE` — execute file, then continue parsing
4. Positional FILE — execute file if no `-f` given (only one allowed)
5. If nothing specified (or after all files), enter REPL

### Implementation sketch

```zig
pub fn main() void {
    if (@import("builtin").is_test) return;

    var env = Environment.init(null, std.heap.page_allocator);
    defer env.deinit();
    var vm = Vm.init(std.heap.page_allocator, &env);
    defer vm.deinit();

    // Parse arguments
    var args = std.process.args();
    const progName = args.next() orelse "lisp-vm";
    
    var file_list = std.ArrayList([]const u8).init(std.heap.page_allocator);
    defer file_list.deinit();
    
    var interactive = true;
    var show_help = false;
    var show_version = false;
    var has_positional = false;
    
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            show_help = true;
            break;  // help is always last flag processed
        }
        if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--version")) {
            show_version = true;
            break;
        }
        if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--file")) {
            const fname = args.next() orelse {
                debugPrint("Error: -f requires a filename\n", .{});
                std.process.exit(1);
            };
            file_list.append(fname) catch unreachable;
            interactive = false;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-")) {
            debugPrint("Unknown option: {s}\n", .{arg});
            debugPrint("Use --help for usage\n", .{});
            std.process.exit(1);
        }
        // Positional file argument
        if (has_positional) {
            debugPrint("Error: multiple files specified without -f\n", .{});
            std.process.exit(1);
        }
        file_list.append(arg) catch unreachable;
        has_positional = true;
        interactive = false;
    }

    if (show_help) {
        printHelp(progName);
        return;
    }

    if (show_version) {
        debugPrint("lisp-vm 0.1.0\n", .{});
        return;
    }

    // Execute files
    var i: usize = 0;
    while (i < file_list.items.len) : (i += 1) {
        if (!loadFile(&vm, &env, file_list.items[i])) {
            debugPrint("Error: could not load {s}\n", .{file_list.items[i]});
            std.process.exit(1);
        }
    }

    // REPL mode
    if (interactive) {
        replLoop(&vm, &env);
    }
}

fn printHelp(program: []const u8) void {
    const help =
        \\Usage: {s} [OPTIONS] [FILE]
        \\
        \\A minimal Lisp bytecode VM.
        \\
        \\Options:
        \\  -h, --help       Show this help message
        \\  -v, --version    Show version
        \\  -f, --file FILE  Load and execute a Lisp source file
        \\
        \\Examples:
        \\  {s}                  Start interactive REPL
        \\  {s} --help           Show help
        \\  {s} -f program.lisp  Run a Lisp file
        \\;
    ;
    debugPrint(help, .{ program, program, program, program });
}
```

## Acceptance Criteria

- [ ] `lisp-vm --help` prints formatted help message and exits cleanly
- [ ] `lisp-vm -h` produces the same output as `--help`
- [ ] `lisp-vm --version` prints version and exits cleanly
- [ ] `lisp-vm -v` produces the same output as `--version`
- [ ] `lisp-vm` with no arguments starts REPL (unchanged behavior)
- [ ] `lisp-vm -f file.lisp` loads and executes the file, then exits
- [ ] `lisp-vm -f a.lisp -f b.lisp` loads both files in order, then exits
- [ ] `lisp-vm file.lisp` loads one file, then exits (positional arg)
- [ ] Unknown flag `-x` prints error and exits with non-zero code
- [ ] `-f` without filename prints error and exits with non-zero code
- [ ] `--help` and `--version` work even if other flags follow
- [ ] All 89 existing tests still pass

## Files to Modify

- `src/root.zig` — `main()` function (line ~4862)
- May need to make `loadFile` function accessible from `main`
