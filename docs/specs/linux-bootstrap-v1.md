# Linux bootstrap manifest v1

Version: 0.1.0. Status: development integrity format; authenticity and installation qualification missing.

This format is subordinate to the [release contract](WOH.16-release-recovery.md)
and precedes the [service installation boundary](linux-service-layout-v1.md#installer-boundary).
It lets an independently trusted launcher verify and privately copy the whole
payload before running any inspected Home or ERTS code. A successful copy is
inert staging, not account creation, registration, update or authority admission.

## Binding

The fresh-source build runner emits `RELEASE_PATH.bootstrap.tsv` outside the
inventoried payload and prints its SHA-256. The manifest includes the inventory
itself and every inventoried file. Keeping it outside avoids a self-hash cycle.
Its header is `WOTEX_HOME_BOOTSTRAP`, version `1` and the full source revision,
separated by tabs. Each following, path-sorted row has SHA-256, octal permission
bits, decimal byte length and relative path, separated by tabs. Every line
ends in LF. No signature or authenticity is inferred from these hashes.

Paths contain only ASCII letters, digits, `_`, `+`, `@`, `.`, `/` and `-`.
They are at most 512 bytes, relative, and have no empty, dot or parent segments
or leading hyphen. Duplicate and unsorted paths refuse. Group/other writable
permissions and special file mode bits refuse. Manifest, file count, directory
count and aggregate payload bounds are 2 MiB, 10,000, 10,000 and 1 GiB.
The release inventory remains an independently checked final report.

The expected manifest pin and launcher must come from trusted build/operator
custody independently of the inspected payload. Reading a pin from that same
untrusted download does not authenticate it. Signed distribution remains work.
The trusted build-side producer verifies inventory before and after rendering;
its verification requires exact regenerated manifest bytes and the expected pin.

## Independent staging

The [launcher](../../native/linux/bootstrap) clears inherited environment and
runs the [verifier](../../native/linux/bootstrap.pl) with Debian base Perl and
`sha256sum`. No Home, ERTS, compiler or inspected executable runs. The verifier
hashes and bounds the manifest before creating staging. It copies only declared
files; extra undeclared source files are not transferred or executed.

Source directory traversal holds directory descriptors and refuses symlink
components. Files must be regular with matching size and permissions; FIFO,
linked, changed, truncated and grown files refuse. Each private copied file is
hashed through an already-open input before receiving its declared permissions.
Destination writes are anchored to held directory descriptors. The destination
must be absent, under a caller-owned directory without other writers. New
directories remain 0700. Changing the presented destination path refuses.
Failure removes this invocation's partial files and directories; an existing
destination is never adopted or removed. The complete operation has a
120-second bound. Crash/power-loss cleanup and installed lifecycle are separate
installer obligations, not established by ordinary exception cleanup.

## Evidence and exclusions

Six focused cases run on Debian 13 arm64, including actual base-tool staging,
inert executable bytes, repeat refusal, changed bytes, source links/FIFOs,
special modes and independently malformed pinned manifests. Three portable
producer cases run on macOS; Linux-only execution is excluded there.
The existing clean `a702d195bfc34b5cb73a6b44990cef6bcb8ac04a` release was
independently copied in the pinned bare Debian runtime as root and UID/GID
10001, with read-only source/root, no network, no added packages and dropped
capabilities. All 1,455 files, including the inventory itself, were verified;
the staged root remained 0700. These checks establish development integrity
and inert copying, not a current-source rebuilt artifact, installed service,
artifact authenticity, physical qualification or shared-host capacity.
