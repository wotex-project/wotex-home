# WOH.12 — Manufacturable local controller

Version: 0.2.0. Status: future product contract; not a released hardware design.

## Product profiles

**H12-01.** Qualify a silent controller first. Derive compute, RAM, storage, power and thermal requirements from measured device counts, native protocol workers and the selected inference/verification profile. Do not freeze Wi-Fi 6/6E, a Pi model or a shared Zigbee/Thread radio merely to make a feature list impressive.

The baseline includes Ethernet/WLAN, a qualified Zigbee NCP, durable storage, protected credential custody, a documented recovery interface and Elixir/OTP through Nerves. BLE and a separate Thread radio are included only for selected profiles. A USB-powered external supply reduces initial mains design scope but does not certify the finished product automatically.

## Physical and software identity

**H12-02.** A product pack records requirement revisions, parts/interfaces, PCB/carrier, antenna placement/keepouts, enclosure, thermal/power margins, radio firmware, boot chain, assembly/service procedures and test evidence. Record source rights and firmware redistribution obligations separately from open host software. Pin exact substitutes; a reused supplier SKU cannot conceal a radio/flash change.

Conjunct evaluates declared physical facts and composition constraints. Missing facts remain unknown. It does not certify runtime safety, RF behavior or legal compliance from a schema-valid pack. Connect can handle independent manufacturer/fabricator/assembler/packer inquiry, quotation and delivery evidence; it is never needed to operate the installed controller.

## Production acceptance

**H12-03.** Define factory tests for image authenticity, per-unit identity, radio enumeration, storage, network isolation, recovery and functional ports. Generate per-device secrets during controlled provisioning; do not bake shared production keys into an image or manufacturing pack. Rework, replacement and ownership transfer have explicit erase/re-enrollment procedures.

Each shipped unit identifies composition, firmware, boot, profile catalogue and model revisions without publishing private keys. Software, coordinator firmware and enclosure/antenna substitutions trigger the appropriate new cohort. Required electrical, radio, cybersecurity and product conformity work must be assessed for the actual market/product before manufacture; a component approval is not blanket finished-product approval.

## Optional voice revision

**H12-04.** A microphone/speaker product is a separate composition with acoustic qualification, echo cancellation, local wake word/ASR and explicit latency/power budgets. DistilBERT classifies text, not audio. A physical mute must interrupt microphone capture in hardware and have a truthful indicator; a software flag is insufficient for that claim. No mandatory voice cloud is introduced.

## Acceptance

H12-T1: a manufacturer can understand an exported permitted product pack without Connect. H12-T2: missing physical facts block automatic acceptance. H12-T3: a changed radio/firmware cannot reuse old qualification silently. H12-T4: factory provisioning yields distinct recoverable identities without shared secrets. H12-T5: the declared offline/runtime profile passes the same Home acceptance suite on the produced unit.
