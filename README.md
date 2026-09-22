# vision-parity — Apple Vision vs the offline-OCR baseline

A macOS CI runner has the **real** `VNRecognizeTextRequest`. This repo runs it over a fixed
set of screenshots and publishes the line boxes as an artifact, so the iOS capture rules can
be validated without owning a Mac.

Part of the iOS port of **jev-chat-jarvis** (a chat copilot that reads the conversation on
screen, judges it, and drafts replies). Phase 0 established that stock iOS cannot read other
apps' UI, so on iOS the screen arrives as a user screenshot and the text recogniser is the
whole capture stage.

## What it does

`Sources/visionlines/main.swift` runs Vision over every image in `shots/` and writes
`<name>.ocr.json` per screenshot, in the same shape the Windows baseline uses:

```json
{"width":1170,"height":2532,"engine":"apple-vision",
 "lines":[{"text":"小陈，在吗？","x":217.0,"y":465.0,"w":262.0,"h":47.0,"conf":0.9}]}
```

`x`/`y` are the **top-left corner in pixels** (Vision's `boundingBox` is normalised with a
bottom-left origin — the code flips it). `conf` is the per-line confidence the iOS pipeline
needs for its "this bubble could not be read" path; the evaluator ignores unknown keys.

## Run it

```bash
gh workflow run vision-parity
gh run watch
gh run download -n vision-ocr-json -D vision_out
```

Then, back in the spike workspace (which holds the evaluator, ground truth and the Windows
baseline):

```bash
python run_corpus.py --ocr-files vision_out
```

That prints a per-scenario parity table — Windows chars vs Vision chars, bubbles vs bubbles —
and the same pipeline gate the Windows run is judged by.

## The screenshots

`shots/` is 12 synthetic chat screenshots rendered at native iPhone resolution (3x) with
ground truth generated from the same spec, covering: 1v1 and group chats, light and dark
mode, WeChat and QQ skins, wrapped long bubbles, quoted replies, transfer cards, images and
voice messages (which must yield no text bubble), a notification banner, an unread badge, a
typing indicator, and 375/390/430pt widths.

They are synthetic. Real screenshots get swapped in as they become available — the parity
table is only as representative as `shots/`.

## Baseline to beat (Windows.Media.Ocr, zh-Hans-CN, same evaluator)

| Metric | Value |
|---|---|
| pipeline-pass | 12/12 scenarios |
| fully-clean (no recogniser recall gap) | 10/12 |
| char accuracy, native resolution | 0.96 – 1.00 |
| downscaled to 1x | 0.87, plus 7 fake bubbles read out of avatar squares → **never downscale** |

Two known recall gaps in the baseline are single-CJK-character bubbles ("好", "行") that the
recognition engine missed entirely. Whether Vision does better on those is one of the things
this run answers.