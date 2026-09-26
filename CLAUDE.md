# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

This is the repository for the **Crystal programming language**: the compiler (written in Crystal itself) plus the standard library. Crystal has Ruby-like syntax, static type checking with global type inference, and compiles to native code via LLVM.

## Build

The compiler is self-hosting: building it requires an already-installed Crystal compiler (the "bootstrap" compiler, see `CRYSTAL_BOOTSTRAP_VERSION` in `bin/ci`) plus LLVM.

- `make` / `make crystal` — build the compiler to `.build/crystal`.
- `make crystal release=1 interpreter=1` — release build with the interpreter feature enabled.
- `make progress=1` — build with progress output.
- `make clean crystal` — clean then rebuild.
- `make help` — list all targets and optional `var=value` flags.

LLVM is auto-detected via `src/llvm/ext/find-llvm-config.sh`; override with `LLVM_CONFIG` or `LLVM_VERSION`. For LLVM < 18 a C++ shim (`src/llvm/ext/llvm_ext.o`) is compiled as a dependency. Place machine-local make overrides in `Makefile.local`. Windows uses `Makefile.win`.

## Running the compiler

Always use the wrapper `bin/crystal`, not a globally-installed `crystal`. The wrapper points `CRYSTAL_PATH` at this repo's `src/` (so you test against the in-tree stdlib) and execs `.build/crystal` if it has been built, otherwise falls back to the bootstrap compiler. Example: `bin/crystal run foo.cr`, `bin/crystal tool format`, etc.

## Tests (specs)

Specs live in `spec/` and use the stdlib's own `spec` framework. There are three suites:

- `make std_spec` — standard library specs (`spec/std/`).
- `make compiler_spec` — compiler specs (`spec/compiler/`); built `--release`.
- `make primitives_spec` — primitive-method specs, run against a freshly built compiler.
- `make interpreter_spec` — interpreter specs.
- `make test` (a.k.a. `make spec`) — runs std + primitives + compiler.

Each suite compiles to a single binary under `.build/` (e.g. `.build/std_spec`). Pass spec-runner flags via `SPEC_FLAGS`, e.g. `make std_spec SPEC_FLAGS="-v"`. Spec order is randomized by default (`order=random`); pin it with `make std_spec order=default` or a seed.

**Run a single spec file or example** (much faster than the make targets):

```
bin/crystal spec spec/std/array_spec.cr            # one file
bin/crystal spec spec/std/array_spec.cr:42         # the example at line 42
bin/crystal spec spec/std/array_spec.cr -e "sorts" # examples matching a name
```

`spec/support/` holds shared spec helpers (e.g. `it_iterates`, tempfile/IO/fiber helpers); reuse these rather than reinventing setup.

## Format & lint

- `make format` — format `src spec samples scripts` with the in-tree formatter (`bin/crystal tool format`). `make format check=1` only checks. Formatting is mandatory; a pre-commit hook is available at `scripts/git/pre-commit`.
- `make lint-shellcheck` — shellcheck the shell scripts.
- Ameba (Crystal linter) config is `.ameba.yml`; typo checking config is `_typos.toml`.

## Compiler architecture

Entry point is `src/compiler/crystal.cr` → `Crystal::Command.run` (`src/compiler/crystal/command.cr` + `command/` for subcommands like `eval`, `spec`, `docs`, `repl`, `format`). The compilation pipeline under `src/compiler/crystal/`:

1. **`syntax/`** — `lexer.cr` → `parser.cr` produce the AST (`ast.cr`). `to_s.cr` and `transformer.cr`/`visitor.cr` operate over it. This is also the layer the formatter (`formatter.cr`) builds on.
2. **`semantic/`** — type inference and checking, structured as a sequence of AST visitors (`top_level_visitor.cr`, `main_visitor.cr`, the various `*_processor`/`*_visitor` files). Method resolution (`call.cr`, `method_lookup.cr`, `match.cr`), type restrictions, and exhaustiveness checks live here. `program.cr` and `types.cr` model the program and its type system.
3. **`codegen/`** — lowers the typed AST to LLVM IR (`codegen.cr`, `llvm_typer.cr`, `primitives.cr`, ABI handling in `abi/`).

Cross-cutting subsystems: `macros/` (compile-time macro expansion), `interpreter/` (the `crystal i` / REPL interpreter), `tools/` (`crystal tool` commands — `doc`, `format`, `hierarchy`, `implementations`, `context`, `unreachable`, `init`, the `playground`), `loader/`/`ffi/` (dynamic linking, used by the interpreter), and `codegen/link.cr` for native linking.

## Standard library

`src/` is the stdlib, with `src/prelude.cr` as the default require root. Code that the compiler depends on at build time lives in `src/compiler/`. Generated data (Unicode tables, SSL config, etc.) is produced by `make -B generate_data` (`scripts/generate_data.mk`) — edit the generators, not the generated files. C bindings live under `src/lib_c/<target>/`.

## Conventions

- Public API changes require doc comments (third person; subset of Markdown — see the project's "documenting code" guide) and must be validated with specs. Behaviour changes need specs.
- Performance-sensitive changes (compiler, hot stdlib paths) should be backed by benchmarks.
- The compiler version is `src/VERSION`; `shard.yml` tracks the dev version. Vendored shard dependencies are under `lib/` (locked in `shard.lock`).
- Backwards compatibility within a major version is a hard guarantee — avoid breaking existing valid programs.

## Fork context (agent notes)

This is a personal fork working toward a batteries-included stdlib. Agent memory, roadmaps,
research reports and benchmark-harness sources are committed under `.agent-context/`. Read
`.agent-context/README.md` first, then `.agent-context/memory/MEMORY.md`. When a note cites
`.remember/<file>`, look under `.agent-context/notes/` or `.agent-context/harnesses/`
instead. `.remember/` is local-only and gitignored. Test services (PostgreSQL with every auth mode and a
standby, Redis) come from `.agent-context/setup/`: cloud sessions provision them automatically
through the SessionStart hook in `.claude/`; on a workstation run the matching script there.
