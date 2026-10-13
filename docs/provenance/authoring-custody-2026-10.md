# Typed authoring custody software evidence

Home commit `7f50efd` adds tagged source/draft/bundle/fixture/contract/envelope/
profile/definition objects to the existing private Custody. V1 Artifact parsing
and its historical backup encoding remain separate. Tagged objects establish
byte custody only, without document compatibility, source truth or admission.

On 2026-10-14, pinned Elixir 1.19.6 / Erlang OTP 28.5.0.6 executed:

- `mix test test/wotex_home/authoring_object_test.exs test/wotex_home/authoring_object_custody_test.exs test/wotex_home/authority_authoring_object_test.exs test/wotex_home/portable_profile_custody_test.exs test/wotex_home/portable_profile_archive_test.exs`:
  42 tests passed. Python-generated frame/digest vectors match exactly. Every
  kind's byte boundary, corrupt/version/tag/length/native input, quota sharing,
  immutable duplicate publication, actual root-file restart/orphan recovery,
  lease ownership/capacity, Store-only all-or-nothing export and collection pass.
  Authenticated Authority staging checks current profile:manage, refuses a
  revoked actor and changes no Store revision or approval.
- `mix test test/wotex_home/durable_profiles_test.exs test/wotex_home/profile_byte_context_test.exs`:
  22 tests passed, retaining existing v1 approval, byte-context, collection and
  durable lifecycle behavior.
- Format, warnings-as-errors compilation, catalogue and Git whitespace checks
  passed. The working catalogue checks 22 contracts; unrelated target drafts
  retain their own status. No full application/native build or Dialyzer was run
  for this bounded storage component.

Objects share the existing 128-object, 4-MiB and 32-lease ceilings; the complete
42-byte header counts toward bytes. Same payload under different kinds has a
different complete-file identity. Wrong API reads cannot turn a tagged source
into a v1 approved profile. Export is bounded by the selected custody byte quota
before reading the selected set. Published/private file checks continue using
the pinned root, descriptor identity, mode, UID and synchronized hard-link scheme.

This component changes no SQLite schema and owns no authoring journal/provider
attempt. Authenticated durable reference ownership, retained source/draft rows,
current-basis assessment, generation policy/handoff, backup packaging and admission
are subsequent authoring obligations. No remote source/model, device, Store
connection or bearer is supplied by the payload, and physical dispatch stays
under its separate default-disabled qualification guard.
