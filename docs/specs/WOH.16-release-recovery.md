# WOH.16 — Release, update and recovery contracts

Version: 0.1.2. Status: accepted target.

## Release identity

**H16-01.** A release manifest pins application, native runtime, protocol dependencies, schemas, rule compiler, capability catalogue and optional inference/verifier artifacts. Dependency licenses and SBOM cover the shipped binary closure, not just Mix dependencies. Signing identifies an artifact/issuer; it does not establish correctness. Distribution and first-run setup must disclose external downloads before offline readiness.

## Separate update domains

**H16-02.** App, data schema, device profile, model, rule set, NCP firmware and device firmware update independently. Each has staging, compatibility checks, affected admission invalidation, activation and recovery. No automatic 'update everything' transaction. Smoke firmware/hush settings and Zigbee network reset are excluded from unattended maintenance.

Before host update, stop accepting new ordinary mutations, finish or mark in-flight work under a deadline, and snapshot the durable state consistently. Rollback must understand new data or use an explicit compatible migration. Restoring an old DB may restore unsafe radio counters or obsolete permissions; it is not a universal rollback strategy.

## Backup and ownership recovery

**H16-03.** An encrypted, operator-exportable backup identifies its database revision, Home authority, device/profile bindings and credential/network-state dependencies. Recovery tests include a blank host and lost/replaced coordinator. Unsupported cross-chip restore is blocked. Never run a restored controller alongside its source with the same writer or radio identity. A reset destroys or revokes the appropriate credentials without silently transferring a household to a new owner.

The first internal export takes a consistent `VACUUM INTO` SQLite snapshot while the single Store process serializes writes. It places the temporary plaintext in a private 0700 directory, encrypts at most 32 MiB with AES-256-GCM using a caller-supplied 32-byte key, writes a new 0600 archive and removes the temporary snapshot. The archive identifies store revision and authority epoch; verification checks the authentication tag, SQLite integrity and those fields without installing the database. The key must come from a trusted local custody path and never be logged or persisted beside the archive. This is an internal backup primitive, not a shipped key broker, complete backup manifest, restore procedure, cross-host ownership transfer or power-loss guarantee. A physical restore remains gated on old-writer isolation and radio/network-counter continuity.

## Operational visibility

**H16-04.** Expose bounded read-only health for authority, store, queue budgets, device freshness, driver loss, inference/verifier availability and active artifact identity. Metrics/logs are separate from durable audit. Per-device private labels and raw utterances are not metric dimensions. Each restart creates an epoch; graph gaps remain gaps. External metrics storage is optional and cannot block command processing.

The initial recovery view reports store revision, authority epoch, writable state, held request count and active enrollment/principal counts, with dispatch explicitly disabled. It carries no Thing IDs, labels, credentials or raw activity. It is available to an authorized local-socket caller but is only a storage diagnostic subset, not the complete host health contract or a remotely exposed endpoint.

Provide a redacted support bundle with consent, finite size/retention and a preview of fields. It excludes keys, stable personal identifiers, prompts and raw household activity by default. Audit exports are permission-scoped and do not grant mutation access.

## Acceptance

H16-T1: clean offline installation after declared artifact provisioning. H16-T2: interrupted update before/after activation and incompatible-schema rollback. H16-T3: backup restore with network-counter and authority checks. H16-T4: disk growth/retention and observability outage do not erase the only authoritative receipt. H16-T5: artifact/credential revocation changes future admission without rewriting history. H16-T6: support exports pass secret/identity canary tests.
