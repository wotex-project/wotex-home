# Complete native external-profile original evidence

Recorded: 2026-10-15. Owner: [complete originals](../specs/native-external-profile-originals-v1.md)
NXO-01/02 and NXO-T1/T2/T3. Requirements preceded the runtime in 5b2066a and
953f69f. Independent corpus: d7e4252. Runtime:
4bbd358e5ea4eaaff79439d8e9fd60466f981bbd on local main.
No Store schema, original wire format, dependency or producer API changed.

## Implemented boundary

The native codec preserves the entire inspection/trust/target original with exact
operation/epoch/expected revisions, handles, references and action-specific nulls.
Canonical ordered arrays and SHA match the Elixir owners. Private construction and
revalidated fields prevent header/bytes substitution; reflection redacts inputs.
There is no credential, file, clock, network, source publication or Store operation.
Encoding establishes structure, not owned bytes, current permission or admission.

A bounded token/container preflight precedes complete Foundation tree allocation.
It enforces depth eight, 4096 nodes, 256 array members, 4096-byte strings, signed
integer token bounds, canonical object/boolean/float refusal and native object
key/duplicate limits. Every owning narrower field/count rule is then repeated.
Canonical decoding requires exact re-encoding; native-object JSON may vary key
order/whitespace while retaining one unambiguous decoded input.

## Independent cases and actual parity

Pinned Elixir 1.19.6/OTP 28.5.0.6 through `mise exec --`; Swift 6.4, Swift 6 mode,
warnings-as-errors and arm64 macOS 15 target on the development host.

- `python3 test/support/native_external_profile_originals_oracle.py --check` passed.
  It imports no Home, BEAM or Swift and allocates explicit array layouts over the
  already frozen inspection/trust/target inputs. There are 43 accepted structural
  inputs, 163 malformed native maps, 68 malformed wire inputs and seven malformed
  native JSON documents: 281 cases. Corpus SHA256:
  `834d261984788d49161cd970b5ea9f04d6af6230a0377bb211b7a57522dde769`.
- `mix woh.native.external.originals.smoke` passed every frozen case in Swift,
  including exact bytes/SHA, decode/fields/native-JSON correspondence, redaction,
  empty/32 definitions, signed maximum, aliases/order, action nullability,
  duplicate decoded names, UTF-8 and resource refusals. Actual Elixir owners agree
  with every accepted input/byte sequence and reject every malformed native map
  and wire input. Native JSON duplicate checks are the separate native boundary.
- The same command passed 579 deterministic URI comparisons classified by the
  actual pinned Elixir inspection codec, without using Swift to allocate expected
  bytes. They cover authority/userinfo, host/IPv6, port text, opaque paths, query,
  fragment and illegal characters. This additional owner-parity oracle supplements
  the frozen independent Python expectations.
- `mix test test/macos_app_inventory_test.exs test/wotex_home/external_inspection_test.exs test/wotex_home/external_trust_test.exs test/wotex_home/external_target_test.exs`
  passed 16 tests. The app's explicit source inventory includes the new codec;
  existing owning originals/receipts and malformed input rules remain unchanged.
- Focused formatting, compilation with warnings-as-errors, specification catalogue,
  HTML ExDoc with warnings-as-errors and Git whitespace checks passed. No full suite,
  Dialyzer, installed app build or hardware check was run.

URI behavior was researched against the pinned OTP uri_string source and actual
URI.new calls. Foundation URL parsing is more permissive for several Home-rejected
characters and repairs some strings, so this codec does not normalize through it.
It preserves the pinned five-digit port-text bound, opaque percent text and current
hexadecimal/dot suffix behavior after a valid IPv6 literal. This predicate never
supplies a transport endpoint. A review found that the C IPv6 parser accepts a
NUL-terminated prefix; a direct bounded C probe confirmed that behavior. The codec
now refuses all controls/space/DEL before that call. Independent cases cover all
34 such bytes inside an IPv6 literal plus escaped NUL in native JSON.

The accepted structural alias/empty-closure examples are not claims that Store
would admit their object kinds or semantic closure. Actual kind, ownership, reader,
capture, current source, grants, maintenance and revision checks stay with their
Authority/Store owners. The codec neither rewrites nor supplies those facts.

Logs: `/tmp/home-native-external-originals-{codec,tests,docs}.log`.
Unchanged mix.lock SHA256:
`3372ef86b264343efeedea270b3a8d0548650898043aa0e360daba46c7aaf184`.
Only public synthetic fixture metadata is used; no credential or private hardware
identity is passed in arguments, logs or tracked files.

## Remaining delivery

These values are ready for the separate complete pending custody/recovery and
fixed mutation consumer. Confirmation must still obtain fresh actual authorization,
publish exact input before send, verify actual typed receipts and retain uncertainty.
Native v2 selected driver/panels, installed signing/Keychain/UI delivery, protocol
publishers, source truth, power-loss and physical qualification remain separate.
No physical dispatch is enabled.
