#!/usr/bin/env python3
"""Byte-compare a golden case's stdout against its committed baseline.

Usage: python3 tests/golden.py [case.be ...]   (default: both golden cases)
Exits 0 when every snapshot matches, 1 on any diff (and prints the diff).
"""
import difflib
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TESTS = ROOT / "tests"

# What the user actually asked for, captured before argv gets padded below.
USER_CASES = sys.argv[1:]

# tests/build.py reads sys.argv[1] in module-level code (line 43), so importing
# it as a module crashes without an argument. Seed argv with a real case name
# before the import; build.CASE is never used by build.build().
if len(sys.argv) < 2:
    sys.argv.append("90_golden_web.be")
sys.path.insert(0, str(TESTS))
import build  # noqa: E402

CASES = {
    "90_golden_web.be": TESTS / "golden" / "web.out",
    "91_golden_service.be": TESTS / "golden" / "service.out",
}


def snapshot(case_name):
    """Run one golden case and return its stdout.

    build.build() prints its staging line to *this* process's stdout, which is
    not part of the compared stream - the comparison uses the berry output only.
    """
    combined = build.build(TESTS / "cases" / case_name)
    berry = build.find_berry()
    r = subprocess.run([str(berry), str(combined)], capture_output=True, text=True)
    if r.returncode != 0:
        print(f"{case_name}: berry exited {r.returncode}\n{r.stderr}")
        return None
    return r.stdout


def main():
    cases = USER_CASES or list(CASES)
    failed = False
    for case_name in cases:
        baseline = CASES[case_name]
        got = snapshot(case_name)
        if got is None:
            failed = True
            continue
        if not baseline.exists():
            baseline.write_text(got)
            print(f"{case_name}: baseline created ({len(got)} bytes)")
            continue
        want = baseline.read_text()
        if got == want:
            print(f"{case_name}: OK ({len(got)} bytes identical)")
            continue
        failed = True
        print(f"{case_name}: MISMATCH")
        sys.stdout.writelines(difflib.unified_diff(
            want.splitlines(True), got.splitlines(True),
            fromfile=str(baseline), tofile="actual"))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()