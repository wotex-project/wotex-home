# Portable profile recovery v1 mechanism

Version: 0.1.0. Accepted bounded archive/restore mechanism, 2026-10-07; authored
before implementation. This supplies retained byte transfer for WOH.18 and
WOH.16, not cross-host fencing or controller activation.

The trusted Store export may select an encrypted profile-inclusive archive. The
single Store serializes the complete snapshot/export against writes and collection.
It takes exact raw/projection/registry commitments from its validated consistent
SQLite snapshot, includes every retained artifact (approved and revoked), and
requests those exact bytes from its configured custody owner in one bounded call.
No caller supplies reference sets. Missing/corrupt bytes or unavailable custody
reject the whole export before publishing a destination. Inert unreferenced files,
capture/review custody, registry bytes, qualification packages, reviewer keys,
transport credentials and network counters are excluded.

Custody export is available only to its configured Store process. Descriptor and
path identity, private immutable permissions, raw SHA-256, the closed data parser,
historical v1 semantic projection and declared registry commitment are checked.
Historical transfer does not depend on today's installed registry or runtime and
does not establish current usability. Store remains the only database owner.

The existing `WOHBK1` database-only format remains readable with schemas 4–20.
The new `WOHBK2` envelope uses the same AES-256-GCM key/nonce/header authentication
and revision/authority epoch fields. Its plaintext is a 32-bit big-endian database
length, exact SQLite bytes, a 16-bit big-endian object count and sorted records.
Each record has three 64-byte lowercase ASCII SHA-256 commitments (raw,
projection, registry), a 32-bit big-endian byte length and the exact author bytes.
SQLite is at most 32 MiB; there are at most 64 records of 1–32,768 bytes each.
The plaintext ceiling includes all framing. Duplicate, unordered, extra, missing,
truncated, oversized or trailing records fail. No archive value becomes an atom,
filesystem path, executable or author-selected codec. Exact record correspondence
with the authenticated database dependency set is mandatory before verification
reports included bytes or any restore file is created.

Verification preserves the existing table-set, journal, history and pin checks.
Its dependency summary states whether portable bytes are included and how many
exact objects were verified; external qualification/registry/credential custody
remains explicit. Database-only verification remains useful with missing external
bytes. A profile-inclusive archive is not a signature or a current admission.

The new trusted offline restore stages into a new absolute directory under an
existing canonical private 0700 parent. It never overwrites an existing directory,
database or object. The directory and `profiles/` are 0700; immutable raw-digest
objects are 0400 and `home.sqlite` is 0600. Files and directories are synchronized.
The database receives `restore_quarantine` before publication. A complete result
requires all verified objects and the database; errors return no completion and
remove only the newly owned, identity-pinned directory where possible. A crash
may leave inert partial custody, never an active controller. Existing database-only
staging remains compatible and does not silently discard an inclusive archive's
objects. A database-only archive with retained portable dependencies cannot claim
complete byte transfer. Store refuses every staged database until a separately
specified transfer satisfies old-writer isolation, authority/credential review
and radio-counter continuity. No marker-clearing shortcut is exposed.

Required software cases cover exact bytes and historical commitments, revoked
history, excluded orphans and transient data, missing/corrupt objects, changed
authenticated record sets, wrong keys and bounded/trailing input, historical
database-only compatibility, destination refusal, private modes, synchronized
publication failure, restart refusal and unchanged source authority. Hardware
power-loss and actual cross-host isolation remain environment-specific evidence.
