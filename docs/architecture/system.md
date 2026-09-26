# System architecture

## Dependency direction

```text
wotex-home
  -> wotex / wotex-runtime
  -> selected WoTEx protocols/transports
  -> ex_maude
  -> Nx/Bumblebee stack for optional local intent

hosts/macos -> wotex-home
hosts/nerves -> wotex-home

Refpath -> optional consumer of validated Home Things
```

WoTEx never depends on Home. ex_maude never depends on Home. Vendor integrations never become generic transports.

## OTP ownership

Target supervision:

```text
WotexHome.Supervisor
├── Persistence
├── DeviceRegistry
├── DiscoverySupervisor
│   ├── LifxDiscovery
│   ├── HueDiscovery
│   ├── ZigbeeCoordinator
│   └── ShellyDiscovery
├── ThingSupervisor
├── AutomationSupervisor
├── IntentSupervisor          optional local model
├── VerificationSupervisor    explicit ex_maude pool
└── HostAPI
```

Library construction starts no hidden singleton. Radio/socket/native resources are explicitly configured and supervised by the host.

## Data flow

Physical protocol evidence is normalized into profile-backed observations. Home state is derived deterministically. WoTEx TDs expose semantic affordances. Commands pass authorization/policy and, where configured, formal qualification before Runtime execution. Effects are confirmed separately by observation.
