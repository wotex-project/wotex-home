# System architecture

Version: 0.2.0. Target design; hardware and implementation evidence are separate.

## Two planes, one physical authority

The control plane validates immutable candidate configurations. The execution plane observes devices and dispatches only current, authorized intents. Verification never holds the dispatcher hostage and the dispatcher never activates its own unreviewed fallback rules.

```text
native UI / CLI / Matter / optional local language input
                         |
                 authenticated Home API
                         |
       +-----------------+--------------------+
       |                                      |
 draft -> checks -> proof receipts       observations / requests
       |                                      |
 immutable admitted revision          state + invariant guards
       +-----------------+--------------------+
                         |
              one durable execution owner
                         |
       profile adapters -> WoTEx -> local protocols
```

## Ownership

Home's pure modules own typed rules, effect domains, state reduction, planning and policy. A host owns the SQLite writer, credentials, radio/socket lifecycles, clock, schedulers and supervised workers. WoTEx stays consumer-neutral. Model compilation for Home belongs here; generic checker result/receipt mechanics belong in ex_maude. DistilBERT is a required demonstration input profile, not the control authority. Refpath remains an optional client.

## Supervision

Use separate restart domains for persistence/authority, drivers, read APIs, optional inference and qualification. If the authority/writer fails, dependent dispatchers stop before restarting. One crashed model worker must not restart a Zigbee network. Bounded work pools prevent radio floods, model jobs or slow UI readers from exhausting the controller. Protocol processes are explicit children; loading a dependency starts nothing.

The driver boundary resolves credentials per operation and admits only finite typed messages. Domain logic never handles serial ports or UDP sockets. Device-family mappings do not leak into Swift.

## State and deployment

The baseline is one writer on one host with durable snapshots, a domain journal and an outbox; see WOH.14. There is no distributed database, active-active controller, runtime source-code plugin loader or mandatory MQTT broker. MQTT is selected only for devices that use it. Model artifacts and TD context/schema registries are installed locally and pinned before operation.

The first installed macOS host keeps an opt-in per-user background controller alive independently of windows. Unlike an art frame, a home may need live automation while its UI is closed. macOS sleep/logout/Keychain lock still have explicit availability limits. Nerves later supplies the same authority as an appliance; switching hosts is an authority-transfer procedure, not starting another copy.

## Prevention claim

Rejected drafts have no physical side effects. Admitted rules retain runtime guards, causal budgets and current-state checks. This prevents the classes actually specified and tested; it is not a claim that arbitrary hardware or unmodeled environments are mathematically safe.
