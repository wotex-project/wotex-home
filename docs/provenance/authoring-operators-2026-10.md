# Typed authoring operator software evidence

Recorded: 2026-10-14. Owner: [authoring operators](../specs/authoring-operators-v1.md).
Level: process, actual SQLite/private socket/CLI and archive-backed software.

The contract preceded runtime code in local commits `5c4c0f5` and `ec9c402`.
Implementation is `fc265c1` on main. No dependency pin, durable schema or socket
frame limit changed. The producer archive identities below are explicit test
inputs, not a claim that the ordinary application consumes those sources.

Elixir 1.19.6 / OTP 28.5.0.6 executed:

- `mise exec -- mix test test/wotex_home/authoring_operator_test.exs
  test/wotex_home/authoring_upload_test.exs test/wotex_home/cli_test.exs
  test/wotex_home/local_api_exchange_test.exs
  test/wotex_home/local_api_route_test.exs
  test/wotex_home/local_api_peer_identity_test.exs`: 29 cases passed in 2.6 seconds.
  These exercise all eight object kinds at their owning byte ceilings, a full
  256-KiB binary import/read, explicit UTF-8 passages and actor privacy, private
  exclusive output, strict wrappers/documents, unavailable custody authorization,
  revoked credentials, chunk replay/conflicts, narrowed quota boundaries,
  nonrenewing expiry, borrower/Store death and changed owner incarnation.
  A real forwarding peer discards import replies before/after a chunk and after
  Store commit; cursor/status recovery retains one original and one revision.
- The command below passed 81 independent component cases in 10.0 seconds and
  two actual Store workflows in 6.9 seconds. Each workflow uses one independent
  quantity (temperature or research), owned source/draft/fixture/envelope bytes,
  manual candidate and complete review. The socket/CLI receipts equal direct
  Authority originals and the fixture correspondence oracle. A forwarding peer
  discards committed candidate and review replies; CLI exits 3 with the exact
  status command, and status/replay resolves the same receipt without a new
  revision. Restart removes upload custody without losing review originals.
  Changed SHA conflicts, source/fixture review remains distinct from approval,
  and a canonical review larger than 65536 bytes reaches Store without expanding
  the request frame or treating ambiguous attribution as complete review.
- Format, warnings-as-errors compilation, the 22-contract catalogue and Git
  whitespace checks passed. `mix.exs` and `mix.lock` remain unchanged.

```
mise exec -- elixir bin/check_routines_shadow.exs \
  --profile-authoring-operator-consumer \
  --core-archive /tmp/home-profile-wotex.tar \
  --core-sha 77c742b0b76c3d4d9d4c9d5e5b47e65755a351021de1ddba73369647b96fee61 \
  --runtime-archive /tmp/home-profile-wotex-runtime.tar \
  --runtime-sha 7c5412ea01dab311357a09276030ca005470c9bd8b0f471e0da3fb8ec5e4b1b4 \
  --profiles-archive /tmp/home-profile-wotex-profiles.tar \
  --profiles-sha 34a3dcef363a0b072fa2b260efeff8633f8365fd4aecfd1fbbc2c268c82e0b96
```

Consumer lock SHA:
`6ddb05e87f2872a12a244a022d666372d792510c8760188a3ac235ce53c258dd`.
Store fixture SHA:
`60b8be2c926132f7325b068b765cd2e0ca4eed1c0eb44c0a7e4e7d7748e31526`.
The archive harness freshly compiles its selected consumer and leaves the
application lock unchanged. The first chunk-replay assertion incorrectly pinned
decreasing remaining time; it now checks unchanged original metadata and a
nonincreasing duration. No timer renewal was added to satisfy the test.

This is bounded software evidence. It does not establish full valid-history
saturation, arbitrary process interleavings, native authoring presentation,
provider export/handoff, host meaning/source installation, installed signed
delivery or physical qualification. Imported/candidate/review records remain
inert, and the catalogue's broader partial/missing axes remain unchanged.
