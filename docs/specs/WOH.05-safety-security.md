# WOH.05 Safety, security and privacy

## Status

Accepted target contract.

Autonomous safety devices remain autonomous. Home MUST NOT become the sole smoke/fire detection or acoustic alarm path. A smoke report is physical evidence; DistilBERT, Refpath or another AI cannot downgrade it or automatically silence it.

Actions are at least ordinary, sensitive and safety_privileged. Smoke silence/manual alarm, safety-invariant changes and destructive reset are safety_privileged, require explicit authorization/freshness/audit, and remain disabled until exact hardware semantics are physically qualified.

Zigbee joining windows are explicit/time-bounded; network keys are secret; IEEE addresses remain private evidence; address changes do not create Things; replay/counter semantics are honored; coordinator backup/restore is explicit.

Legacy LAN protocols may lack strong authentication. Locality is not identity. Management APIs have independent authentication and should support isolated device networks.

TDs/logs/public fixtures never contain Zigbee keys, Hue credentials, Wi-Fi credentials, Matter fabric secrets or account tokens.

macOS uses Keychain where applicable. Nerves uses a qualified protected persistent store/hardware-backed option where available.

Telemetry remains local by default. Natural-language command text is not durably retained by default.

Remote access, if added, uses an operator-controlled authenticated tunnel/service boundary rather than device-vendor clouds.
