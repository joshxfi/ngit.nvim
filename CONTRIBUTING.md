# Contributing to ngit

ngit is intentionally dependency-free at runtime. New features should preserve
the review-first workflow, asynchronous Git execution, bounded output, and safe
defaults for repository mutations.

## Development

Requirements:

- Neovim 0.10 or newer
- Git

Run the complete checks, formatting verification, and parser benchmarks:

```sh
make check
make format-check
make benchmark
```

Tests create disposable repositories under Neovim's temporary directory. Add
an integration test for every Git mutation, including its failure or conflict
state where applicable. The benchmark uses generated fixtures, warm-up runs,
and median timings; it excludes Git process startup, disk I/O, and rendering.

## Architecture

- `lua/ngit/git/` contains Git commands and parsers. It must not manipulate
  Neovim windows or buffers.
- `lua/ngit/ui/` owns buffers, windows, navigation, and user interaction.
- `lua/ngit/config.lua` contains all public options and validates unknown keys.
- `plugin/ngit.lua` must remain a small, command-only startup entrypoint.

Git commands must:

- use argument arrays rather than a shell;
- use literal pathspecs and `--` before user-controlled paths;
- parse stable or explicitly formatted machine output;
- run asynchronously in user-facing flows;
- cap potentially large previews;
- require confirmation for destructive or history-rewriting actions.

## Documentation

Update both `README.md` and `doc/ngit.txt` when changing commands, mappings, or
configuration. Validate vimdoc with:

```sh
nvim --headless --clean -u NONE -c "helptags doc" -c "qa"
```

`doc/tags` is generated and intentionally ignored.
