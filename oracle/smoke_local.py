"""Local smoke test for render_parity.py: real Chrome render, stubbed recogniser.

Exercises find_chrome -> shoot -> PNG header check -> batch recognise -> metrics -> metrics.json
without needing a macOS Vision binary. Run from the oracle/ directory.
"""
import json
import shutil
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import render_parity as rp

SPIKE = Path(__file__).resolve().parent.parent.parent / "out"     # the Windows reference run


def fake_batch(_visionlines, in_dir: Path, out_dir: Path):
    """Stand in for Apple Vision by reusing the Windows OCR of the same HTML."""
    for png in sorted(Path(in_dir).glob("*.png")):
        src = SPIKE / f"{png.stem}.ocr.json"
        shutil.copyfile(src, Path(out_dir) / f"{png.stem}.ocr.json")
    return f"stub: recognised {len(list(Path(in_dir).glob('*.png')))} images"


rp.recognise_batch = fake_batch
sys.argv = ["render_parity.py", "--out", "C:/Users/xiaodongyu/AppData/Local/Temp/smoke2",
            "--only", "s01_1v1_light_short", "s11_narrow_dark_group", "s12_wide_light_long"]
rp.main()
print("smoke ok")