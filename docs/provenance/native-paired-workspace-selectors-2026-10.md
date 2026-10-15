# Paired workspace source and fixture selector evidence

Recorded: 2026-10-15. Owner: [workspace session](../specs/native-paired-generation-workspace-session-v1.md)
PGW-03/PGW-T3a and selected generation PGU-T4.
Requirements preceded code in 1639250. The bounded handle join is implemented in
550ab9cd3b8b9d8619a9eb951a226996d8f5c202; live fixtures are in
8be840419b81ba8f5ddeb2a71b3e49ae2555696a, both local main commits.
No schema, dependency, producer API or original wire encoding changed.

## Boundary and independent oracle

The generated-draft adapter now uses one explicit bounded handle join before its
owned-object reads. It accepts at most 32 closed digest/first-revision rows,
collapses identical references, refuses conflicting revisions and sorts by digest.
Actual source and fixture reads still require the exact kind and first revision
under the same original paired scope. The join creates metadata, never authority.

`python3 test/support/native_paired_workspace_selectors_oracle.py --check` passed
with eight valid and 17 invalid frozen cases. Expectations are explicit Python
sets/order and do not invoke Swift, Home or BEAM. Cases include empty input,
repeated passages, reverse/interleaved digest order, 32 unique/duplicate rows,
signed maximum, conflicting revisions, 33 rows, unknown/missing keys, bool/float/
string/null/overflow revisions and malformed digests. Corpus SHA256:
`aa481258f06225f42d9dfba65d912612b8ac11370d5368a8f3776170cc9e0729`.

## Executed checks

Pinned Elixir 1.19.6/OTP 28.5.0.6 through `mise exec --`; Swift 6.4 in Swift 6
mode with warnings-as-errors and arm64 macOS 15 target on the development host.

- `mix woh.native.paired.workspace.smoke` passed the 25 new joins, existing 245
  independent transitions, private-file/inode witnesses and unsigned factory
  refusal. This checks the actual join used by the generated-draft adapter.
- `mix woh.native.paired.recovery.smoke --workspace-selectors` passed temperature
  and research cohorts over real pairing, pinned loopback TLS, SQLite and private
  object custody. Each imports the frozen source at first revision 5 and its
  family fixture at 6. The explicit root selects disjoint ranges offset 0/length 26
  and offset 26/length 58 from that source, plus that fixture. The manual assessment
  request contains exactly one source handle and one fixture handle. Its actual
  Store original is compatible with source review still not_assessed.
- For each family, replies for each selected source/fixture are faulted separately
  by kind and first revision: eight adverse exchanges across both cohorts. The
  fault must actually be reached once. Each refuses invalidResponse with zero
  mutation requests, no candidate original and unchanged Store revision/private
  workspace. These faults alter only a real TLS owner's returned DTO, never a
  signing backend or successful production seal.
- Preparation/attempt committed replies are dropped and recovered status-first
  without replay. One gated synthetic provider call per cohort remains the oracle
  through cancellation, pending restoration/archive, native/Store restart and
  revocation. Physical dispatch is checked disabled. No external model is used.
- Focused formatting, compilation with warnings-as-errors, specification catalogue,
  oracle regeneration check, HTML ExDoc with warnings-as-errors and Git whitespace
  checks passed. No full application suite, Dialyzer or hardware check was run.

Frozen source/fixture input SHA256 (`generation-inputs.json`):
`fea95619fdcb9dbdf448159151c5cccad0ac89301042b2ec50bae989e510f359`.
Unchanged `mix.lock` SHA256:
`3372ef86b264343efeedea270b3a8d0548650898043aa0e360daba46c7aaf184`.
Logs: `/tmp/home-native-paired-selectors-{vectors,transport,docs}.log`.
Synthetic keys and inputs use stdin/private fixture files; no real hardware
identity, source locator or model account is accessed.

## Evidence limits

This closes the nonempty selector software gap recorded by the earlier workspace
and selected-generation checks. Raw transport owners have 15-second deadlines and
multi-action scenarios have 45-second bounds; production signed sessions retain
five seconds. A correctly framed owned source or compatible mechanics result does
not establish attribution truth, complete fixture/consumer review, approval,
admission or physical qualification. Positive installed signing/Keychain, same-lease
file/publication and UI delivery races, accessibility, live provider confinement,
storage power-loss and hardware qualification retain their existing obligations.
