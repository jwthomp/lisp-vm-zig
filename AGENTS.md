<!-- br-agent-instructions-v1 -->

---

## Beads Workflow Integration

This project uses [beads_rust](https://github.com/Dicklesworthstone/beads_rust) (`br`/`bd`) for issue tracking. Issues are stored in `.beads/` and tracked in git.

### Essential Commands

```bash
# View ready issues (open, unblocked, not deferred)
br ready              # or: bd ready

# List and search
br list --status=open # All open issues
br show <id>          # Full issue details with dependencies
br search "keyword"   # Full-text search

# Create and update
br create --title="..." --description="..." --type=task --priority=2
br update <id> --status=in_progress
br close <id> --reason="Completed"
br close <id1> <id2>  # Close multiple issues at once

# Sync with git
br sync --flush-only  # Export DB to JSONL
br sync --status      # Check sync status
```

### Workflow Pattern

1. **Start**: Run `br ready` to find actionable work
2. **Claim**: Use `br update <id> --status=in_progress`
3. **Work**: Implement the task
4. **Complete**: Use `br close <id>`
5. **Sync**: Always run `br sync --flush-only` at session end

### Key Concepts

- **Dependencies**: Issues can block other issues. `br ready` shows only open, unblocked work.
- **Priority**: P0=critical, P1=high, P2=medium, P3=low, P4=backlog (use numbers 0-4, not words)
- **Types**: task, bug, feature, epic, chore, docs, question
- **Blocking**: `br dep add <issue> <depends-on>` to add dependencies

### Session Protocol

**Before ending any session, run this checklist:**

```bash
git status              # Check what changed
git add <files>         # Stage code changes
br sync --flush-only    # Export beads changes to JSONL
git commit -m "..."     # Commit everything
git push                # Push to remote
```

### Best Practices

- Check `br ready` at session start to find available work
- Update status as you work (in_progress → closed)
- Create new issues with `br create` when you discover tasks
- Use descriptive titles and set appropriate priority/type
- Always sync before ending session

## Standard Library

The Lisp VM has a growing standard library located in `stdlib/stdlib.lisp`. This file contains high-level Lisp functions implemented using the core primitives (defn, def, cons, car, cdr, if, etc.).

### Current Contents

- `list` — create a list from arguments: `(list 1 2 3)` → `(1 2 3)`

### How to Use the Standard Library

1. **Discover tasks**: Run `br epic status` to see epics and their child tasks. Run `br ready` for actionable items.
2. **Implement functions**: Each function should be a `defn` definition in `stdlib/stdlib.lisp`
3. **Add tests**: For each new function, add a bytecode test in `src/root.zig` using the same pattern as existing tests
4. **Verify**: Run `zig build test` — all tests must pass

### Creating New Standard Library Tasks

To add a new function to the standard library:

1. Find the epic: `br show sqhn-yux` (the Standard Library epic)
2. Create a task as a child of the epic:
   ```bash
   br create --title="Implement sort function" --parent=sqhn-yux --type=task --priority=3
   ```
3. Implement in `stdlib/stdlib.lisp` and add bytecode tests
4. Close the task when done

### Naming Conventions

- Predicates end with `?`: `null?`, `number?`, `list?`, `even?`, `odd?`, `equal?`
- List operations: `car`, `cdr`, `cons`, `append`, `reverse`, `nth`, `member`
- Math: `abs`, `max`, `min`, `mod`, `sqrt`
- Keep function names consistent with Common Lisp conventions

## Epic Management

Epics track larger bodies of work with multiple child tasks:

- `br epic status` — Show all epics and their progress
- Epics are automatically created with type `epic`
- Use `br update <epic-id> --status=closed` when all children are closed

<!-- end-br-agent-instructions -->
