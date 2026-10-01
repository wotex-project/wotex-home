# Repository contract

## Scope and ownership

Read [README.md](README.md), [the contract catalogue](docs/specs/catalogue.yaml)
and the contracts relevant to the change. The catalogue distinguishes accepted
targets, implemented behavior and evidence; keep those distinctions intact.
Project semantics belong in `docs/specs/`, host procedures in `native/*/README.md`
and physical test procedures in `docs/labs/`.

Home is one Mix/OTP application. `WotexHome.Authority` owns application use cases;
the single `Durable.Store` owns SQLite, transactions, revisions and host locks.
Transport adapters and Swift presentation consume the authority boundary.
Device workers own their transport without receiving a Store connection or
bearer credential. Preserve these boundaries when adding or changing behavior.

Keep staging, admission, handoff, protocol acknowledgement and observed state
distinct. Synthetic fixtures, compilation, packaging and bounded verification
do not establish physical qualification. Preserve fail-closed guards and the
default-disabled physical dispatch until its actual qualification obligations
are met. AI proposals do not authorize control.

## Work and Git

- Preserve unrelated changes and existing local client settings.
- Make logical local commits with a single concise subject, no spec IDs and no
  commit body. Keep spec references in their owning project documentation.
- Never push a branch, tag, commit or other Git ref. The user performs all pushes.
- Never change repository visibility. Report a visibility dependency in chat
  and continue work that does not require it.
- Keep credentials and private hardware identities out of command arguments,
  logs and tracked files. Use the existing private custody and fixture paths.

## Validation

Use the Elixir/OTP versions in `.tool-versions` and dependencies in `mix.lock`.
`WOTEX_HOME_GIT_DEPS=1` selects the pinned Git sources rather than neighboring
development checkouts. Do not update dependencies as a side effect of a task.

Run checks appropriate to the affected mechanism, using existing tools:

- `mix format --check-formatted`
- `mix compile --warnings-as-errors`
- `mix woh.spec.check` for contract/catalogue edits
- `mix test <affected test files>` for behavioral changes
- `git diff --check` before committing

When Mix's TCP launcher is unavailable, `elixir bin/test.exs <test files>` uses
already-built locked test dependencies and freshly compiles Home. Its
`--socket-free` option omits real socket tests; report that exclusion.
`--firmware-host` adds pure firmware probes without qualifying a board.

Choose native and packaging checks from the owning host guide when those
surfaces change. Documentation-only changes need reference, metadata and Git
boundary checks rather than unrelated application suites. Report checks
actually run, failures and unresolved environment requirements in chat;
declarations and planned checks are not evidence.

## Skills and client discovery

Canonical workflows live in `.agents/skills/<name>/SKILL.md`. Select and apply
them automatically from their descriptions when the task, changed mechanism
or delivery stage matches. Do not ask the user to select a skill or slash
command. Load supporting material only when relevant.

Clients with native skill discovery use that mechanism with implicit invocation
enabled. A client without discovery must inspect the skill descriptions, read
the matching `SKILL.md` files and apply them itself. Claude Code skill discovery
uses ignored individual directory symlinks under `.claude/skills/` pointing to
the canonical skill directories. Create a missing link as
`.claude/skills/<name> -> ../../.agents/skills/<name>`. Preserve existing local
directories and links to other locations; repair a dangling link only when its
target belongs to this repository's canonical skills.

Keep shared repository policy in this file and focused workflows in `.agents`.
Client settings stay local and ignored; shared guidance needs no hooks,
session markers or setup helpers.
