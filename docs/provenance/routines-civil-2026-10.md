# Immutable civil calendar candidate evidence

Updated: 2026-10-15. This records RCC-01–05's bounded pure/archive candidate.
Home runtime dependency selection, v4 correspondence and current Store races
under [RTR](../specs/routine-temporal-runtime-v1.md) remain open. No clock,
installed host or physical qualification is supplied by these checks.

## Exact cohort

Home runtime candidate, harness and fixtures: local commit `167954f`.
The provider was introduced at `d1ce451`; the contracts preceded code at
`cb60edd` and `79cd42d`. WoTEx source is local commit `eb1380ae`, whose civil
runtime code is `f3e77a43`. ExBooking archive source is `3fa614c`; its shipped
inputs are unchanged from the complete-civil implementation at `16a9d0d`.
The producer's added independent tests do not enter the archive. No neighboring
producer path or cached Home BEAM enters either isolated consumer.

All Home/consumer execution uses pinned Elixir 1.19.6/OTP 28.5.0.6. Source
archives were built under each producer's pinned toolchain: WoTEx Elixir
1.20.2/OTP 29.0.4 and ExBooking Elixir 1.20.4/OTP 29.0.4. The fresh civil
consumer resolves Decimal 3.2.0, ExJsonSchema 0.11.5, Jason 1.4.5,
NimbleOptions 1.1.1 and Tz 0.28.4. These producer archives retain their current
unreleased development additions and version labels; this does not select a
published successor or change Home's mix.exs/mix.lock.

| Artifact | SHA-256 |
| --- | --- |
| Core archive | `77c742b0b76c3d4d9d4c9d5e5b47e65755a351021de1ddba73369647b96fee61` |
| Continuum archive | `db7077c5f0ad92426c94a077a4f58f9b7334df25de8c2a1b8ed25143bab6efb5` |
| Routines archive | `f37bce173a6e738a1c14f2768a958054093575bd4629eed9d2be7bb773fad5d2` |
| ExBooking archive | `5e1b12fbe5fa9e72f02ff7e79674dd35e415fb4aea87222f7ea01cfa50ae1fb2` |
| Civil consumer lock | `79bb3746c94f2f858f6586eacccfe22eb7ebd51f6d574320b6ec25956a2b439b` |
| Restricted consumer lock | `b59d95b8595581bf44948381924f6396062db43e0768bb5b1de9ccd50055287f` |

The freshly copied civil closure has these exact source bytes:

| Home source / fixture | SHA-256 |
| --- | --- |
| lib/wotex_home/id.ex | `1dba3abf794eb238b12b6427c7bbf122d023b7bb19f8ad013476cce6fdea307c` |
| profiles/codec.ex | `d55846e7d56576f2e6815ffb96499e68d79013af513cb94f494b3b8ddae0e9d7` |
| schedules/codec.ex | `eb1c889b58950e16775bb385afb2d78baa15907da0c6fabc7e4fbf053b40b7cd` |
| schedules/tzif_footer.ex | `bfe3c438d8735c55ead1a2ce878dbbee8dfbb7be8128cb3046d89b5e580c1531` |
| schedules/tzif.ex | `08f214dfd68377c497885ac1ab434920c5efef26682aa7e5be11fda4920ffd12` |
| schedules/calendar_reference.ex | `0ced735fce028e9dc9a52134af6f50be0cb5264ead13bf764c69ea962a84b846` |
| schedules/occurrence.ex | `6320db174ca253397e23fcd9a622f4443617eee3aefd0e77160e3f7861e4d42c` |
| schedules/routine_timezone.ex | `2c3025b267dcda6203fcc2d65e80d748451221b033a8296df5043ed42d26a89b` |
| schedules/recurrence.ex | `cd8fa7d271949dd1dbf2c037d38d2d98becca1897dac593d3013b03da45ed117` |
| schedules/civil_timezone.ex | `cbd8161d6c693f4c43accc3e40bca29d19ce5f4f8e67d0d0df7e18c6a38d0841` |
| schedules/routine_calendar.ex | `20824972bddf0943c1f384904bc61eb7385e3d7392b8591854aeacd6189075cd` |
| test/support/routines_civil_consumer.exs | `9a50db1a8a3ff65dc94eb24e4b2314657d11390eec9df68146d3176644e04d4b` |
| test/support/routines_timezone_consumer.exs | `703df6e3bc50aded0154b015e652e39834164656596b35190e8c2646145c80a1` |
| test/fixtures/schedules/timezone_vectors.json | `4ab8a77636c79a33fb212c95f7b437786694fe5274584f11af2630ad947d5320` |
| bin/check_routines_shadow.exs | `01f0eae1c9c1edb812b283a5237ffb314311222f8b7eda98ac0de639c912556b` |

Unprefixed module paths in this table are under lib/wotex_home. The harness
retains its 32-MiB archive, 16-MiB inflation, 2048-member regular-file/directory
limits, exact SHA checks, no-link/traversal rules and extracted env=prod paths.

## Executed checks

The final focused command passed 27 tests (seed 562491), with no socket-free
exclusion:

```sh
mix test test/wotex_home/routine_calendar_test.exs \
  test/wotex_home/civil_timezone_test.exs \
  test/wotex_home/routine_timezone_test.exs \
  test/wotex_home/schedule_timezone_test.exs \
  test/wotex_home/schedule_recurrence_test.exs --warnings-as-errors
```

The exact four-archive lane uses each archive path and its tabled lowercase
digest exactly once:

```sh
elixir bin/check_routines_shadow.exs --civil-consumer \
  --core-archive /absolute/core.tar --core-sha SHA256 \
  --continuum-archive /absolute/continuum.tar --continuum-sha SHA256 \
  --routines-archive /absolute/routines.tar --routines-sha SHA256 \
  --ex-booking-archive /absolute/ex_booking.tar --ex-booking-sha SHA256
```

It passed 14 tests (seed 384264): seven actual civil/independent-reference
cases, two isolated output-boundary/control-flow cases and all five unchanged
SP.08 provider cases. A separate no-start process successfully resolved a civil
label with Home, Routines, ExBooking and Tz unstarted before and afterward.
Incomplete, mixed and duplicate civil-mode argument lists separately refused
before archive execution.

| Case | Observed evidence |
| --- | --- |
| RCC-T1 | All 230 frozen labels pass through actual public civil construction/query and the independently parsed raw-phase reference; direct callback tests retain precise microseconds, name/designation and native/context refusals |
| RCC-T2 | Literal threefold and 256 simultaneous alternatives remain complete; direct 258-offset input and both extreme offsets pass; exact UTC zero/final headroom and genuine gap/undefined-data distinctions remain |
| RCC-T3 | All 112 retained recurrence vectors agree across the current Recurrence, new candidate and independent raw-TZif/Gregorian reference; literal Home occurrence/root documents and IDs retain their original encoding |
| RCC-T4 | Current missing capability refuses; synthetic native page/point/time/request/ordinal/precision/digest faults refuse; exact work/unavailable/refusal/fault outcomes have no partial coordinates, private payload or fallback |
| RCC-T5 | One-shot second/third positions remain selectable; passed recurring first fold cannot substitute another; exact end and 32 successive gaps terminate correctly; final-year exhaustion preserves headroom |

The local-date-order case is deliberately distinct from globally sorting a
multi-date query. At 08:30 UTC its synthetic zone jumps from offset 0 to +86400,
then at 09:30 to -25200. After an 08:00 cursor, today's 09:00 label resolves at
16:00 UTC, while tomorrow's first 09:00 label resolves at 09:00 UTC today.
Both current and candidate Home searches, plus the independent reference,
choose today's 16:00 original. A globally earliest multi-date query would choose
the other point. This is a supported synthetic calendar case, not IANA evidence.

Adversarial output checks exposed an extra retained Time member accepted by a
map subset pattern. Exact equality now refuses it. Native-date tests additionally
check calendar fields explicitly because reconstructing from an already native
Date can retain invalid fields. The final checks above include both corrections.
The real producer cases and synthetic control-flow cases remain distinct.

The original restricted mode, omitting --civil-consumer and the ExBooking pair,
passed four tests including all 360 finite Boolean scenarios (seed 421795).
Its closure initially failed warnings-as-errors because current profile codecs
now reference ProducerIdentity. Copying actual producer_identity.ex and
runtime_artifacts.ex fixed that missing-source closure; no stub, weakened
compiler check or comparison-policy change was introduced. These two sources
hash to `bedce3d76ce4065adadc78a1c178bf6666a098457f71199db8bdce623382cdf9`
and `ac4d68d3f38e2fa5013e748e7fc28b6e283aadc010416b2035bd94f41546e5c7`.

Scoped formatting, warnings-as-errors Home compilation, all 22 working catalogue
contracts and Git whitespace checks passed. Full Home application/Dialyzer,
durable v4 admission/queue/claim/handoff, release/native, installed-clock and
physical campaigns were not run for this pure candidate. Existing runtime pins
and the authoritative Recurrence implementation remain unchanged.

## Cleanup

Each success and failed archive attempt removed its inner consumer/extraction
directory in after; the outer producer-archive root was removed in finally.
Both documentation agents' private patches were applied and their directories
removed. No Docker resource, release or native artifact was created. Small
existing locked build caches remain reusable; no shared cache/volume was pruned.
