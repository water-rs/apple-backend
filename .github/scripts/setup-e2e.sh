#!/usr/bin/env bash
# Prepares a waterui checkout for driving the examples: clones waterui at the
# ref matching the current flow (main for main-gate, dev otherwise), initializes
# the submodules example builds resolve (`kit` and `utils/nami` are workspace
# members, so cargo cannot even read the workspace without them), and replaces
# `backends/apple` with this repository's tested tree so the suite exercises the
# commit under test rather than the submodule waterui has pinned. The committed
# FFI header is then synced from the cloned waterui, matching what
# `setup-waterui.sh` does for the package build legs.
set -euo pipefail

repo_root="${GITHUB_WORKSPACE:-$(pwd)}"
waterui_dir="${repo_root}/waterui"

if [[ -n "${WATERUI_REF:-}" ]]; then
  waterui_ref="${WATERUI_REF}"
elif [[ "${GITHUB_BASE_REF:-}" == "main" || "${GITHUB_REF_NAME:-}" == "main" ]]; then
  waterui_ref="main"
else
  waterui_ref="dev"
fi

echo "Using waterui ref: ${waterui_ref}"
rm -rf "${waterui_dir}"
git clone --depth 1 --branch "${waterui_ref}" https://github.com/water-rs/waterui.git "${waterui_dir}"
git -C "${waterui_dir}" submodule update --init --depth 1 kit utils/nami

# `backends/apple` is consumed by example builds as a SwiftPM path dependency,
# not through git; replacing the directory wholesale with the tested tree is
# the whole point of the suite.
rm -rf "${waterui_dir}/backends/apple"
mkdir -p "${waterui_dir}/backends/apple"
git -C "${repo_root}" archive HEAD | tar -x -C "${waterui_dir}/backends/apple"

# The Rust library the examples link is waterui's own checkout; the Swift side
# must see its declarations, not the snapshot the backend repo last synced.
cp "${waterui_dir}/ffi/waterui.h" "${waterui_dir}/backends/apple/Sources/CWaterUI/include/waterui.h"

if [[ -n "${GITHUB_ENV:-}" ]]; then
  {
    echo "WATERUI_DIR=${waterui_dir}"
    echo "WATERUI_REF=${waterui_ref}"
  } >> "${GITHUB_ENV}"
fi
