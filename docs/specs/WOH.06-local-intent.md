# WOH.06 — Local intent classification without control authority

Version: 0.2.4. Status: accepted target, partial implementation.

## Role and model choice

**H06-01.** DistilBERT remains required in the complete Goatmire demonstration profile. It is optional to ordinary Home control. A classifier produces a candidate; it neither discovers physical truth nor authorizes an Action. Typed UI/CLI and structured Matter commands bypass classification and use the same command gate.

A base DistilBERT checkpoint is not a trained home-intent recognizer. Admission requires an actual sequence-classification checkpoint, exact tokenizer, label map, calibration, artifact license and evaluation evidence. Local candidates under `_build/intent-model-*` are deliberately **not admitted**. The Elixir training path uses [Bumblebee's fine-tuning approach](https://bumblebee.hexdocs.pm/fine_tuning.html) with Axon and EXLA. A later offline serving path must load the native Nx parameters with the matching model definition and qualify its execution backend. [Bumblebee's text classification serving](https://bumblebee.hexdocs.pm/Bumblebee.Text.html#text_classification/3) supplies a mechanism, not our intent labels or accuracy guarantees.

**H06-02.** Compare the trained model against a deterministic grammar and a compact statistical intent baseline. Keep DistilBERT for the requested PoC even if another optional profile later wins on energy/latency. Do not add a generative LLM or retrieval system for ten commands without measured benefit. ONNX/runtime alternatives are separate qualified profiles, not silent conversions with assumed equivalent scores.

## Candidate contract

A candidate carries model/tokenizer/label-map identities, supported locale, normalized text reference or ephemeral digest, ranked intents and scores, slot candidates with provenance, ambiguity/OOD disposition and evaluation timestamp. Raw scores are not calibrated probabilities. Input digests are not retained by default because common household phrases can be guessed.

**H06-03.** Device/room references resolve against the currently authorized registry after classification. An ambiguous 'turn it off' requests clarification; it does not select the last arbitrary device. Slots require deterministic type, range, unit and permission validation. Multi-action phrases are either explicitly supported by the grammar or rejected; truncation may not silently remove negation or a second clause.

The first grammar baseline recognizes only anchored English `turn/switch on/off [the] <exact target alias>` phrases, with optional leading `please`, `could you` or `can you`. It accepts at most 256 input bytes, normalizes case and repeated spaces, and abstains on pronouns, clause conjunctions, punctuation indicating another sentence, unsupported locale and malformed text. Its result is an ephemeral candidate, never an authenticated request. An exact alias must resolve to one currently granted enrolled Light with a validated writable `power` capability; only then may a typed mutation *preview* be constructed. The caller must still submit that preview to the authenticated Store gate, which rechecks current grants, revision, policy and runtime state. The grammar does not provide DistilBERT evidence or a general natural-language interface.

The initial supported locale is an explicit release choice. English weights do not imply Swedish support. Record Swedish/English/code-switched test cohorts separately. Speech recognition and wake-word detection are outside DistilBERT; a future microphone path needs its own offline model and privacy contract.

## Calibration and uncertainty

**H06-04.** Use held-out paraphrases, negation, quoted commands, irrelevant conversation, ambiguous devices, unsupported languages and adversarial inputs. Split by paraphrase/session source to reduce evaluation leakage. Choose per-intent thresholds, top-two margins and OOD rejection from validation evidence, not a universal score such as 0.9. Report false acceptance, abstention, confusion and calibration alongside accuracy. More risk requires explicit confirmation, not simply a higher confidence score.

The English Light experiment uses `priv/intent/corpus-v2.json`, split by template family and target alias. `mix woh.intent.train` checks exact hashes of the pinned Apache-2.0 DistilBERT base, trains a three-label model locally, calibrates on validation examples and writes only aggregate evaluation and native Nx weights to an ignored candidate slot. One five-epoch Elixir run accepted 16/20 allowed held-out phrases with 0/44 false accepts after the exact grammar/authorized-alias gate. Its deterministic character n-gram Naive Bayes baseline and the grammar each accepted 20/20 with 0/44 false accepts. The earlier local Safetensors experiment accepted 17/20 under its own training and baseline recipe; its artifact remains checkable, but its former training program has been replaced. Neither result is model admission or physical qualification. The authored set is small, synthetic and narrower than household speech; a zero count here supplies no field error-rate guarantee. A new independently sourced cohort and runtime/latency tests are needed before admission. Never improve apparent safety by counting the grammar's rejection as model skill.

The training task verifies pinned base hashes before use and writes model/tokenizer hashes, label map, corpus hash, tool versions and aggregate evaluation to a local immutable slot. It records a seed and shuffles batches, but identical weights across machines or repeated EXLA runs are not guaranteed; the manifest identifies the actual bytes evaluated. `mix woh.intent.artifact.check` accepts the historical Safetensors format and native Nx format. It checks slot integrity relative to its manifest, bounds every file and the corpus, rejects duplicate JSON members and symlinks, and verifies the DistilBERT class/label and tokenizer contract before reporting evaluation. A release must separately pin the manifest digest to authenticate installed bytes; the checker does not parse model weights or qualify inference. Neither tool installs a serving runtime or turns a model score into a command.

No intent class may request smoke hush, provisioning, credential export, firmware update or safety-policy changes in the baseline. Such requests are denied independently of classifier output. An optional agent cannot relabel them as ordinary light commands.

## Offline execution and updates

**H06-05.** Models, tokenizer files, native runtimes and compilation artifacts are installed and checked before the offline readiness gate. Startup never downloads them. Missing artifacts return `intent_unavailable`; there is no cloud fallback. Bound input bytes/tokens, batch size, concurrency, memory and job time. Do not assume Apple GPU/ANE support from an Elixir backend name; record measured CPU/accelerator behavior per target.

Model updates install into a new immutable slot, pass the regression corpus and become active atomically. Rollback preserves label-map compatibility. Model version changes never rewrite admitted rules or historical decisions. Optional inference runs in an isolated restart/resource domain and cannot starve device observation.

## Acceptance

H06-T1: actual trained checkpoint recognizes the held-out allowed intents and abstains on declared negatives at least as well as the grammar and compact baseline, on a separately sourced cohort. H06-T2: raw text, private room names and tokens do not leak in telemetry. H06-T3: missing model/WAN loss does not affect typed control. H06-T4: resource saturation leaves runtime guards responsive. H06-T5: backend/quantization changes repeat semantic and calibration tests. H06-T6: every accepted candidate still passes current authorization and invariant checks. The current candidate fails H06-T1; H06-T2–T5 require a deployed runtime and H06-T6 remains a control-path obligation.
