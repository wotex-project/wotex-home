# Manual authoring mechanics software evidence

Home commit `73ebf84` adds pure AuthoringContract and AuthoringAssessment
components that call public
WoTEx WPF.03 export/finalize/validate/projection APIs. They bind exact selected
core/Runtime/Profiles archive assertions and explicit Home limits without
granting admission, source truth or fixture qualification. The owning accepted
contract is profile-authoring-v1.md version 0.1.4.

On 2026-10-14, pinned Elixir 1.19.6 / OTP 28.5.0.6 ran the fresh archive consumer
through `bin/check_routines_shadow.exs --profile-consumer`, selecting:

| Archive | SHA-256 |
| --- | --- |
| Core | 77c742b0b76c3d4d9d4c9d5e5b47e65755a351021de1ddba73369647b96fee61 |
| Runtime | 7c5412ea01dab311357a09276030ca005470c9bd8b0f471e0da3fb8ec5e4b1b4 |
| Profiles | 34a3dcef363a0b072fa2b260efeff8633f8365fd4aecfd1fbbc2c268c82e0b96 |

All 12 cases passed: seven existing envelope cases and five authoring cases.
The consumer compiled six selected Home files with warnings treated as errors,
without Home application startup or a routines package. Its independent lock
SHA-256 was 6ddb05e87f2872a12a244a022d666372d792510c8760188a3ac235ce53c258dd.
Python-generated vectors for temperature and a research quantity match original
draft, finalized bundle, exported producer contract and Home basis identities.
The Python oracle uses sorted-key compact UTF-8 JSON and the exact domain strings
in the owning contract; it reads schema/rule literals from the selected Profiles
archive and the independently authored Home quantity fixtures, not Elixir output.

Cases exercise absent/matched/mismatching capture, syntax/duplicate-field and
unsupported-selector failures, explicit limits, improper registrations, safe
diagnostics, forged native values and changed archive/Home reference/limit bases.
The first archive run found one incorrect mapping of the public core's string
limit error; after correction the fresh consumer passed all cases. A separate
locked Home test passed the typed producer-unavailable case. Format, warnings-
as-errors compilation, 22-contract catalogue and Git whitespace checks passed.

These results establish generic mechanics only. Reports explicitly leave source
review and Home consumption unassessed, with independent fixtures unsupplied.
Application dependency adoption, actor-owned candidate journals, fixture/source
review, provider policy/handoff and physical qualification remain separate work.
