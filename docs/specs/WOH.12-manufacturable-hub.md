# WOH.12 Manufacturable Home Hub

## Status

Accepted future product contract.

The first manufactured product is a silent local Home Hub, not a voice speaker.

## Required product properties

- Elixir/OTP + Nerves runtime;
- Ethernet and WLAN;
- BLE where qualified;
- dedicated Zigbee/802.15.4 coordinator radio;
- separate Thread RCP when Thread/Matter-over-Thread is included;
- secure credential/storage capability;
- local durable storage;
- explicit hardware/radio/firmware identity;
- no WAN dependency for normal home operation.

A later Voice composition may add microphone array, DSP/ASR, speaker/amplifier and a physically meaningful microphone mute/privacy indicator. It is a separate qualification cohort.

## Conjunct

Conjunct owns manufacturer-facing physical truth: RequirementSet, PartRevisions, Composition, interfaces, geometry, compatibility, procedures, evidence and composition digest.

The product definition MUST prohibit silent radio substitutions. A chipset/firmware change creates a successor composition requiring affected qualification.

## Conjunct Connect

Connect may carry the qualified pack into supplier/manufacturer/fabricator/assembler/packer inquiry, RFQ, quotation, commitment and delivery-evidence workflows. Connect is never required to run Home.

Each shipped hub should be able to report product revision, composition digest, radio identity/firmware, Nerves image, Home release, profile catalogue revision, Maude model digest and ML model digest.
