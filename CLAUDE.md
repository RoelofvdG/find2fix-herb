# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A Julia research project using the [Herb.jl](https://herb-ai.github.io/) program synthesis framework to automatically generate candidate Java bug fixes. Given a buggy Java program, it synthesizes replacement expressions by building a context-free grammar from extracted code templates and available context, then enumerating candidates via breadth-first search.

## Running the Scripts
Use the julia environment in the herb directory: `--project=.`

```bash
julia find2fix.jl   # Enhanced: templates + context grammar, BFS, adds type-hierarchy reachability filtering, max_depth=4
julia roelof.jl        # Minimal Herb smoke test
julia dekel.jl         # Minimal Math.max/Math.min example
```

There is no build step or test suite — running a script is the test.

## Architecture

### Data files (inputs)

| File | Format | Purpose |
|------|--------|---------|
| `templates.txt` | `expr -> ASTNodeType -> returnType` blocks separated by `###` | Java expressions extracted from the buggy program; placeholders like `_TypeName_N` mark typed holes |
| `context.txt` | Three sections (variables, class methods, instance methods) | In-scope names and callable methods at the bug location |
| `type_hierarchy.txt` | `ChildType -> extends\|implements -> ParentType` | Java subtype relationships |
| `target_type.txt` | Key–value metadata | Bug location (class + line) and target return type |

### Pipeline (`newfind2fix.jl` — canonical version)

1. **`parse_templates(filename)`** — splits `templates.txt` on `###`, extracts `(code, return_type, arg_types)` per template, and defines `templateN(args...)` Julia functions that do placeholder substitution.

2. **`load_context(filename, grammar)`** — parses `context.txt` into grammar rules: variables become terminals, zero-arg methods become string terminals, parameterized methods become `context_method_N(paramTypes...)` grammar rules. Returns `initial_types` (types of all terminals).

3. **`parse_type_hierarchy(filename)`** — reads subtype edges.

4. **`compute_reachable_types(initial_types, ...)`** — fixpoint expansion: a type is reachable if it's a variable/terminal type, or all its argument types are already reachable (via templates, hierarchy, or context methods). This prunes unusable grammar rules before adding them.

5. Grammar assembly — only templates/hierarchy rules whose arg types are all reachable are added via `add_templates_to_grammar!` / `add_hierarchy_to_grammar!`.

6. **`HerbSearch.BFSIterator(grammar, :Start, max_depth=4)`** — enumerates all programs in the grammar up to depth 4.

### `find2fix.jl` (earlier version)

Same idea but without reachability filtering. Uses `@csgrammar` directly and has a separate `render_expr(expr, template_map)` function that reconstructs Java strings from synthesized Herb `RuleNode` trees by reversing the placeholder substitution.

### Key design detail: placeholder format

Templates contain typed holes spelled `_TypeName_N` (e.g., `_Shape_0`, `_double_1`). The leading `_` preceded by a non-`.` ensures field accesses like `obj._field` are not mismatched. `sanitize_type` / `normalize_type_name` strip Java package prefixes and illegal Julia symbol characters (`[]`, `.`).
