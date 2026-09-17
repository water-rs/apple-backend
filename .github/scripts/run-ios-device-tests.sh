#!/usr/bin/env bash
# Runs the WaterUITests suite on an iOS simulator, optionally with a real
# WaterUI application archive linked into the test bundle.
#
# The package resolves waterui_* symbols by dynamic lookup, so the
# device-backed tests (DeviceHostedApp) can drive a real application only
# when an example's Rust archive is linked into the test bundle. This script
# builds one with the `water` CLI against a staged waterui checkout and hands
# it to `xcodebuild test`.
#
# Usage:
#   WATERUI_DIR=<staged waterui checkout> run-ios-device-tests.sh <example> [simulator-udid]
#
#   <example>   a project under ${WATERUI_DIR}/examples (e.g. reminders,
#               navigation), or `ios_test_host` — this repository's own
#               fixture (Tests/IOSTestHost), staged into the framework's
#               examples tree the way setup-e2e.sh stages Examples/*.
#
# With no example the suite still runs; the archive-backed tests skip.
#
# Prerequisites: a staged checkout — see setup-e2e.sh, which clones waterui,
# replaces backends/apple with this repository's tree, and syncs the FFI
# header — and the `water` CLI on PATH.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
simulator_udid="${2:-${SIMULATOR_UDID:-}}"
if [[ -z "${simulator_udid}" ]]; then
  simulator_udid="$(xcrun simctl list devices available \
    | awk -F '[()]' '/iPhone/ {print $2; exit}')"
fi
if [[ -z "${simulator_udid}" ]]; then
  echo "error: no available iPhone simulator" >&2
  exit 1
fi

ldflags="-Xlinker -undefined -Xlinker dynamic_lookup"
archive=""

if [[ $# -ge 1 ]]; then
  example="$1"
  waterui_dir="${WATERUI_DIR:?WATERUI_DIR must name the staged waterui checkout}"
  example_path="${waterui_dir}/examples/${example}"
  if [[ "${example}" == "ios_test_host" && ! -f "${example_path}/Water.toml" ]]; then
    cp -R "${repo_root}/Tests/IOSTestHost" "${example_path}"
  fi
  [[ -f "${example_path}/Water.toml" ]] || {
    echo "error: no example at ${example_path}" >&2; exit 1; }

  water package --platform ios-simulator --backend apple --path "${example_path}"
  archive="$(find "${waterui_dir}/target/water-backends/static/aarch64-apple-ios-sim/debug" \
    -maxdepth 1 -name "lib*_ffi.a" -print -quit)"
  [[ -n "${archive}" ]] || {
    echo "error: no lib*_ffi.a archive produced for ${example}" >&2; exit 1; }
  ldflags="${ldflags} ${archive}"
fi

derived_data="${DERIVED_DATA_PATH:-$(mktemp -d)/DerivedData}"

status=0
xcodebuild test \
  -scheme WaterUITests \
  -destination "platform=iOS Simulator,id=${simulator_udid}" \
  -derivedDataPath "${derived_data}" \
  OTHER_LDFLAGS="${ldflags}" || status=$?

if [[ ${status} -eq 0 && -n "${archive}" ]]; then
  # The DeviceHostedApp cases bind `waterui_app` through dynamic lookup, so a
  # staging failure that drops the archive still produces a green suite —
  # those tests simply skip. Assert the symbol actually landed in the built
  # test bundle rather than trusting that OTHER_LDFLAGS was honoured.
  xctest_bundle="$(find "${derived_data}/Build/Products" \
    -maxdepth 2 -name '*.xctest' -print -quit)"
  [[ -n "${xctest_bundle}" ]] || {
    echo "error: no .xctest bundle under ${derived_data}/Build/Products" >&2
    exit 1
  }
  xctest_bin="${xctest_bundle}/$(basename "${xctest_bundle}" .xctest)"
  # `grep -q` exits on the first match and closes the pipe under nm, which
  # then dies with "LLVM ERROR: IO failure on output stream: Broken pipe";
  # with `pipefail` that reports a linked bundle as unlinked. Let grep read
  # nm's whole output instead.
  nm -gU "${xctest_bin}" | grep ' _waterui_app$' >/dev/null || {
    echo "error: waterui_app is not linked into ${xctest_bundle};" \
      "the archive-backed tests skipped" >&2
    exit 1
  }
fi

exit "${status}"
