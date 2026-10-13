# Retained timezone routine archive evidence

Executed 2026-10-13 against Home source/harness `3597ac6`, WoTEx runtime
`f0e68746` and ExBooking `fb9082f`. This is the
[immutable provider join](../specs/routine-timezone-provider-v1.md), without
runtime dependency selection, clock confidence or scheduler activation.

The standalone `bin/check_routines_shadow.exs --temporal-consumer` takes the
four exact archive/SHA pairs. Every digest is checked before executing archive
code; bounded inflation and safe-relative member checks apply independently.
The consumer selects extracted paths with env=prod and WOTEX_PATH_DEPS unset,
freshly compiles eight actual Home source files, and starts no Home application,
Store or transport. No current checkout or cached Home BEAM is its producer.

Five archive cases pass with warnings-as-errors. All 230 retained Python/libc
local-label vectors also agree with the separately implemented CalendarReference
through the public ExBooking provider API. Four named gap/fold calendar series
preserve COUNT, nominal/UTC starts and ordinals across page sizes; explicit
second-fold DTSTART stays second. Home occurrence arrays/IDs/causal IDs retain
their original canonical encoding, independently checked from the ordered array.
Changed context/clock rejects old cursors; changed source bytes/name and malformed
native zones refuse; fractional query endpoints preserve the exact instant.

| Input | SHA-256 |
| --- | --- |
| wotex archive | `77c742b0b76c3d4d9d4c9d5e5b47e65755a351021de1ddba73369647b96fee61` |
| wotex_continuum archive | `db7077c5f0ad92426c94a077a4f58f9b7334df25de8c2a1b8ed25143bab6efb5` |
| wotex_routines archive | `9efd2ccb4963c28719506a965838c138e9a109105ba94e0861275d05b6eb4e58` |
| ex_booking archive | `420dc97c440256276b0f37e75d44430750b23e063ace7d3a7f5ae63363c3d319` |
| lib/wotex_home/id.ex source | `1dba3abf794eb238b12b6427c7bbf122d023b7bb19f8ad013476cce6fdea307c` |
| lib/wotex_home/profiles/codec.ex source | `8bebfa34d5501479a33b6210b81a99da5efd245c117be7d370cc7feb57b58e92` |
| lib/wotex_home/schedules/codec.ex source | `164bca012f690fb3ffea40d1d62cd446d3b0bd11569c47af58ff80f41583246d` |
| lib/wotex_home/schedules/tzif_footer.ex source | `55ae23f7adcca33b3a31e6777840e0a8b9ebbe800b67f59e2767bad39c1208ad` |
| lib/wotex_home/schedules/tzif.ex source | `5db5cbfa6c129f65c711da2001044a6385b51505bcc7e436188d7d44594b8550` |
| lib/wotex_home/schedules/calendar_reference.ex source | `0e0b8e16121bec9c5e5d861f3a935c7923b9d695476398917f4d0faadde332ac` |
| lib/wotex_home/schedules/occurrence.ex source | `1f959053a2e14dd0e0572d059b72443b56aa7706366d4367f6dbc5f851a4b683` |
| lib/wotex_home/schedules/routine_timezone.ex source | `9bdbf4352f0c51883620194dda67fe89695a55519989a8ef8075f4d4c1a6c107` |
| test/support/routines_timezone_consumer.exs source | `703df6e3bc50aded0154b015e652e39834164656596b35190e8c2646145c80a1` |
| test/fixtures/schedules/timezone_vectors.json source | `4ab8a77636c79a33fb212c95f7b437786694fe5274584f11af2630ad947d5320` |
| consumer lock | `79bb3746c94f2f858f6586eacccfe22eb7ebd51f6d574320b6ec25956a2b439b` |
| bin/check_routines_shadow.exs | `88f160749a2bf456046cf9160581fc9c769a2e8005de915423c13ea6130f12a2` |

Toolchain: Elixir 1.19.6, OTP 28.5.0.6, ERTS 16.4.0.6. Consumer Hex closure is
Decimal 3.2.0, ExJsonSchema 0.11.5, Jason 1.4.5, NimbleOptions 1.1.1 and Tz 0.28.4;
no updater/watcher starts. Its selected Home fixture bytes are synthetic, not a
qualified IANA release or hardware identity. ExBooking's development archive
still carries version 0.2.3 but differs from published 0.2.3, which lacks this
API. All archives are inspected development cohorts, not publication evidence.

The focused Home timezone/provider/reference suites pass 19 tests. Their negative
cases include truncated/over-bound/foreign contexts, native/byte tampering,
unsupported precision/year, offsets wider than the producer contract and a
synthetic three-instant fold. Compile warnings, format, specification catalogue
and Git whitespace checks pass. After extending the same archive harness, the
original restricted Boolean consumer still passes all four tests/360 finite
cases against its historical `5bf61912` routines archive; its lock remains
`b59d95b8595581bf44948381924f6396062db43e0768bb5b1de9ccd50055287f`.

These checks establish the declared pure provider and extracted calendar seam.
They do not establish full legacy scheduler extraction, runtime dependency
adoption, actual Store/current-grant races, installed time/sleep bounds, physical
dispatch or device qualification. Those gates remain separate and open.
