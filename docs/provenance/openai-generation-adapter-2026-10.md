# Remote generation adapter software evidence

Recorded: 2026-10-15. Contract:
[bounded remote generation adapter](../specs/openai-generation-adapter-v1.md).
Runtime: 9d469c0d854873900bc33c8c9eba66b5e00bdac7 on local main.
The contract and independent API vectors preceded code in dd89a83.

## Implemented boundary

OpenAIEndpoint reconstructs exact trusted literal routing and CA bytes, retaining
the fixed API hostname during verified TLS. OpenAIWire encodes one stateless
tool-free request and extracts a bounded unchanged draft string. OpenAIHTTPS
performs one finite POST and incrementally bounds status, headers, framing and
body before returning data. OpenAIAdapter owns sealed private key custody and
linked/monitored per-caller channels, with explicit concurrency/deadline limits
and no retry. GenerationRunner preserves the four closed provider failures so
lost transport knowledge becomes unknown rather than malformed draft success.

The strict API output wrapper constrains one draft string. It does not substitute
for the actual installed WPF grammar or source/fixture review. Store continues
to reserve handoff, check current authority, assess exact raw bytes and retain
inert results. Model input contains no Home credential or activation/tool port.

Frozen test/fixtures/profiles/openai-generation.json raw SHA-256:
f1026450d88297247a885ef3a53318442d116e0bff1db72371e3f3fdd2947c2c.
Independent Python allocated the canonical API request/response wrappers and raw
draft identities from the existing two independently authored quantity fixtures,
without Home or BEAM invocation. Actual codec and TLS requests match those bytes.
TLS uses platform-generated synthetic CA/API-hostname certificates and fixture
keys. No production key or real provider endpoint was contacted.

Checks used mise Elixir 1.19.6 / OTP 28.5.0.6 on macOS, Store schema 37.
Root mix.lock SHA-256 remains
3372ef86b264343efeedea270b3a8d0548650898043aa0e360daba46c7aaf184.
Consumed core/Runtime/Profiles remains
ba8ea373244ce57987f47a731b8eca3ccae9b45f. WoTEx HTTP binding source guidance
confirms that it owns TD mapping through a consumer-supplied network port and
prohibits a built-in client/provider. This non-TD vendor adapter belongs to Home;
no sibling API, dependency or schema changed.

## Executed checks and exact scope

The affected generation/certificate milestone passed **100 tests, zero failures,
81.6 seconds**:

```
mise exec -- mix test test/wotex_home/openai_adapter_test.exs \
  test/wotex_home/openai_wire_test.exs \
  test/wotex_home/generation_attempt_codec_test.exs \
  test/wotex_home/generation_attempt_test.exs \
  test/wotex_home/generation_operator_test.exs \
  test/wotex_home/generation_installation_test.exs \
  test/wotex_home/controller_tls_bootstrap_test.exs
```

After adding key/revocation cases and tightening final status-line/chunk-extension
validation, the final adapter/codec run passed **21 tests, zero failures,
8.3 seconds**:

```
mise exec -- mix test test/wotex_home/openai_adapter_test.exs \
  test/wotex_home/openai_wire_test.exs
```

The final new suites contain sixteen actual TLS/filesystem/Host/process cases
and five pure wire cases. The earlier 100-test result is not a claim of a final
102-test rerun. No socket-free exclusion was used. Formatting, warnings-as-errors
compilation, catalogue checking (22 workspace contracts matched), full HTML
ExDoc with warnings-as-errors and Git whitespace checks passed. No native app,
firmware, release or signed installation artifact was rebuilt.

Raw synthetic logs: /tmp/home-openai-adapter-final.log,
/tmp/home-openai-adapter-credential-final.log and /tmp/home-openai-adapter-docs.log.
Initial failures exposed the actual tuple return of beam_lib.md5 and OTP's
oversized invalid_packet result, plus a malformed fixture list and wrong expected
revocation error. Those were corrected; the final focused cases exercise the
closed results without exposing raw TLS/service exceptions.

## Acceptance correspondence

OA-T1 matches both independently frozen API requests, original private projection
and unchanged drafts. A separate raw-number spelling/negative-zero/exponent case
and inclusive 262144-byte draft preserve bytes. Actual configured Host retains
both inert candidates with source_review not_assessed and fixture_status
not_supplied. Remote consent refusal occurs before export; original retry sends
no second POST. The observed request contains the synthetic model key only in
Authorization, with no Home bearer in the body.

OA-T2 checks malformed/noncanonical/oversized document/model/token inputs,
wrong model/object/status/output/phase, duplicate/unknown draft wrapper members,
annotations/tools, refusal/incomplete/failed outcomes, endpoint/DER/native identity
and startup option bounds. Actual private key cases cover unsafe mode, malformed
length/encoding/newlines, same-file replacement, hardlink, symlink and parent
mode. Credential changes refuse before a new connection. Diagnostic status omits
the key, private path and input document.

OA-T3 exercises actual verified TLS and split Content-Length/chunked/close-delimited
responses. Wrong chain/name/purpose, expired/future/critical/corrupt certificates
receive no application key. Redirect/error status closes without following or
reading its announced huge body. Duplicate/ambiguous framing, compression,
oversized header/announced chunk/Content-Length, malformed CRLF/control extension,
bad trailer and truncation have closed failures. Exactly 4194304-byte bodies pass
in all three framings; a streamed extra byte and 4097 chunks refuse, while 4096
chunks pass. TLS policy/header/body bounds remain distinct from API JSON limits.

OA-T4 fills the explicit one-call adapter limit, then proves caller loss and
deadline close the owned socket. Adapter and worker death retire their channels;
the adapter child is temporary. Forged/duplicate/late result PID/token pairs do
not replace the actual response. Lost actual model replies reach Store as unknown,
never an automatic retry or a candidate.

OA-T5 uses actual named Host, SQLite, private custody and the real adapter against
the controlled TLS peer. Cancellation closes remote work; Store restart resolves
its original as unknown with no resumed POST. Credential revocation before a
valid TLS response leaves only withdrawn/actor metadata and zero draft/bundle
objects; authenticated status refuses unauthorized. Physical dispatch stays
disabled. The shared synthetic certificate helper now accepts an explicit hostname;
its original default controller cohort passed the affected milestone unchanged.

## Source decisions and remaining delivery

Official [Responses documentation](https://developers.openai.com/api/reference/python/resources/responses/methods/create)
and [structured outputs](https://developers.openai.com/api/docs/guides/structured-outputs?api-mode=responses)
support the API/wrapper, with [phase guidance](https://developers.openai.com/api/docs/guides/deployment-checklist)
for final_answer. [Data controls](https://developers.openai.com/api/docs/guides/your-data)
distinguish store false from provider retention. [OTP TLS](https://www.erlang.org/docs/28/apps/ssl/ssl.html)
and [RFC 9112](https://www.rfc-editor.org/rfc/rfc9112.html) support the reviewed
transport; ambiguous HTTP refusal is an explicit stricter consumer policy.

Actual account access, model completion/quality, native signed provider composition,
local-model OS confinement, native generation/pending UI, paired delivery,
aggregate attempt-pool boundaries, hosted full-suite, storage power-loss and
physical qualification remain separate obligations. Trusted literal routing/CA
selection identifies a chosen peer; this corpus does not establish a live service.
All commits are local on main; nothing was pushed or published. Unrelated drafts
and local client settings were preserved.
