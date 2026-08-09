#!/usr/bin/env bash
# Deploy the pinned Berry VM used by the characterization test suite.
#
# Pinned versions (see tests.md):
#   Berry   v1.1.0   https://github.com/berry-lang/berry.git  (tag v1.1.0)
#   build   via repository Makefile (gcc + libreadline), no cmake required
#   python3 >= 3      tests/build.py, run_all.py
#
# Berry v1.1.0 has no CMakeLists.txt; it builds with `make` (src + default/).
# Source goes to ${HOME}/.local/src/berry, binary is installed to
# ${HOME}/.local/bin/berry (persistent, NOT /tmp, survives reboots).
#
# Test runner looks for the binary first in PATH (see tests/run_all.py,
# tests/build.py), so ensure ${HOME}/.local/bin is in PATH.
#
# Usage:  bash tests/setup_berry.sh
set -euo pipefail

BERRY_REPO="https://github.com/berry-lang/berry.git"
BERRY_REF="v1.1.0"                 # pinned
SRC_DIR="${HOME}/.local/src/berry"
BIN_DIR="${HOME}/.local/bin"
BIN_PATH="${BIN_DIR}/berry"

if command -v cmake >/dev/null 2>&1; then
    echo "[berry] cmake available (not required for v1.1.0): $(cmake --version | head -1)"
fi
if ! command -v python3 >/dev/null 2>&1; then
    echo "[berry] ERROR: python3 is required." >&2
    exit 1
fi

echo "[berry] pinning ${BERRY_REPO}#${BERRY_REF}"
if [ -d "${SRC_DIR}/.git" ]; then
    echo "[berry] updating existing checkout at ${SRC_DIR}"
    git -C "${SRC_DIR}" fetch --tags --force origin
    git -C "${SRC_DIR}" checkout --force "${BERRY_REF}"
else
    echo "[berry] cloning ${BERRY_REPO}"
    git clone "${BERRY_REPO}" "${SRC_DIR}"
    git -C "${SRC_DIR}" checkout --force "${BERRY_REF}"
fi

echo "[berry] building with make (${SRC_DIR})"
make -C "${SRC_DIR}" -j"$(nproc)" >/dev/null

mkdir -p "${BIN_DIR}"
install -m 755 "${SRC_DIR}/berry" "${BIN_PATH}"
echo "[berry] installed ${BIN_PATH}"
"${BIN_PATH}" -v

echo "[berry] done. Verify with: python3 tests/run_all.py"
echo "[berry] NOTE: add ${BIN_DIR} to PATH (e.g. export PATH=\${HOME}/.local/bin:\$PATH)"