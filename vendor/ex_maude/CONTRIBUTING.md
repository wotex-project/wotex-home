# Contributing to ExMaude

Thank you for your interest in contributing to ExMaude!

## Getting Started

1. Fork the repository
2. Clone your fork: `git clone https://github.com/YOUR_USERNAME/ex_maude.git`
3. Install dependencies: `mix setup`
4. Create a feature branch: `git checkout -b feature/amazing-feature`

## Development

```bash
mix setup          # Install dependencies
mix test           # Run tests
mix lint           # Run linters (format, credo, dialyzer)
mix check --no-retry # Run all quality checks, including previously passing ones
mix docs           # Generate documentation
mix bench          # Run benchmarks
```

## Running Integration Tests

Integration tests require Maude to be installed:

```bash
mix maude.install                    # Install Maude
mix test --include integration       # Run all tests including integration
```

## Code Quality

Before submitting a PR, ensure:

- [ ] All tests pass: `mix test`
- [ ] Code is formatted: `mix format`
- [ ] Credo passes: `mix credo --strict`
- [ ] Dialyzer passes: `mix dialyzer`
- [ ] Documentation is updated

## Commit Messages

Follow [Conventional Commits](https://www.conventionalcommits.org/):

- `feat:` new features
- `fix:` bug fixes
- `docs:` documentation changes
- `refactor:` code refactoring
- `test:` test additions or changes
- `chore:` maintenance tasks

## Pull Request Process

1. Ensure your code follows the project style
2. Update documentation as needed
3. Add tests for new functionality
4. Use a Conventional Commit message so git_ops can generate the changelog
5. Submit a PR with a clear description

## Releases

Releases are managed by maintainers using git_ops:

1. Ensure all tests pass: `mix check --no-retry`
2. Run `mix release` (alias for `mix git_ops.release`) — updates changelog, bumps version, commits, and tags
3. Push with tags: `git push --follow-tags`
4. The tag starts the precompiled-NIF workflow; Hex publishing runs only after
   that workflow succeeds and its exact tagged commit is verified

### What the tag triggers

The `v*` tag drives a two-stage pipeline:

1. **release.yml** builds precompiled NIF binaries for every supported
   target (macOS aarch64/x86_64, Linux gnu/musl × aarch64/x86_64,
   Windows gnu/msvc) and attaches them to the GitHub release.
2. **publish.yml** runs after the NIF build succeeds. It checks the
   project out, runs the test/lint suite, then executes
   `mix rustler_precompiled.download ExMaude.Backend.NIF.Native --all --print`
   to populate `checksum-Elixir.ExMaude.Backend.NIF.Native.exs` from the
   uploaded artifacts, and only then runs `mix hex.publish`. The checksum
   file is intentionally empty in git — it must be generated against the
   release artifacts at publish time, or consumers could not verify their
   downloaded NIF binaries.

## Questions?

Open an issue for questions or discussions.

The complete `mix check --no-retry` gate includes Rust tests and RustSec advisory
checks. Without `--no-retry`, ex_check may run only the tools that failed on the
previous invocation.
Install the audit tool with `cargo install cargo-audit --locked --version 0.22.1`.
Release artifacts and native CI use Rust 1.91.1 with the committed Cargo lockfile.
