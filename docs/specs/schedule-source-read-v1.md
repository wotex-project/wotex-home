# Retained schedule source read v1

Version: 0.1.0. Implemented principal-private Store, Authority, local API and
CLI correspondence, 2026-10-08. WOH.15 owns the read boundary; WOH.14 retains
immutable admission history and current lifecycle guards.

`schedule_source` is a closed four-field request: `api_version: 1`, operation,
credential and `admission_revision`. The selector is an exact nonnegative
signed-64-bit integer. Zero selects the latest visible own admission; a positive
selector selects that exact publication revision. Selection includes only
`admit` history in the current authority epoch for the currently authenticated
stable principal, with current `rule:review` permission and the source's exact
target grant. Another principal's row, an absent revision, a screening record
or an ungranted target returns the same `not_found` envelope. Latest selection
skips newer ungranted targets without exposing their source or receipt.

The single Store checks the complete bounded retained ledger and all historical
source/artifact/journal joins before returning a body. It uses the existing
1024-row/8 MiB admission ceiling; selection queries at most 1025 rows and never
truncates history. Damaged correspondence disables writing through the existing
read-health path. This is a serialized read, with no schema change, journal
event, revision, operation, maintenance barrier, timer or effect.

A success has the ordinary envelope and one `schedule_source` object with
exactly `basis_scope: historical_schedule_source_only`, `original_document`
and `schedule_receipt`. The original is the complete canonical admission input,
bounded to 8192 bytes, including the retained closed source and rule documents.
The receipt is the existing exact eight-field immutable admitted receipt.
No artifact, timezone bytes, credential, clock sample, device routing or current
proof is returned. Request fields cannot choose an author, target, filesystem
root, clock, runtime, activation or dispatch setting.

Selection survives an ordinary same-owner Store/client restart and a credential
rotation for the same authorized stable principal. It needs neither today's
timezone file nor a review gate or qualified clock. Current declaration,
profile, invariant, runtime and clock readiness remain the separate activation
transaction's obligations. Reloading older content cannot refresh its proof or
manufacture a current admission. Transfer/restore and old-epoch visibility keep
their existing ownership and quarantine boundaries.

CLI `schedule-source [ADMISSION_REVISION]` uses the current protected credential
file and private socket. Omission or canonical zero selects latest; an exact
positive decimal selects that revision. Leading zeroes, signs, whitespace,
floats and expanded integers refuse before a request. Missing results exit 4.
No original input file is required for this read; the returned document remains
historical, and a new activation still needs its own complete original.

Five actual-Store/framed cases cover empty/private selection, screening versus
admission, exact/latest correspondence, current target revocation, a newer
ungranted target skipped after credential rotation, same-owner restart without
timezone/gate/clock, permission/closed-input refusals and the actual private
socket/credential-file CLI. Retained original lookup stays available separately
after target loss. The damaged-ledger regression also invokes this reader and
checks the existing fail-closed writer state. These checks create no physical
effect and establish no installed clock, signing or storage power-loss evidence.
