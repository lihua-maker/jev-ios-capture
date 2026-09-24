#!/usr/bin/env python3
"""Render the corpus with THIS machine's fonts and recognise it with THIS machine's OCR.

Why this exists: the rules in capture.py are driven by text metrics, and text metrics ARE font
metrics. The reference corpus is rendered on Windows in Microsoft YaHei; an iPhone renders in
PingFang SC. Rather than trust that the difference does not matter, the same HTML is rendered here
(Chrome picks PingFang SC from the font stack automatically), recognised with Apple Vision, and
scored by the same evaluator against the same ground truth:

  python3 oracle/render_parity.py --out /tmp/renders --visionlines .build/release/visionlines
  python3 oracle/run_corpus.py --ocr-files /tmp/renders

Exit code is non-zero if a render is not native 3x, because a resampled render would make every
metric below meaningless while still producing a plausible looking report.
"""
import argparse
import json
import statistics
import struct
import subprocess
import sys
from pathlib import Path
from shutil import which

import capture
import corpus

HERE = Path(__file__).parent
CHROME_CANDIDATES = [
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",          # runner
    "/Applications/Chromium.app/Contents/MacOS/Chromium",
    r"C:\Program Files\Google\Chrome\Application\chrome.exe",                # reference box
    "google-chrome",
    "chromium",
]


def find_chrome() -> str:
    for c in CHROME_CANDIDATES:
        if c.startswith("/") or ":\\" in c:
            if Path(c).exists():
                return c
        found = which(c)
        if found:
            return found
    sys.exit("no Chrome found; install it with `brew install --cask google-chrome`")


def shoot(chrome: str, html: Path, png: Path, w: int, h: int) -> None:
    subprocess.run([chrome, "--headless=new", "--disable-gpu", "--hide-scrollbars",
                    "--force-device-scale-factor=3", f"--window-size={w},{h}",
                    f"--screenshot={png}", f"file://{html}"],
                   check=True, capture_output=True, timeout=240)


def png_size(png: Path):
    """PNG header (IHDR) — no image library available, and none needed."""
    with png.open("rb") as fh:
        head = fh.read(24)
    if head[:8] != b"\x89PNG\r\n\x1a\n":
        sys.exit(f"{png} is not a PNG")
    return struct.unpack(">II", head[16:24])


def recognise_batch(visionlines: str, in_dir: Path, out_dir: Path) -> str:
    """visionlines is a folder-at-a-time tool: <in-dir> <out-dir>, emitting <stem>.ocr.json."""
    r = subprocess.run([visionlines, str(in_dir), str(out_dir)],
                       capture_output=True, text=True, timeout=900)
    if r.returncode != 0:
        sys.exit(f"visionlines failed (exit {r.returncode}): {r.stdout[-400:]} {r.stderr[-400:]}")
    return r.stdout.strip()


def metrics(doc: dict) -> dict:
    """The two numbers the segmentation rules actually key off, so a font change is visible."""
    steps = [capture.advance(l) for l in doc["lines"] if len(capture.norm(l["text"])) >= 4]
    heights = [l["h"] for l in doc["lines"]]
    return {
        "median_step": round(statistics.median(steps), 1) if steps else None,
        "median_h": round(statistics.median(heights), 1) if heights else None,
        "lines": len(doc["lines"]),
    }


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="/tmp/corpus_macos", help="where PNGs and .ocr.json go")
    ap.add_argument("--visionlines", default=".build/release/visionlines")
    ap.add_argument("--only", nargs="*", help="scenario ids")
    args = ap.parse_args()

    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)
    chrome = find_chrome()
    baseline_path = HERE / "win_metrics.json"
    baseline = json.loads(baseline_path.read_text(encoding="utf-8")) if baseline_path.exists() else {}

    print(f"renderer: {chrome}")
    rendered, bad = [], []
    for sc in corpus.SCENARIOS:
        if args.only and sc["id"] not in args.only:
            continue
        html_text, _gt = corpus.build_html(sc)
        html = out_dir / f"{sc['id']}.html"
        png = out_dir / f"{sc['id']}.png"
        html.write_text(html_text, encoding="utf-8")
        shoot(chrome, html, png, sc["width"], sc["height"])

        got_w, got_h = png_size(png)
        want = (sc["width"] * 3, sc["height"] * 3)
        if (got_w, got_h) != want:
            bad.append(f"{sc['id']}: rendered {got_w}x{got_h}, expected {want[0]}x{want[1]}")
        rendered.append((sc, png, got_w, got_h))

    if bad:
        print("\nNATIVE-RESOLUTION FAILURES (metrics below would be meaningless):")
        for b in bad:
            print("  " + b)
        sys.exit(1)

    print(recognise_batch(args.visionlines, out_dir, out_dir))

    print(f"\n{'scenario':<26}{'png':>12}{'chars':>7}{'step':>8}{'win step':>10}{'delta':>8}{'h':>6}{'win h':>7}")
    summary = {}
    for sc, _png, got_w, got_h in rendered:
        doc = json.loads((out_dir / f"{sc['id']}.ocr.json").read_text(encoding="utf-8"))
        m = metrics(doc)
        base = baseline.get(sc["id"], {})
        delta = ""
        if base.get("median_step") and m["median_step"]:
            delta = f"{(m['median_step'] / base['median_step'] - 1) * 100:+.1f}%"
        summary[sc["id"]] = {**m, "png": f"{got_w}x{got_h}", "win_step": base.get("median_step")}
        print(f"{sc['id']:<26}{f'{got_w}x{got_h}':>12}{m['lines']:>7}{m['median_step']:>8}"
              f"{base.get('median_step', ''):>10}{delta:>8}{m['median_h']:>6}{base.get('median_h', ''):>7}")

    (out_dir / "metrics.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2),
                                         encoding="utf-8")
    steps = [v["median_step"] for v in summary.values() if v["median_step"]]
    if steps:
        print(f"\nmedian character step here: {statistics.median(steps)}")
        if baseline:
            win = statistics.median([v["median_step"] for v in baseline.values() if v.get("median_step")])
            print(f"median character step on Windows: {win}  "
                  f"({(statistics.median(steps) / win - 1) * 100:+.1f}%)")


if __name__ == "__main__":
    main()