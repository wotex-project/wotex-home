# Authoring source access software evidence

Home commit `4f367c4` adds authenticated actor-owned inert payload reads, and
`160b271` adds source-passage projection, checking the complete owned source set before
accessing Custody. The owning contract is profile-authoring-v1.md version 0.1.6.
No digest-only capability or source URI lookup is introduced. Each read validates
the import journal, verifies an actual typed leased object and preserves the
historical first-import revision.

On 2026-10-14, pinned Elixir 1.19.6 / OTP 28.5.0.6 passed 22 focused tests:
`source_passages_test.exs`, `durable_authoring_objects_test.exs` and
`authority_authoring_object_test.exs`. The actual Store/root cases cover ownership,
another actor, orphan files, permission/revocation, tampered bytes, unsafe file
permissions, missing files, custody shutdown, maintenance reads, unchanged
revisions and released leases. Shutting down Custody demonstrates that complete-
set unowned/wrong-kind refusals occur before any attempted byte read. Existing
import/replay/migration/rollback/backup cases remain green in this focused suite.

Python-generated raw/frame and passage identities cover exact Unicode byte
offsets and inert instruction-like source text. Pure cases cover split code
points, invalid UTF-8, Unicode controls, newline/tab preservation, improper and
duplicate/unsorted selectors, wrong summaries/native shapes, 32/33 entries,
4096/4097 bytes, 128-KiB overlapping passage selection and the 4-MiB source-frame
ceiling including all headers. Every complete request either returns exact
selected text/identities or one refusal; no partial output or automatic clipping.

Format, warnings-as-errors compilation, 22-contract catalogue and Git whitespace
checks passed. These are software access/projection checks, not source correctness,
remote export approval, independent model fixtures or physical qualification.
The provider boundary must still recheck its explicit source/export policy before
handoff. No network/provider, native packaging or Dialyzer was used for this stage.
