# Native profile mapping draft editor

Version: 0.1.1. Updated: 2026-10-14. Status: accepted successor target.
Owner: WOH.08 H08-T1/T2/T5 and WOH.18 H18-09/H18-T13/T14/T16/T17.
Implementation: sealed local context, byte-preserving section editor and original/assessment flow implemented.
Evidence: [executed Store, byte/resource, retirement and native checks](../provenance/native-mapping-editor-2026-10.md).

## Result and preserved owners

An operator explicitly loads the installed authoring context, selects its exact
binding, edits profile identity and mapping/definition sections, and prepares a
draft import without creating a file. After confirmation and a matched import
receipt, a separate assessment uses the existing owned-draft workflow and optional
explicit source/fixture selections. The private-file draft entry remains intact.
Draft import, compatibility, review, admission, target selection and physical
qualification remain separate decisions.

WoTEx WPF.03 owns schemas, supported mechanics, finalization and validation.
Home consumes its installed export and constructs inert bytes; Swift does not
implement a JSON Schema evaluator, unit algebra, protocol decoder or compiler.
The [native contract reader](native-authoring-contract-v1.md) supplies verified
raw grammar/basis and typed limits. [Manual drafts](native-manual-draft-v1.md)
own import originals, current-basis fencing, matched owned handoff and assessment.
[Data selection](native-authoring-data-selection-v1.md) owns explicit source/
fixture handles. This editor adds no producer API, Store schema, authority route,
dependency update, file export, generation provider or physical dispatch flag.

## Closed editable representation

| Field | Input and bound | Source/default |
| --- | --- | --- |
| Context | Checked installed contract bound to current local identity/selection/generation | Explicit Load Installed Mapping Context action |
| Profile identity | Absolute URI ≤256 UTF-8 bytes and supported canonical x.y.z version | Operator; blank ID, version 1.0.0 |
| Binding | One exact installed id/version/sha256 reference; no editable digest | Operator choice; none selected automatically |
| Fingerprint | JSON array, 0..32 elements | Operator; [] |
| Channels | JSON array, 0..32 elements, preserves insertion order | Operator; [] |
| Definitions | JSON array, 0..32 elements, preserves insertion order | Operator; [] |
| Profile requires | JSON array, 0..32 elements | Operator; [] |
| Profile annotations | Optional JSON object ≤16 entries | Operator; blank means absent |

The editor assembles exactly format=wotex.profile.draft@1, profile and
definitions. Profile contains format=wotex.profile@1, id, version, binding,
fingerprint, channels and requires, plus annotations only when explicitly
supplied. Definitions and nested mapping records are supplied original JSON;
local/external semantic references, affine/table conversions, units, value
schemas and binding-specific selectors remain producer-owned data.

Preserve every JSON section's exact UTF-8 bytes, including whitespace, number
lexemes and Unicode spellings, when embedding it. Do not deserialize and
reserialize section values, trim them, replace duplicates, repair malformed
source, reorder arrays, normalize strings or invent references. Encode newly
entered identity strings and the chosen trusted binding reference as JSON
without changing their string values. Root/member ordering is deterministic:
draft format, profile, definitions; profile format, id, version, binding,
fingerprint, channels, requires, optional annotations. No row/widget identity
enters payload bytes.

Each nonblank section must be valid UTF-8 JSON of its declared container type,
with duplicate decoded keys refused by the existing strict native scanner.
Check each section's nonempty byte size ≤262144 before materialization; enforce
complete draft size ≤min(262144, exported reader.max_bytes), container depth
≤exported reader.max_depth and total nodes ≤exported reader.max_nodes. Counts
may additionally narrow to current exported channel/definition/dependency limits.
Nodes count every value/container, excluding object keys. Nested collections are
≤1024 entries; strings/keys are ≤min(8192, exported reader.max_bytes) UTF-8 bytes,
matching the producer's bounded JSON envelope. No boolean/float count alias or missing exported limit gets a default. Validation
materialization may inspect syntax, shape/count and resource bounds but its
numeric values never become output. Semantic/schema success is established only
by the producer's separate assessment. Empty required sections may therefore
import inertly and receive an invalid assessment; they assert no missing fact.

## Requirements and transitions

**ME-01 — Explicit installed context.** Require current selected local session
before credential or socket I/O. Capture once; read before identity, authenticated
installed contract and after identity with equal revisions, unchanged owner/
principal/epoch/installation/reference and current selection metadata/generation.
Return an immutable context retaining those fences and exact complete basis.
Expose only installed binding references and public identity/limit metadata.
Bindings must be exact valid references, sorted/unique by UTF-8 id/version;
unknown/damaged descriptor identities refuse. The advertised draft/profile format
constants and required wrapper properties must match this editor's supported
representation; otherwise report mapping_editor_unavailable without a substitute.
No binding, semantic, vendor or protocol model is selected by inference.

**ME-02 — Construct and prepare exact bytes.** Accept the captured immutable
editor fields and a binding from that context. Validate syntax/container/resource
bounds before credential I/O. Reject a forged or absent binding/context. Require
the context's same retained local identity/selection/generation and a fresh
before/export/after contract basis equal to the editor context. A concurrent
unrelated revision may advance since context loading, but current preparation
uses one stable current CAS. Changed producer, installed binding/meaning policy,
limits, principal, epoch, owner or association retires the context and requires
explicit reload. Construct the same kind=draft WOHA object and fresh import
original as the existing manual-draft path, preserving composed payload bytes.
Preparation publishes nothing and performs no producer assessment.

**ME-03 — Editor workflow and retirement.** Add file/editor choice within Manual
Draft. The editor has persistent field labels, byte/count bounds, one explicit
context load, installed binding choice and separate import preparation. Every
field/binding/entry change retires preparation, confirmation and local owned-
draft handoff. Context reload also retires prior preparation/handoff. Session,
access, wake and cancellation retire context and late results while preserving
unsent editor text. Mount/reload/wake does no file, context or provider read.
Shared local/access/busy and pending guards apply; busy repeat starts one call.
Do not automatically fill model facts, load a template/file, import, assess,
review, approve or select. Invalid fields display a safe bounded explanation
without source excerpts. An explicit retry is a new preparation, not a silent
repair of retained originals.

**ME-04 — Existing original and owned assessment.** Each prepared import starts
unconfirmed. Recheck same capture/current identity/CAS/association and complete
installed basis before v6 private publication. Existing bounded upload/Store
delivery and matched receipt precede owned-draft presentation. Only that matched
receipt permits separately prepared/confirmed assessment, using current exported
contract/limits and selected handles. Lost reply, malformed receipt or retired
scope retains the original and exposes no owned handoff; Activity lookup uses
that exact original without another revision. Editing cannot alter a published
original. A schema-invalid draft may remain owned but grants no compatibility,
source attribution, admission, target selection or effect.

## Acceptance and evidence

| Case | Requirements | Stimulus and independent observation | Level |
| --- | --- | --- | --- |
| ME-T1 | ME-01/02 | Frozen installed contexts and independent draft sections; exact composed bytes and hashes, preserved numeric/Unicode/whitespace lexemes; malformed/duplicate/type/count/depth/node/size/forged binding refusals | Native codec |
| ME-T2 | ME-02/04 | Two real Store families construct editor drafts, import and separately assess as compatible; independent input bytes/WOHA/CAS/receipts and v6-before-transport evidence; invalid producer draft remains inert | Software Store |
| ME-T3 | ME-01/02/04 | Changed context basis/identity, current CAS, revocation and lost committed reply; no stale context publication or false owned draft; exact original lookup commits no extra revision | Store/peer |
| ME-T4 | ME-03 | Delayed context/prepare interrupted by fields/binding/entry/session/wake/cancel; one busy call, preserved unsent text, safe errors and five existing viewport widths | Native model/render |

Evidence records source/toolchain/fixtures, executed commands and results.
Software and foreground renders do not establish installed signing/accessibility,
paired authoring, source/model authenticity or physical qualification. Catalogue
parents keep broader partial/missing axes until their complete gates have evidence.
