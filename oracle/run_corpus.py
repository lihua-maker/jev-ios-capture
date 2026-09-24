#!/usr/bin/env python3
"""Drive the whole corpus: spec -> HTML -> Chrome screenshot (native 3x) -> offline OCR -> eval."""
import json, subprocess, sys
from pathlib import Path
import corpus, capture

HERE = Path(__file__).parent
CHROME = r"C:\Program Files\Google\Chrome\Application\chrome.exe"
PS = "powershell.exe"

def shoot(html_path: Path, png: Path, w: int, h: int):
    subprocess.run([CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars",
                    "--force-device-scale-factor=3", f"--window-size={w},{h}",
                    f"--screenshot={png.as_posix()}", f"file:///{html_path.as_posix()}"],
                   check=True, capture_output=True, timeout=120)

def ocr(png: Path, out: Path):
    r = subprocess.run([PS, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
                        str(HERE / "ocr.ps1"), "-Image", png.as_posix(), "-Out", out.as_posix()],
                       capture_output=True, text=True, timeout=180)
    if r.returncode != 0:
        raise RuntimeError(r.stderr[-400:])
    return json.loads(out.read_text(encoding="utf-8"))

def main(only=None, ocr_files=None, tag=None):
    """ocr_files=<dir>: evaluate pre-existing <scenario_id>.ocr.json files instead of
    rendering + OCR-ing locally. That is the Vision-parity path: a macOS CI runner produces
    Apple Vision line boxes for the same PNGs, they are dropped in a folder here, and the
    same evaluator compares them against the Windows baseline."""
    results = []
    baseline = {}
    if ocr_files:
        bp = HERE / "corpus_report.json"
        if bp.exists():
            baseline = {r["id"]: r for r in json.loads(bp.read_text(encoding="utf-8"))}
    for sc in corpus.SCENARIOS:
        if only and sc["id"] not in only: continue
        doc_path = Path(ocr_files) / f"{sc['id']}.ocr.json" if ocr_files else None
        if ocr_files:
            if not doc_path.exists():
                print(f"SKIP  {sc['id']:<26} (no {doc_path.name} in {ocr_files})")
                continue
            doc = json.loads(doc_path.read_text(encoding="utf-8"))
            _html, gt = corpus.build_html(sc)
        else:
            html, gt = corpus.build_html(sc)
            hp = HERE / "out" / f"{sc['id']}.html"; png = HERE / "out" / f"{sc['id']}.png"
            hp.parent.mkdir(exist_ok=True)
            hp.write_text(html, encoding="utf-8")
            shoot(hp, png, sc["width"], sc["height"])
            doc = ocr(png, HERE / "out" / f"{sc['id']}.ocr.json")
        res = capture.evaluate(doc, gt)
        res.update(id=sc["id"], size=f"{doc['width']}x{doc['height']}",
                   skin=sc["skin"], gt_bubbles=len(gt["bubbles"]), gt_no_text=len(gt["no_text"]))
        results.append(res)
        flag = "PASS" if res["clean"] else ("PASS" if res["ok"] else "FAIL")
        tag = "" if res["clean"] else ("  [recall gap]" if res["ok"] else "")
        print(f"{flag}  {sc['id']:<26} bubbles {res['bubbles']}/{res['effective']} (gt {res['expected']})  "
              f"sender {res['sender_ok']}  charc {res['char_accuracy']}  sim {res['mean_sim']}  "
              f"quote {res['quote_sim']}  leaks {res['chrome_leaks']}  iconhalluc {res['icon_hallucinations']}  "
              f"labels {res['sender_labels']}{tag}")
        for f in res["fails"][:6]:
            print(f"        ! {f}")
        for m in res["recall_misses"]:
            print(f"        ~ recogniser missed a whole bubble: {m['sender']} {m['gt']!r}")
        for d in res["deltas"][:4]:
            print(f"        - {d}")
    rep = (HERE / (f"corpus_report_{Path(ocr_files).name}.json" if ocr_files else "corpus_report.json"))
    rep.write_text(json.dumps(results, ensure_ascii=False, indent=2), encoding="utf-8")
    if ocr_files and baseline:
        print(f"\n{'scenario':<26}{'win chars':>10}{'this run':>10}{'win bub':>9}{'run bub':>9}")
        for r in results:
            b = baseline.get(r["id"])
            if not b: continue
            print(f"{r['id']:<26}{b['char_accuracy']:>10}{r['char_accuracy']:>10}"
                  f"{b['bubbles']:>9}{r['bubbles']:>9}")
    ok = sum(1 for r in results if r["ok"])
    clean = sum(1 for r in results if r["clean"])
    print(f"\npipeline-pass {ok}/{len(results)}   fully-clean {clean}/{len(results)}")
    return ok, len(results)

if __name__ == "__main__":
    args = sys.argv[1:]
    files = None
    if "--ocr-files" in args:
        i = args.index("--ocr-files"); files = args[i + 1]; del args[i:i + 2]
    main(args or None, ocr_files=files)