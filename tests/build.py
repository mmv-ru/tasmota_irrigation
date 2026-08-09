#!/usr/bin/env python3
"""Build a combined Berry test script and run it with a local berry binary.

Usage:
  python3 tests/build.py <case.be> [berry_path]

Assembles: harness_header.be + watering.be + <case.be> and runs berry.
Module .be files are copied next to the combined script so `import` resolves.
"""
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TESTS = ROOT / "tests"
OUT = TESTS / "out"
BERRY = Path(sys.argv[2]) if len(sys.argv) > 2 else Path("/tmp/opencode/berry/berry")
CASE = TESTS / "cases" / sys.argv[1] if not (TESTS / "cases" / sys.argv[1]).exists() else Path(sys.argv[1])

def build(case_path: Path) -> Path:
    OUT.mkdir(exist_ok=True)
    combined = OUT / "combined.be"
    header = (TESTS / "harness_header.be").read_text()
    watering = (ROOT / "watering.be").read_text()
    case = case_path.read_text()
    combined_text = "\n".join([header, watering, case])
    combined_text = combined_text.replace("\ufeff", "")
    combined.write_text(combined_text)
    # copy module stubs next to test script
    for m in (TESTS / "modules").iterdir():
        shutil.copy(m, OUT / m.name)
    return combined

if __name__ == "__main__":
    case_path = Path(sys.argv[1])
    combined = build(case_path)
    r = subprocess.run([str(BERRY), str(combined)], capture_output=True, text=True)
    sys.stdout.write(r.stdout)
    sys.stderr.write(r.stderr)
    sys.exit(r.returncode)