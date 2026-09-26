# Universal Light lab

Prove that applications consume one semantic Light contract across independent physical architectures.

Initial comparison:
- old LIFX: direct Wi-Fi/UDP;
- Hue: Zigbee bulb through local Hue Bridge/HTTP.

For overlapping capabilities:
- same Property/Action/Event names and schemas;
- same normalized brightness semantics;
- same colour/temperature semantics;
- same desired/accepted/observed distinction;
- no application branch on vendor;
- protocol-specific failures remain typed transport/profile evidence rather than semantic corruption.

A later Matter Light may join the same comparison.
