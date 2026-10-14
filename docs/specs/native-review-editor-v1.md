# Native source and fixture review editor

Version: 0.1.0. Updated: 2026-10-14. Status: accepted successor target.
Owner: WOH.08 H08-T1/T2/T5 and WOH.18 H18-09/H18-T14/T16/T17.
Implementation: planned. Evidence: missing.

## Result and compatibility

An operator enters source citations, unresolved roots and an optional owned
envelope in the native review form, then separately prepares and confirms the
review. The operator no longer needs a review-content JSON file. The existing
private-file entry remains available and preserves exact input validation.
The editor prepares the same canonical original and uses the same current
contract/candidate checks and complete v6 publication as
[review preparation](native-authoring-review-preparation-v1.md).

[Authoring reviews](authoring-reviews-v1.md) remains the semantic owner of
actual required roots, selected-source ownership, envelope consumption and
independent fixtures. Native editing never invents citations, fetches locators,
derives fixture expectations, adds sources to an immutable candidate, approves
or selects a profile, grants access, or qualifies physical behavior. No sibling
API, Store schema, route, original encoding or dependency update is required.

## Closed form and bounds

| Input | Representation / bound | Source |
| --- | --- | --- |
| Candidate | Positive signed-64 epoch in canonical decimal; existing Home operation ID | Explicit operator choice |
| Content entry | File or editor; editor is offered only when its typed preparer exists | Operator |
| Review mode | Exactly source or complete; default source | Operator |
| Evidence | 0..256 rows, each exactly instance_path, source_ref and locator | Operator |
| Unresolved roots | 0..64 exact root strings | Operator |
| Envelope | Null for source; exact digest/positive signed-64 first_revision handle for complete | Owned import receipt supplied by operator |

Each root is ≤512 UTF-8 bytes and exactly /profile/binding,
/profile/fingerprint/i, /profile/channels/i/selector, /semantic,
/invalid_values or /conversion, or /definitions/i/unit or /value_schema,
where i is canonical decimal 0..31. Source/envelope digests are lowercase
64-hex. Locator is nonempty UTF-8 ≤256 bytes with no Unicode Cc/Cf. No trimming,
case conversion, normalization or guessed value is permitted. Empty rows refuse;
blank input does not mean deletion. Add/remove row actions are explicit and
respect their count ceilings. Fields use persistent labels and visible counts.

Rows remain in operator insertion order during editing. Preparation sorts
evidence by unsigned UTF-8 tuple (path, source, locator), and unresolved roots
by unsigned UTF-8 bytes. Reject exact byte duplicates without dropping any row.
Normalization-equivalent but byte-distinct locator strings remain distinct.
Missing/invalid fields refuse the whole preparation. Native row UUIDs are
presentation identities only and never enter the four-field review content.

The content is exactly mode, evidence, unresolved_paths and envelope_ref.
Source mode supplies null envelope_ref; complete-only envelope fields may remain
in the editor draft when source is selected, but have no source-mode wire value.
Complete mode requires canonical decimal first_revision >0. The complete final
original, including current header and derived candidate reference, must obey
the existing 131072-byte bound and unchanged codec limits. Defaults are empty
evidence/unresolved lists and blank complete-envelope inputs. Defaults may
prepare incomplete source review; they do not assert source coverage.

## Requirements and transitions

**RE-01 — Typed content before I/O.** Accept a bounded immutable native content
value with only the fields above. Validate and canonicalize it using the existing
complete-original codec before acquiring a credential or issuing a request.
Perform no file/clipboard/provider/URL I/O to construct editor content. Reject
bad roots/digests/locators/counts/duplicates/native handles locally. The private
file path retains duplicate-JSON-key/depth/equal-field checks and sorted-input
requirements; it is not silently converted into editor rows or reordered.

**RE-02 — One trusted preparation boundary.** File and typed editor entries
use the same selected-local driver: local/current selection before content I/O,
one captured credential, before identity/installed export/candidate status/after
identity with equal current revisions and unchanged owner/principal/epoch and
installation/reference association. Require compatible actual candidate and
current complete basis; derive its five-field reference from its receipt.
Construct a fresh original at current epoch/CAS, revalidate final bytes and
retain the exact capture/basis privately. Preparation creates no Store mutation
or pending file. A preview shows only counts and public operation/basis metadata.
Locators and content stay out of reflection/diagnostics. The Store independently
checks actual selected sources, required roots, envelope/fixture ownership and
current authority when submitted.

**RE-03 — Editor and retirement.** Add an explicit file/editor choice in the
review entry. Capture the exact editor value for one preparation. Evidence row
add/remove/field edits, unresolved row edits, mode/envelope changes, candidate
changes, entry changes, session/access replacement, wake and cancellation retire
prepared decisions and confirmation. Late completions cannot restore them.
Preserve unsent editable rows on session/wake/input invalidation; they convey
no authorization and require new preparation. While busy, editors and row actions
are disabled and repeat preparation starts one call. Shared local/access/busy
and pending-root guards remain in force. Mount/reload/wake do no preparation.

**RE-04 — Separate confirmation and original recovery.** A successfully
prepared editor review starts unconfirmed. Submission rechecks the same scope,
global CAS and complete installed basis before publishing the complete original
to the private v6 root, then using existing review upload/Store delivery. Matched
receipt resolves the pending original and exposes separate source/consumption/
fixture/proposal statuses. Lost or malformed replies retain the original for
Activity recovery; editing does not change its bytes or authorize a new retry.
Cancellation cannot undo a handed-off Store operation. No automatic submission,
review, approval, selection or file export follows an edit, read or receipt.

## Acceptance and evidence

| Case | Requirements | Stimulus and independent observation | Level |
| --- | --- | --- | --- |
| RE-T1 | RE-01 | Unsorted independent citations/roots produce exact canonical sorted fields; reject byte duplicates, invalid roots/digests/Cc/Cf/locator sizes, count limits and noncanonical/overflow revisions; byte-distinct Unicode locators survive | Native codec |
| RE-T2 | RE-01/02/04 | Both real Store families prepare source and complete reviews from editor rows; independently decode retained original, inspect v6 publication before transport, compare actual receipt; file entry regression remains green | Software |
| RE-T3 | RE-02/04 | Stale candidate/basis/CAS, current permission loss, unselected source and lost committed reply; no false success, retained exact original and separate lookup without new revision | Software Store/peer |
| RE-T4 | RE-03 | Delayed edits/add/remove/mode/envelope/entry/session/wake/cancel retire results; one busy call; rows survive retirement; five existing viewport widths with long metadata/locator fields | Native model/render |

Record source/toolchain/fixtures, executed commands and results. Software checks
and foreground renders do not establish installed signing/accessibility, paired
authoring, source authenticity or physical qualification. Catalogue parents keep
broader partial/missing axes until their complete obligations have evidence.
