# ADR 0007 — One writer with durable state and an outbox

Status: accepted target decision, 2026-09-26.

Choose one Home authority per deployment, a local transactional snapshot/journal store and a durable outbox. This retains inspectable history without making every boot/migration depend on replaying all telemetry. ETS is a cache. SQLite/Exqlite is the reference host implementation; the domain remains port-driven.

Do not merge conflicting actuator intent through CRDTs or enable active-active controllers as a default. A second host cannot be fenced merely by a database epoch when legacy devices accept direct LAN commands. Transfer requires stopping/isolating the old writer.

Device I/O is outside the database transaction. Crash ambiguity is represented as unknown outcome, not an exactly-once promise. See WOH.14 and WOH.15.
