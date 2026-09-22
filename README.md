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

## Result — run 35735396725 (first attempt, green)

Vision ran over all 12 shots and the artifacts were scored with the same evaluator and ground
truth as the Windows baseline:

| | pipeline-pass | fully clean | single-char bubbles | dark-mode sender labels | notification banner |
|---|---|---|---|---|---|
| **Apple Vision** | **12/12** | **12/12** | all read | **2/2** | read (must be filtered) |
| Windows.Media.Ocr | 12/12 | 10/12 | missed in 2/12 | 0/2 | missed |

**Vision's first run scored 6/12, and every failure was a bug in the capture rules — not in
Vision.** Vision is not "worse": its ink boxes are ~25% taller for the same text (59px vs 47px
for 16pt at 3x), which changes every gap in the layout. Three rules had been implicitly tuned to
one recogniser's metrics:

1. A fixed `1.9 × median_line_height` merge threshold became too permissive and merged three
   bubbles into one. → **Adaptive split**: cut at the largest relative jump in the sorted
   per-side gap distribution (Vision computes 55.3px, Windows 88.5px on the same screen — both
   correct for their own metrics).
2. Vision splits a wrapped trailing character onto its own line, and a lone character's box is
   too padded to estimate font size from. → **Font size from the median advance of
   multi-character lines only**, plus **orphan absorption**: a lone short line whose left edge
   matches the bubble above merges back into it (the fragment's centre fell on the wrong half of
   the screen and it was attributed to the wrong person).
3. Vision reads notification banners that other engines miss, and a banner's text sits *below*
   the nav-bar band. → New rule: in the top 30% of the screen, any line starting left of
   `0.15*W` is banner chrome (bubble ink starts at ~0.185\*W, banner text at ~0.137\*W).

After the fix the **same** segmenter scores 12/12 on both engines. The rules are now
engine-independent geometry, which is exactly what the Swift port implements.

Vision's real advantages, worth designing for: no single-character dropouts, readable
low-contrast labels, and it reads overlay chrome — so the banner filter is mandatory rather than
optional. Its downside is that "what counts as one box" is looser, which is why the adaptive
rules above are required.