"""Local smoke test for render_parity.py: real Chrome render, stubbed recogniser.

Exercises find_chrome -> shoot -> PNG header check -> metrics -> metrics.json, without needing a
macOS Vision binary. Run from the oracle/ directory.
"""
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import render_parity as rp

SPIKE = Path(__file__).resolve().parent.parent.parent / "out"     # the Windows reference run


def fake_recognise(_visionlines, png, out):
    """Stand in for Apple Vision by reusing the Windows OCR of the same HTML."""
    doc = json.loads((SPIKE / f"{png.stem}.ocr.json").read_text(encoding="utf-8"))
    out.write_text(json.dumps(doc), encoding="utf-8")
    return doc


rp.recognise = fake_recognise
sys.argv = ["render_parity.py", "--out", "C:/Users/xiaodongyu/AppData/Local/Temp/smoke",
            "--only", "s01_1v1_light_short", "s11_narrow_dark_group", "s12_wide_light_long"]
rp.main()
print("smoke ok")