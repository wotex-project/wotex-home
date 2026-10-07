# Native network preferences v1

Version: 0.1.3. Accepted host preference mechanism with native software evidence,
2026-10-07. WOH.08 owns native selection of the existing WOH.02/03 read-only
LIFX capture option. This is neither an Authority command nor a device grant,
qualification, route, credential or physical dispatch setting.

The private descriptor, bounded read and publication/CAS implementation is
shared with the separately encoded [pending journal](native-pending-custody-v1.md).
The network document retains its own fixed filename, lock, 128-byte codec and
revision semantics. Saving the journal cannot change a network choice, and a
journal lock cannot block the network lock. Existing preference, panel and
passive inventory checks pass against this shared implementation.

The native window offers a local OS interface inventory and one explicit saved
choice for the next background-host start. Opening the window, refreshing that
inventory and registering the host do not send discovery packets. The default
is disabled. The user selects a live broadcast-capable IPv4 interface or
explicitly disables capture, saves the choice and explicitly restarts Home to
apply it. Discovery/interview remain separate authenticated actions. A saved
choice is labelled as next-start configuration, never as proof of a running
capture owner, OS network permission or device reachability. Busy or unresolved
native operation/review state blocks preference changes.

The inventory reads `getifaddrs` with a ceiling of 4,096 records and 64 offered
names. An offered interface must be up, running and broadcast-capable, with
exactly one usable IPv4 address and a contiguous /8 through /30 netmask. The
local address must not be its network/broadcast address or in 0/8 or multicast/
reserved space at or above 224/8. Names are ASCII letters followed by ASCII
letters/digits, 1–15 bytes. This inventory is guidance, not admission. Home's
existing `InterfaceSelection` independently reads the actual named interface,
derives its exact current scope and binds/checks the original UDP owner. Missing,
ambiguous or changed scope refuses capture without choosing another interface.
No device identity/address or packet transcript enters the preference.
Darwin may return a packed netmask shorter than `sockaddr_in`. Read only its
advertised bounded bytes, zero-extend omitted trailing address bytes and reject
inconsistent length/family. Never dereference the full structure beyond that
allocation. The current Apple producer copies the packed routing record in
[Libinfo getifaddrs](https://github.com/apple-oss-distributions/Libinfo/blob/main/gen.subproj/getifaddrs.c).

## Private, closed storage

Use the actual non-root OS user's fixed `Library/Application Support/WoTExHome`
directory, resolved with POSIX `realpath`. Do not read HOME, argv, defaults from
another application, an inherited environment value or a socket-supplied path.
The directory must be a same-user 0700 physical directory; pin its original
descriptor and named identity throughout reads/publication. A test may supply
an explicit disposable private directory, without granting a signing or network
admission bypass.

The only preference file is `native-network-v1.json`, a same-user 0600 regular
file with one link and at most 128 bytes. Missing means revision zero and
disabled; malformed, insecure, linked, replaced or inaccessible data is a typed
refusal. It does not select an inherited fallback. Its exact canonical UTF-8
records have no newline, escapes, whitespace, alternate numeric encoding,
nested data or other members:

```
["wotex-home.native-network.v1",revision,"disabled"]
["wotex-home.native-network.v1",revision,"lifx-read",interface]
```

Revision is an integer 1 through signed-i64 maximum. A writer compares the
captured current revision and immutable record, increments once and publishes
a complete replacement. An unchanged current choice leaves its revision and
file untouched, including the absent disabled default. Serialize cooperating writers with a same-user 0600
one-link regular `native-network-v1.lock`, nonblocking exclusive file lock and
pinned descriptor/named identity. Bound reads before parsing; reject special
files without blocking. Write an exclusive random sibling 0600 file, sync it,
repeat original directory/lock/current-record checks, atomically rename under
the held lock and sync the directory. Remove only the still-matching temporary
inode. A changed expected revision is a conflict, not overwrite or automatic
retry. A failure after publication is uncertain and needs a fresh read.
These checks contain cooperating client updates; the OS account owner remains
the trusted local preference administrator. Storage power-loss durability needs
its actual host evidence and is not inferred from a passing file fixture.

## Fixed child and OS privacy

At each original child start, load one validated immutable preference snapshot.
Disabled/absent retains the six-entry closed child environment. Only the
`lifx-read` record adds exactly `WOTEX_HOME_LIFX_INTERFACE` with that validated
name. No socket request chooses environment keys, child arguments or executable,
and no preference enables `lifx_power_dispatch_enabled` or physical admission.
The original running child is never silently replaced or reconfigured by saving.
The existing core/transport lifecycle owns scope loss and shutdown.

Add a plain `NSLocalNetworkUsageDescription` to the app and app-like helper:
Home discovers and reads local devices only on the selected network. Follow
[Apple TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)
for responsible-code attribution and stable signed identity. Do not invent a
permission-granted flag, use a synthetic packet to bypass the user workflow,
change TCC/firewall settings or add unrelated Bonjour/multicast declarations.
Actual signed launchd-child attribution, allow/deny/revoke behavior and fresh
account interaction are installed-host evidence.

Software evidence must independently check literal canonical records, bounds,
malformed names/numbers, private file/directory/lock ownership, symlink/hard-link/
special-file/refusal, stale revision and exact atomic readback; default versus
explicit child environments and exclusion of hostile inherited settings; pure
interface ambiguity/netmask/source vectors and actual bounded OS enumeration
without sending packets. Compile the actual app/helper, inspect an unselected
panel and verify required privacy metadata in packaging. Existing selected-
interface/capture tests retain their own scope; these checks do not qualify a
device, installed privacy decision or physical write.

The closed record and private file layer are implemented. The independent
`mix woh.native.network.preference.smoke` fixture checks literal records and
round trips, numeric/name/member/bound refusals, absent and unchanged disabled
state, successive atomic replacements, stale record/inode conflicts, held-lock
capacity, symbolic/hard links, FIFO preference/lock refusal, insecure modes,
oversized/corrupt contents, lock contents, exhausted revision and directory alias
refusal. It compiles the actual source under Swift 6/macOS 15 warnings-as-errors
and performs no network or Keychain operation.

The fixed child now loads that snapshot before launch. Disabled/absent produces
exactly the original six environment entries; the enabled record supplies only
the seventh read-only interface key. Hostile inherited capture/dispatch values
are excluded. Preference tests cover both environments and malformed refusal;
`mix woh.native.core.pipe.smoke` additionally checks the actual original child
against an inert peer that retains its first interface after another preference
is saved. The actual Home receipt/lifecycle checks still pass with no configured
capture, including parent signal/pipe loss and cleanup. The unsigned broker
socket fixture also passes with this joined startup dependency.

`mix woh.native.network.inventory.smoke` checks independent prefix, source,
ambiguity, flags, count and packed-netmask vectors. It reads actual Darwin and
OTP interface inventories and requires exact agreement on offered names; it
opens no socket and logs no addresses. `mix woh.native.network.panel.smoke`
exercises explicit refresh/save, pending guard refusal, stale-window conflict,
disappearance between selection/publication and explicit disabling of an
unavailable saved choice using private files and inert offers. It renders an
unselected panel, inspected for unclipped controls and readable explanations.
The shared app model gates session changes while preference work is busy.
Both app and helper compile fully with Swift 6/macOS 15 warnings-as-errors.
Assembly/XcodeGen declare the required usage description, and inventory rejects
missing app or empty helper descriptions. The affected packaging, interface,
capture and Host suites pass 22 cases. These checks do not register a service,
change a real account preference, send discovery packets, grant OS access or
establish device/installed/power-loss qualification.
