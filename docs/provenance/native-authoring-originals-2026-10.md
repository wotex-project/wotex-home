# Native complete-original codec evidence

Recorded: 2026-10-14. Owner: [complete native originals](../specs/native-authoring-originals-v1.md).
Level: pure Swift/owning byte-vector software.

The owning contract preceded implementation in `5235390`. The Swift value keeps
the complete ordered original and its SHA and reconstructs a revalidated native
field map. Reflective output excludes original bytes, instructions and locators.
It performs no transport, publication, custody acquisition, approval or effect.

`mise exec -- mix woh.native.authoring.original.smoke` passed 181 cases using
Elixir 1.19.6 / OTP 28.5.0.6 and Apple Swift 6.4
(swiftlang-6.4.0.34.1, clang-2100.3.34.1), Swift 6 language mode and
arm64-apple-macos15.0 target. Existing independent ordered-array originals for
all three kinds match exact canonical bytes, SHA and decoded native fields.
The owning Elixir codecs also generate accepted boundary originals without
performing candidate assessment or review.

Cases include all import kind/size ceilings, all twelve limit ceilings and their
zero/boolean/one-over refusals, maximum S64/overflow and integral/fractional float
refusals, 32/33 handles, byte-sorted unique tuples, canonically equivalent but
byte-distinct Unicode locators, instruction and locator byte bounds, UTF-8,
slash/quote/tab/newline escaping, U+2028/U+2029, 256/257 evidence records, 64/65
unresolved paths, mode/envelope joins, invalid control/format characters and roots,
strict duplicate/unknown/missing fields, native JSON exact byte budgets and
over-budget canonical input. Canonical whitespace/extra-array members refuse;
native whitespace remains within its separate input bound.

The initial fixture accidentally used a 257-byte locator for an intended accepted
256-byte boundary; the existing owning codec refused it before Swift compilation.
The fixture was corrected to the actual ceiling. Failed preparation now occurs
before private-directory creation and task directories use a random identity,
avoiding collisions across separate BEAM invocations.

Full-app warnings-as-errors Swift type checking, locked warnings-as-errors
Elixir compilation, formatting, the 22-contract catalogue and Git whitespace
checks passed. Application dependency sources remain unchanged. No mutation,
pending-journal upgrade, installed signing/accessibility or physical result is
claimed by this pure codec evidence.
