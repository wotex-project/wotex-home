# HTTP header dependency remediation v1

Version: 0.1.0. Updated: 2026-10-15. Status: accepted target.
Owner: WOH.16 release dependencies and dependency audit.
Implementation: implemented bounded source selection and public API regressions.
Evidence: [executed software and audit record](../provenance/http-header-dependency-2026-10.md).

## Scope and source evidence

Home indirectly includes Cowlib and Gun through the pinned EMQTT client. The
[CNA advisory](https://cna.erlef.org/cves/CVE-2026-43966.html), updated October 14,
identifies CVE-2026-43966: Cowlib structured-field string serialization accepts
non-printable bytes, including CR/LF. At this inspection, Hex's latest Cowlib
is 2.21.0 and has no released fix. Its named upstream fix is
[4401b858f2229abb3ea115c60924f6c77e5f8aa3](https://github.com/ninenines/cowlib/commit/4401b858f2229abb3ea115c60924f6c77e5f8aa3).
The same CNA explicitly identifies Gun 2.4.0 onward's default rejection of
invalid outgoing request headers as a client-side mitigation. The registry's
Gun finding still covers the selected latest 2.7.0 release.

This contract updates the selected library source and records one bounded
advisory acknowledgement. It adds no HTTP endpoint, network service, custom
protocol implementation, caller trust option, device authority or dispatch.

## Requirements

**HDR-01 — Exact patched closure.** Root and firmware locks select Cowlib from
its canonical GitHub repository at the full fix revision above, with a direct
override of EMQTT/Gun's transitive requirement. Retain Gun's exact locked Hex
2.7.0 and EMQTT 1.16.1, including disabled QUIC. No fork, vendored patch or
unbounded branch replaces the upstream implementation. Inspect all intervening
changes from 2.21.0: six commits update erlang.mk, content-length 0 on HTTP 204,
percent-encoded Host values, the content-range property generator and RFC 9651
structured fields/canonical serialization. Keep Home's existing API usage.

**HDR-02 — String serialization.** The actually compiled Cowlib public
`cow_http_struct_hd:item/1` must reject a structured string containing any byte
0–31 or 127–255, including each byte embedded between printable prefixes and
suffixes. Only ASCII bytes 32–126 are accepted; quotes and backslashes retain
proper escaping. Refusal must occur before returning serializable header data.
The test must fail against the unpatched 2.21.0 encoder. Pure tests send no packet.

**HDR-03 — Client mitigation and audit.** Actual Gun public `headers/5` and
`request/6`, with their default empty request options, must synchronously reject
CR, LF and NUL in either a header name or value before casting a request to the
supplied local process. Never select `invalid_request_headers: ignore` in Home.
A printable header must still produce exactly one expected request cast.
Root and firmware Hex configuration may acknowledge only
`GHSA-w4f7-4cxr-rv3c`, with an explicit comment linking this contract. The
acknowledgement is justified only together with the exact HDR-01 patched closure
and these executable cases. Other advisories and retirements remain errors.
Do not label the registry finding repaired or a blanket ignored audit green.

**HDR-04 — Delivery and history.** Retain actual Cowlib/Gun license bytes through
the existing MQTT release legal step; the upstream source still declares version
2.21.0. Check both root and firmware locked resolution, exact source parity,
focused public serialization/client fixtures, release legal fixtures and the
ordinary advisory audit. Record acknowledged findings explicitly, alongside
other findings. No release/image/installed or physical evidence follows from
those software cases. A later published fix requires a fresh dependency review
and removal/review of this acknowledgement rather than carrying it forward by
habit. Historical dated no-advisory records remain historical observations.

## Acceptance

| Case | Requirements | Expected observation and falsifier | Level |
| --- | --- | --- | --- |
| HDR-T1 | 01–02 | Exact paired locks; all 161 disallowed byte values refuse in string positions; printable/escape vectors round trip. The released old encoder counterexample is accepted by the old implementation and rejected by the selected one. | Software |
| HDR-T2 | 03 | Default public Gun calls reject each CR/LF/NUL name/value case with no cast; printable calls cast once. Changed ignore configuration or an unreviewed source/version fails the fixed cohort check. | Software |
| HDR-T3 | 01, 03–04 | Both locked resolutions succeed; audit lists only the named acknowledgement and no other advisory/retirement; exact release legal byte fixtures pass. Missing/changed license inputs fail. | Software/package fixture |

The dependency provenance owns actual commands, toolchains, selected source and
lock hashes, results and cleanup. No full suite, image or network test is needed
for this pure bounded dependency remediation; delivery milestones retain their
separate obligations.
