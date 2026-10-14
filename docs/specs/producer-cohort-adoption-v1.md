# Application adoption of owned profile and occurrence producers

Version: 0.1.0. Updated: 2026-10-14. Status: accepted successor target.
Owner: WOH.18 H18-T13/T14/T16/T17/T18; WOH.07 runtime correspondence;
WOH.16 release source inventory. Implementation: planned. Evidence: missing.

## Result and source entry

The ordinary locked Home application can load the actual generic WPF core/
Runtime/Profiles and ExBooking original-occurrence APIs already consumed by its
bounded archive tests. Source availability is separate from host installation,
current authorization, source authenticity, qualified clock and physical effect.
Installing a library creates no contract, source selection, active routine,
schedule, report, trust record or grant. Default dispatch and scheduler flags
remain false.

On 2026-10-14 primary Hex API reads show ExMaude 0.5.0 and ExBooking 0.2.3;
wotex, wotex_runtime, wotex_profiles and wotex_routines return 404. ExMaude already
uses the exact released 0.5.0 pin. ExBooking's new APIs are outside its released
0.2.3 artifact. GitHub API reads verify these exact hosted sources:

| Application | Repository and exact ref | Subdirectory |
| --- | --- | --- |
| wotex | wotex-project/wotex, ba8ea373244ce57987f47a731b8eca3ccae9b45f | packages/wotex |
| wotex_runtime | same exact WoTEx ref | packages/wotex-runtime |
| wotex_profiles | same exact WoTEx ref | packages/wotex-profiles |
| ex_booking | futhr/ex_booking, 25ad04548c01e5a24c5505acfbe063550d3efaa0 | repository root |

WoTEx is public at this read; no visibility change or push is required or
authorized. ExBooking's latest local maintenance commit preserves the generic
occurrence APIs at hosted 28dadca and refreshes CI action pins. A neighboring
checkout, version label or older archive SHA does not identify consumed code.
The existing separately pinned wotex_udp remains at its current source.
WoTEx Routines/Continuum adoption is a later explicitly allocated cohort.

## Requirements and compatibility

**PC-01 — Resolve exact owned sources.** Add the four production dependencies
above through the existing explicit Git/local-source selector. Ordinary and
release builds use the exact Git ref; WOTEX_HOME_GIT_DEPS=1 forces that source,
and WOTEX_HOME_PATH_DEPS=1 may choose explicit neighboring development paths only
when Git mode is absent. Declare the core/Runtime overrides required to satisfy
the producer packages' own currently unpublished Hex requirements. Do not enable
their development/test dependencies in Home. Record all source refs in
MixProject.source_pins and actual mix.lock Git tuples. No moving branch/tag,
fabricated Hex version, hidden path default or vendor copy is accepted.

Resolve only newly required transitive packages, retaining existing locked
versions when their constraints remain valid. Profiles requires Decimal ≥3.2;
select the current stable registry release within that constraint. Core requires
ex_json_schema ~>0.11. Review their primary release notes and actual dependency
graphs before consuming them. Do not run a global dependency upgrade or compile
the unrelated development inference stack for this adoption.

**PC-02 — Preserve source and runtime assertions.** Existing staged-pinned-source,
release require_git_sources and native/release inventory tools must cover every
new pin. The loaded public producer APIs must be available in a fresh ordinary
locked consumer process and match independently retained authoring/value/
occurrence vectors. Keep raw archive SHA assertions distinct: old explicit test
archives do not become identities for the Git dependency's runtime package. Host
reader/authoring configuration must supply its own truthful producer source/build
assertions through a separately specified installation boundary; adoption alone
does not manufacture them or make an old reader/current target available.

No schema, public API wrapper, current semantic profile, trust/selection scope or
physical qualification is broadened. Existing missing host installation still
returns authoring_unavailable/source unavailable; no local substitute appears.
Dependency absence or invalid producer output retains the existing typed refusal.
Current runtime artifact inventories must read actual new loaded application
bytes rather than reuse an inventory from before adoption.

## Acceptance

| Case | Requirement | Stimulus and falsifier | Level |
| --- | --- | --- | --- |
| PC-T1 | 01 | Locked Git consumer resolves all four exact refs, no neighboring/default Hex substitute; existing lock entries unchanged except justified new transitive closure. Wrong source/version or inherited dev package fails. | Dependency/software |
| PC-T2 | 02 | Fresh ordinary process calls public contract/finalizer/validator/value/occurrence APIs and compares independent vectors; missing/changed inputs refuse. Archive-only availability, private producer helper or local semantic branch fails. | Software |
| PC-T3 | 01/02 | Staged source/release pin validation and changed runtime inventory, focused existing import/candidate/review/temporal guards. Invented archive assertion, implicit installed source/clock/approval or enabled dispatch fails. | Source/runtime software |

Run locked formatting/compilation, contract metadata and focused affected tests.
Full release/native/board milestones retain their documented requirements; a
dependency compile does not replace installed or physical evidence. Keep every
commit local on main and preserve unrelated sibling documentation drafts.
