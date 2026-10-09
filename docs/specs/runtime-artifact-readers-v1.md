# Fresh runtime artifact readers v1

Version: 0.1.2. Implemented software boundary, 2026-10-09.
WOH.03 owns protocol qualification, WOH.07 runtime correspondence and WOH.14
the enclosing execution guards. This reader changes neither admission scope
nor the original LIFX v2 term-encoded digest convention.

For an application with more than eight declared modules, `RuntimeArtifacts`
observes the current code path and working directory and builds a fresh index
of requested BEAM filenames. It searches directories in path order, retains
only the first occurrence of each requested filename and stops when all are
found. The index is limited to 256 paths, 16,384 entries in each directory and
the existing 512-module application bound. Missing directories are skipped.
Archives, inaccessible directories and oversized path/listing layouts fall
back to OTP's existing `get_object_code` lookup rather than ignoring a possible
preceding source. A missing requested artifact refuses. Absolute filename
construction preserves parent references through symlinks, matching OTP's
actual source selection rather than resolving those references lexically.
The absolute directory is computed once per visited directory, then joined
to selected filenames. This shares only deterministic path construction
inside the current pass; it skips no artifact read or loaded-code check.

At most four temporary readers process ordered, disjoint module groups. Each
gets only its selected filenames and parsed-checksum memo entries. It receives
no SQLite handle, credential, qualification receipt or current guard result.
Ordinary files use public raw file operations, 64-KiB reads, an unconditional
descriptor close and complete EOF verification. Reading more than 16 MiB,
empty content, malformed BEAM content or a mismatching module refuses. Each
file's complete bytes remain SHA-256 bound using the existing deterministic
term encoding. Current loaded-code checksums must match; retained old code is
checked before and after the read/checksum comparison. Parsed checksums may
still be reused only after a fresh complete-byte digest match.

A reader exception or its five-second task timeout refuses the inventory and
finishes the remaining temporary readers. Sorted module order is preserved.
The parsed memo remains bounded to 2,048 entries; successful reader results
merge parsed checksums, retaining only the current module set on overflow.
Neither filenames, file bytes nor a manifest is retained for another pass.
An observed change to the code path or working directory refuses the complete
pass. Unscoped guards obtain their own fresh inventory. A Store execution
transaction may separately use a [bounded guard inventory](runtime-guard-inventory-v1.md)
with fresh complete opening/closing passes; that scope closes before the final
unscoped execution guards. The reader itself retains no manifest. These are trusted
release consistency checks, not atomic filesystem/live-upgrade protection or
a hostile-host defence. A task timeout does not promise to interrupt blocked
kernel I/O or bound directory-listing latency.

Thirteen artifact cases pass in fresh source, including an independent isolated
VM with twelve fixture modules. They compare every complete-byte digest with
OTP lookup and exercise warm byte changes that preserve the BEAM code checksum,
loaded/file drift, old code, deletion and exact restoration. A new preceding
file is observed even when OTP's directory cache was previously warmed. Actual
archive lookup, symlink/parent traversal and oversized-listing fallback preserve
the digests of the actual OTP-selected files.
Call tracing confirms exactly four finished readers, one visit per module and
memo overflow handling. Source-isolated exception, timeout and mid-pass path
mutation probes refuse without a manifest and verify reader cleanup.

Private paired same-VM measurements of the early-stop/raw-reader prototype
observed complete Home/UDP inventories at 8.4–17.6 ms versus 41.3–68.1 ms for
the prior reader over seven alternating pairs. Those are local measurements,
not a host latency guarantee. Seven further alternating pairs with the final
bounded reader observed 22.9–30.5 ms versus 56.6–77.9 ms for the prior reader
under local background load. Earlier parallel OTP-lookup and full-directory
snapshot prototypes failed to improve the complete flow sufficiently and were
discarded. The final bounded reader separately passes the independent actual
UDP default-window and exact-expiry tests. A local default-window handoff was
observed at 1,614 ms. A private positive one-second attempt still expired safely
before a set; its peer timed out waiting for that absent packet. Minimum-window
usability, qualified autonomous admission and installed/physical qualification
remain obligations. No production deadline is widened.

Those measurements precede transaction-bounded guard inventory reuse. The
new scope removes repeated inventories during preparation; the earlier failed
one-second attempt remains historical evidence rather than a measurement of
the scoped implementation. Repeated minimum-window and host/load qualification
remain required.

A Store call-time trace of the transaction-scoped implementation still
computed 12,030 absolute directories before the default-window handoff.
Computing each visited directory once removes that redundant work. The trace
itself observed handoff at 1,684 ms and is not an unprofiled latency sample.
The directory-reuse implementation passed 29 final-guard and mandatory UDP
cases, with default-window handoff at 929 ms. Its separate opt-in one-second
attempt still reached the final clock at 1,003 ms and refused without a set.
This cleanup therefore supplies no minimum-window readiness claim.
All sixteen artifact cases also passed, including preceding-file selection,
archive fallback, symlink/parent traversal, loaded/file drift, scope closure,
reader cleanup and path mutation. Real sockets remained enabled in the
mandatory UDP run.

The first source-isolated probes failed because the test harness truncated a
quoted source string; complete literal quoting fixed the harness. A subsequent
bounded-read compile exposed an ambiguous dynamic-range guard warning; explicit
positive-size and remaining-byte comparisons replaced it. These preliminary
failures are not successful guard or packaging evidence.

Owner regression runs also exposed two timing-dependent harness failures. The
competing worker used a baseline recorded before constructing sixteen historical
occurrences; it now records a real Store-stamped report after that setup, before
any queue is sealed. The fresh-priority test performed complete immutable-history
lookup while a protocol reply was deliberately paused. That lookup now follows
settlement, preserving its exact original assertion without spending the real
routing deadline. Production clocks, deadlines, freshness, guards and causal
spend are unchanged by those harness corrections.

Final fresh-source verification passed 198 selected cases across artifact,
mapping/correspondence, admission, clock custody/context, supervised power,
Host lifecycle, enclosing guards and original/owner delivery. Both independent
UDP window cases also passed with real sockets enabled; the final default-window
handoff was observed at 1,715 ms. Formatting, warnings-as-errors compilation,
the indexed 19-contract and working 20-contract catalogues, 31 local references
and Git whitespace checks passed. Packaging is separate from these checks and
does not establish physical or installed-clock qualification.
