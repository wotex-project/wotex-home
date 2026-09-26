# WOH.06 — Local intent classification without control authority

Version: 0.2.1. Status: accepted target, partial implementation.

## Role and model choice

**H06-01.** DistilBERT remains required in the complete Goatmire demonstration profile. It is optional to ordinary Home control. A classifier produces a candidate; it neither discovers physical truth nor authorizes an Action. Typed UI/CLI and structured Matter commands bypass classification and use the same command gate.

A base DistilBERT checkpoint is not a trained home-intent recognizer. Admission requires an actual sequence-classification checkpoint, exact tokenizer, label map, calibration, artifact license and evaluation evidence. The initial Elixir path is Bumblebee/Nx.Serving with a qualified execution backend. [Bumblebee's text classification serving](https://bumblebee.hexdocs.pm/Bumblebee.Text.html#text_classification/3) supplies the mechanism, not our intent labels or accuracy guarantees.

**H06-02.** Compare the trained model against a deterministic grammar and a compact statistical intent baseline. Keep DistilBERT for the requested PoC even if another optional profile later wins on energy/latency. Do not add a generative LLM or retrieval system for ten commands without measured benefit. ONNX/runtime alternatives are separate qualified profiles, not silent conversions with assumed equivalent scores.

## Candidate contract

A candidate carries model/tokenizer/label-map identities, supported locale, normalized text reference or ephemeral digest, ranked intents and scores, slot candidates with provenance, ambiguity/OOD disposition and evaluation timestamp. Raw scores are not calibrated probabilities. Input digests are not retained by default because common household phrases can be guessed.

**H06-03.** Device/room references resolve against the currently authorized registry after classification. An ambiguous 'turn it off' requests clarification; it does not select the last arbitrary device. Slots require deterministic type, range, unit and permission validation. Multi-action phrases are either explicitly supported by the grammar or rejected; truncation may not silently remove negation or a second clause.

The first grammar baseline recognizes only anchored English `turn/switch on/off [the] <exact target alias>` phrases, with optional leading `please`. It accepts at most 256 input bytes, normalizes case and repeated spaces, and abstains on pronouns, clause conjunctions, punctuation indicating another sentence, unsupported locale and malformed text. Its result is an ephemeral candidate, never an authenticated request. An exact alias must resolve to one currently granted enrolled Light with a validated writable `power` capability; only then may a typed mutation *preview* be constructed. The caller must still submit that preview to the authenticated Store gate, which rechecks current grants, revision, policy and runtime state. The grammar does not provide DistilBERT evidence or a general natural-language interface.

The initial supported locale is an explicit release choice. English weights do not imply Swedish support. Record Swedish/English/code-switched test cohorts separately. Speech recognition and wake-word detection are outside DistilBERT; a future microphone path needs its own offline model and privacy contract.

## Calibration and uncertainty

**H06-04.** Use held-out paraphrases, negation, quoted commands, irrelevant conversation, ambiguous devices, unsupported languages and adversarial inputs. Split by paraphrase/session source to reduce evaluation leakage. Choose per-intent thresholds, top-two margins and OOD rejection from validation evidence, not a universal score such as 0.9. Report false acceptance, abstention, confusion and calibration alongside accuracy. More risk requires explicit confirmation, not simply a higher confidence score.

No intent class may request smoke hush, provisioning, credential export, firmware update or safety-policy changes in the baseline. Such requests are denied independently of classifier output. An optional agent cannot relabel them as ordinary light commands.

## Offline execution and updates

**H06-05.** Models, tokenizer files, native runtimes and compilation artifacts are installed and checked before the offline readiness gate. Startup never downloads them. Missing artifacts return `intent_unavailable`; there is no cloud fallback. Bound input bytes/tokens, batch size, concurrency, memory and job time. Do not assume Apple GPU/ANE support from an Elixir backend name; record measured CPU/accelerator behavior per target.

Model updates install into a new immutable slot, pass the regression corpus and become active atomically. Rollback preserves label-map compatibility. Model version changes never rewrite admitted rules or historical decisions. Optional inference runs in an isolated restart/resource domain and cannot starve device observation.

## Acceptance

H06-T1: actual trained checkpoint recognizes the held-out allowed intents and abstains on declared negatives. H06-T2: raw text, private room names and tokens do not leak in telemetry. H06-T3: missing model/WAN loss does not affect typed control. H06-T4: resource saturation leaves runtime guards responsive. H06-T5: backend/quantization changes repeat semantic and calibration tests. H06-T6: every accepted candidate still passes current authorization and invariant checks.
