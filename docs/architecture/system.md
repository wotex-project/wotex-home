# System architecture

## Design objective

Wotex Home is a deterministic local home runtime first. AI and formal tooling strengthen specific boundaries; they do not sit in the mandatory control loop for every operation.

## Dependency direction

    macOS host / Nerves host
              |
          wotex-home
       deterministic core
      /        |         \
 profiles   automation    policy
      \        |         /
         WoTEx Runtime
              |
     generic WoTEx protocols
              |
       physical devices

Optional side capabilities:

- DistilBERT -> untrusted request adapter -> deterministic core
- ex_maude -> rule admission / selected verification
- Refpath -> validated Thing/policy consumer

WoTEx never depends on Home. ex_maude never depends on Home. Vendor integrations never become generic transports.

## OTP ownership

    WotexHome.Supervisor
    ├── Persistence
    ├── DeviceRegistry
    ├── DiscoverySupervisor
    ├── ThingSupervisor
    ├── AutomationSupervisor
    │   ├── ActiveRuleSet
    │   └── RuntimeGuards
    ├── QualificationSupervisor   optional ex_maude-backed admission service
    ├── IntentSupervisor          optional DistilBERT adapter
    └── HostAPI

Library construction starts no hidden singleton. Radio/socket/native resources are explicitly configured and supervised by the host.

## Automation deployment

    draft rules
       |
    schema/static checks
       |
    qualification policy
       |
    ex_maude when required
       |
    immutable admitted revision
       |
    atomic activation
       |
    runtime guards
       |
    WoT Actions

The previous active revision remains in service if a candidate revision is rejected or cannot satisfy its required qualification policy.

## Device data flow

Physical protocol evidence is normalized into profile-backed observations. Home state is derived deterministically. WoTEx TDs expose semantic affordances. Effects are confirmed separately by observation.
