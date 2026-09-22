# ChatCapture — the iOS capture stage for a chat copilot

Screenshot → ordered chat transcript, for the iOS port of **jev-chat-jarvis** (a copilot that
reads the conversation on screen, judges it, and drafts replies). Stock iOS has no accessibility
service, no system overlay and no way to screenshot another app, so on iOS the screen arrives as
a **user screenshot** — which makes this stage, text recognition plus layout reconstruction, the
whole of capture.

```
Sources/ChatCapture/     capture stage: OcrLine/OcrDocument -> BubbleSegmenter -> [Bubble]
Sources/JudgeClient/     decision stage: routes, typed judgments, drafting, ranking
Sources/visionlines/     measurement harness: Apple Vision over a folder of PNGs
Tests/ChatCaptureTests/  parity fixtures + capture-rule tests
Tests/JudgeClientTests/  route/question/HTTP/copilot tests (stubbed transport, no network)
shots/                   the 12-screenshot corpus (native 3x, ground truth generated with them)
```

## The two halves

```
screenshot ──Vision──> [OcrLine] ──BubbleSegmenter──> [Bubble{side,sender,text,quote}]
                                                                  + [DroppedLine{region,text}]
[Bubble] + user facts ──JudgeClient──> Judgment{intent, danger, reply-now, verify-first}
                                  └──> reply route (only if a reply is due) ──> candidates
                                  └──> ranked by one score question per candidate
```

### Capture stage

`OcrLine` is the only thing the recogniser must supply, which is what makes the rules
engine-independent. `DroppedLine` records the screen chrome that was discarded (status bar, nav
bar, notification banner, timestamps, input bar, avatar/badge artwork) — chrome leaking into a
transcript is a data-integrity bug, so it is reported rather than silently swallowed.

### Decision stage

Three independently configurable routes (judgment / reply / vision) with the v1.3 presets
(TypeSafe, OpenRouter, DeepSeek, Qwen-compatible). The **key always inherits**; an address only
inherits inside one protocol family, so a TypeSafe-only setup can never silently point the reply
route at an endpoint that serves no chat completions.

Judgment has two backends, and the difference is part of the result:

| backend | what it is | what it guarantees |
|---|---|---|
| `typesafeTyped` | the typed System One API, `POST /v1/systemone` | calibrated answers with probabilities and confidence |
| `llmJSON` | a chat model prompted for the same JSON shape | typed, **uncalibrated** — an answer that omits `confidence` is recorded as 0 and escalates instead of being acted on |

`Copilot.run` is the product's identity in one call: judge first (four independent questions in
one request), draft only when the judgment says a reply is due, then score every candidate on one
dimension so the ranking is comparable and re-rankable without re-running inference. Whatever is
too flat or too risky comes back as an `Escalation` (`.highRisk`, `.verificationRequired`,
`.lowConfidence`) instead of a guess.

## Verified, not assumed

`swift test` runs **62 tests** (3 of them live-API checks that skip without a key):

### Capture stage

1. **Parity (25 fixtures).** `make_fixtures.py` in the spike workspace runs the validated Python
   reference over 12 screenshots × two recognisers (Apple Vision and Windows OCR) *plus* a 1x
   capture where avatar artwork really was recognised as text. The Swift port must reproduce the
   reference's bubbles **and** its dropped-chrome classification exactly. A port bug cannot hide
   behind "the engine behaves differently".
2. **Rule tests.** One test per rule that cost real debugging, asserted directly so a future
   "simplification" fails loudly.

### Decision stage

Stubbed transport, no network: the exact request shape (path, headers, body — including the
`choice` criteria being a `key=description` map), response decoding (noul/score/choice with
probabilities, legend and confidence), every error path (401/403, a provider's "product is not
activated" 400, malformed bodies, unreachable hosts), route inheritance, question validation, and
the copilot's ordering + escalation rules.

`LiveAPITests` re-run the Phase 0 verdict against the real API when `TYPESAFE_API_KEY` is present:
the scam transcript must come back `intent = scam` with `danger >= 2.5`, the boundary-holding
reply must outrank the one that pays up, and an ordinary work chat must not be flagged. Add the
key as a repository secret and they run in CI instead of skipping.

| | pipeline-pass | fully clean |
|---|---|---|
| Apple Vision | 12/12 | 12/12 |
| Windows OCR baseline | 12/12 | 10/12 |

Rules that exist because of a measured failure — full reasoning in the spike workspace's
`PORT_SPEC.md`:

- **R5 adaptive merge threshold.** Apple Vision's ink boxes are ~25% taller than Windows OCR's
  for identical text (59px vs 47px at 3x). A fixed `1.9 × median line height` merged three
  bubbles into one under Vision. Cut at the largest relative jump in the sorted per-side gap
  distribution instead: it computes 55.3px for Vision and 88.5px for Windows on the *same*
  screen.
- **R6 font size from advance width, never ink height.** Full-width punctuation inflates a box
  until a 12pt quote line measures *taller* than 16pt body text; and a lone character's box
  carries too much padding to measure, so only multi-character lines feed the median.
- **R5c orphan absorption.** Vision splits a wrapped trailing fragment onto its own line
  ("…审批流程" → "…审批流" + a lone "程"); the fragment's centre falls on the left half of the
  screen and it would be attributed to the wrong person.
- **R3 a single CJK character is a message** ("行", "好"), so the artwork filter keys on glyph
  shape and a tiny box near the avatar rail — never on text length alone.
- **R1b notification banners** are read by Vision but sit below the nav-band cutoff, so in the top
  30% of the screen anything starting left of `0.15*W` is chrome.
- **Never downscale.** Native 3x: 9/9 bubbles, 97.7% char accuracy. The same page at 1x: 16
  bubbles (7 read out of the avatar squares), 86.9%.

## Run it

```bash
swift build -c release
swift test                                  # parity + rule tests
.build/release/visionlines shots vision_out # measure the recogniser on the corpus
```

CI (`.github/workflows/swift.yml`, `macos-14`) runs the build, the tests and the Vision pass,
publishing the recognised line boxes as the `vision-ocr-json` artifact. Those artifacts are
scored in the spike workspace with the same evaluator and ground truth:

```bash
python run_corpus.py --ocr-files vision_out   # parity table vs the Windows baseline
```

No Mac required — a runner is enough.

## Next

Phase 1 continues in the app: `ScreenshotImporter` (photo library / share sheet / screenshot
detected) → this segmenter → `JudgeClient` (TypeSafe Jev for intent, risk and whether to reply
now, plus a reply route) → keyboard extension for one-tap insertion via `textDocumentProxy`.
On-device: knowledge base and contacts in an App Group container, keys in the Keychain.