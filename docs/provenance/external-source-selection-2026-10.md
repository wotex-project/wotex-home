# Explicit source selection software evidence

The [source selection contract](../specs/external-source-selection-v1.md) was
committed in bd195fc, independent complete-input/policy/stable-ID identities in
740b356, and implementation in e885a8e. It supplies the host-side input needed
between raw catalogue trust and target-specific read declarations. It creates
no source process, lease, Store row, grant, report or physical qualification.

On 2026-10-14, Elixir 1.19.6 / OTP 28.5.0.6 executed:

- The exact three-archive `--profile-consumer` command recorded in
  [trust evidence](external-trust-2026-10.md) passed 47 cases in 8.6 seconds,
  freshly compiling 29 selected Home modules with warnings as errors. Archive
  and consumer-lock identities are unchanged.
- `mise exec -- mix test` selecting external_value_unavailable_test and
  generic_read_semantics_test passed nine cases. These selected cases exercise
  actual Store metadata/restart and producer absence, not sockets.
- Format, warnings-as-errors compilation, the working 22-contract catalogue
  and Git whitespace checks passed. No schema/dependency change, whole-app/
  native suite, Dialyzer, packaging or physical qualification was run.

| Source | SHA-256 |
| --- | --- |
| ExternalSourceSelection | 528e6deab22dfb149a9d72118a98a6a796f910e7fb6e3257405dbf485888cd1d |
| Independent source vectors | 82798f1a709603b2cf98c78e83dcaafe23711e5e0d7a00c61e9ca499e57dc52f |
| Archive reader/source cases | af4e22ec575b52e7d2154931749babc45bea089607e98ec3be2f7695bb511943 |

Four new archive cases extend the prior 43. Both independent quantities and a
multi-channel consumer policy reproduce complete frozen input-derived identities
and the payload-free summary. Changed stable identity, source epoch/generation,
method/trust, accepted consumer range, policy freshness and a genuinely checked
recapture all change the complete basis. Extra/native forged fields cannot
survive reconstruction. Invalid source metadata, channel/key duplicates/order,
policy bounds, an uninstalled consumer reference and whole-input resource excess
refuse. Cold optional-producer absence cannot use a local substitute.

One mutation fixture changed a unit numerator without preserving the producer's
canonical reduced rational. Its expected success correctly failed. The corrected
valid mutation narrows the accepted range and retains the shared unit guard;
the final archive run passed. Stable IDs and captures are synthetic fixtures,
not private hardware evidence. The emitted summary contains neither raw stable
identity nor capture, selector, consumer/unit bodies or credentials.

Source assertions remain host input, not transport authentication or physical
truth. Bounded current source custody, original-scoped leases and durable target
selection/report admission are named unfinished owners. Current generic profile
use remains fail-closed. All commits remain local on main; producer pins are
unchanged and unrelated drafts are preserved.
