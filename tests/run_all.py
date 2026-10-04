#!/usr/bin/env python3
"""Run all characterization test cases and print a summary.

Usage:
  python3 tests/run_all.py [berry_path]
"""
import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CASES = sorted((ROOT / "tests" / "cases").glob("*.be"))
build = ROOT / "tests" / "build.py"

def find_berry() -> Path:
    """Explicit argv > $BERRY_BIN > PATH (setup_berry.sh installs to ~/.local/bin)."""
    if len(sys.argv) > 1:
        return Path(sys.argv[1])
    env = Path(os.environ.get("BERRY_BIN", ""))
    if str(env) != "." and env.name:
        return env
    found = shutil.which("berry")
    if found:
        return Path(found)
    installed = Path.home() / ".local" / "bin" / "berry"
    if installed.exists():
        return installed
    legacy = Path("/tmp/opencode/berry/build/berry")
    if legacy.exists():
        return legacy
    sys.exit("berry VM not found. Deploy it first: bash tests/setup_berry.sh")

def run_case(case: Path, berry: Path) -> tuple[int, str, int]:
    r = subprocess.run(
        [sys.executable, str(build), str(case), str(berry)],
        capture_output=True, text=True)
    out = r.stdout + r.stderr
    passes = out.count("PASS:")
    fails = out.count("FAIL:")
    # crash detection: exit code != 0 or unhandled traceback
    crashed = r.returncode != 0 and "caught:" not in out
    return r.returncode, out, passes, fails, crashed

if __name__ == "__main__":
    berry = find_berry()
    total_pass = total_fail = 0
    for case in CASES:
        rc, out, p, f, crashed = run_case(case, berry)
        total_pass += p
        total_fail += f
        status = "OK " if not crashed and f == 0 and rc == 0 else "FAIL"
        print(f"{status} {case.name}: PASS={p} FAIL={f} rc={rc} crashed={crashed}")
    print(f"\nTOTAL: PASS={total_pass} FAIL={total_fail}")
    sys.exit(0 if total_fail == 0 else 1)