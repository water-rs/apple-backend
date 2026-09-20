#!/usr/bin/env bash
# TEMPORARY #256 diagnostic — exists only on this branch and is removed, with
# the `twin_probe` workflow_dispatch input, before the PR leaves draft.
#
# Runs on a bare macos-26 runner (no waterui checkout, no packaged example):
# installs the SwiftUI reference host the workflow already built, launches it
# for PROBE_EXAMPLE with the dev.waterui marker stream attached — the same
# attach order capture_reference uses — and captures one frame every
# PROBE_INTERVAL_S for PROBE_SECONDS starting at launch, so the twin's
# materialisation arc is measured on the runners that reproduce the failure
# rather than extrapolated from a local machine.
#
# Artifact layout under PROBE_OUT: frames/frame-NNN.png (every capture),
# marker.log (the marker stream, plus a `log show` fallback if the stream
# missed the marker), and timeline.tsv with per-frame t_since_launch_s,
# t_since_marker_s, diff_vs_previous and diff_vs_final.
#
# Env: PROBE_EXAMPLE (twin name), PROBE_APP (.app path), PROBE_OUT (artifact
# dir), SIMULATOR_UDID (booted device), PROBE_SECONDS (default 120),
# PROBE_INTERVAL_S (default 1).
set -euo pipefail

example="${PROBE_EXAMPLE:?PROBE_EXAMPLE is required}"
app="${PROBE_APP:?PROBE_APP is required}"
out="${PROBE_OUT:?PROBE_OUT is required}"
: "${SIMULATOR_UDID:?SIMULATOR_UDID is required}"
seconds="${PROBE_SECONDS:-120}"
interval="${PROBE_INTERVAL_S:-1}"
workspace="${GITHUB_WORKSPACE:-$(pwd)}"
frames_dir="${out}/frames"
marker_log="${out}/marker.log"
scratch="${out}/.scratch"
mkdir -p "${frames_dir}" "${scratch}"

# Reuse the shard's own capture path: the definition is lifted out of
# run-e2e-shard.sh rather than retyped — the script cannot be sourced whole
# (sourcing would run the shard), so the function body is extracted and
# eval'd verbatim.
eval "$(sed -n '/^capture_frame()/,/^}/p' "${workspace}/.github/scripts/run-e2e-shard.sh")"
if ! declare -F capture_frame >/dev/null; then
  echo "::error::capture_frame was not found in run-e2e-shard.sh; the probe cannot reuse it."
  exit 1
fi
# platform selects capture_frame's simctl branch; app_pid is its default
# window pid (macOS only) and just has to be bound.
# shellcheck disable=SC2034 # both are read inside the eval'd capture_frame
platform="ios" app_pid=""

# compare-screenshots.swift compiled once: ~2N interpreter runs would each
# pay a frontend start-up. swiftc only accepts top-level code in a file
# named main.swift, hence the copy.
cp "${workspace}/.github/scripts/compare-screenshots.swift" "${scratch}/main.swift"
swiftc -O "${scratch}/main.swift" -o "${scratch}/compare"

# Fraction of pixels differing between two frames, or "-" when the compare
# could not run (a failed capture leaves no PNG).
compare_fraction() {
  local result
  result="$(DIFF_BUDGET=1.0 "${scratch}/compare" compare "$1" "$2" \
    "${scratch}/diff.png" 2>&1)" || true
  result="$(sed -n 's/^compare: \([0-9.]*\).*/\1/p' <<<"${result}" | head -1)"
  printf '%s' "${result:--}"
}

stream_pid=""
cleanup() {
  if [[ -n "${stream_pid}" ]]; then kill "${stream_pid}" 2>/dev/null || true; fi
  xcrun simctl terminate "${SIMULATOR_UDID}" dev.waterui.E2EReference >/dev/null 2>&1 || true
}
trap cleanup EXIT

xcrun simctl install "${SIMULATOR_UDID}" "${app}" >/dev/null
: > "${marker_log}"
xcrun simctl spawn "${SIMULATOR_UDID}" log stream --level info \
  --predicate 'subsystem == "dev.waterui"' --style compact \
  > "${marker_log}" 2>/dev/null &
stream_pid=$!
sleep 1
xcrun simctl launch "${SIMULATOR_UDID}" dev.waterui.E2EReference \
  -E2EExample "${example}" -E2ETitle "${example}" >/dev/null
launch_epoch="$(python3 -c 'import time; print(f"{time.time():.3f}")')"

capture_times="${scratch}/capture-times.tsv"
: > "${capture_times}"
deadline=$((SECONDS + seconds))
i=0
while (( SECONDS < deadline )); do
  t="$(python3 -c 'import time; print(f"{time.time():.3f}")')"
  frame="${frames_dir}/frame-$(printf '%03d' "${i}").png"
  capture_frame "${frame}" || true
  printf '%s\t%s\n' "${frame}" "${t}" >> "${capture_times}"
  i=$((i + 1))
  sleep "${interval}"
done

kill "${stream_pid}" 2>/dev/null || true
stream_pid=""
xcrun simctl terminate "${SIMULATOR_UDID}" dev.waterui.E2EReference >/dev/null 2>&1 || true

# A first paint can still beat the stream attach; the marker is in the
# persisted log store, so replay the recent window — the same fallback
# wait_for_reference_first_paint uses — before giving up on it.
if ! grep -q "waterui_reference_first_paint_ms=" "${marker_log}" 2>/dev/null; then
  xcrun simctl spawn "${SIMULATOR_UDID}" log show --last 5m \
    --predicate 'subsystem == "dev.waterui"' --style compact \
    >> "${marker_log}" 2>/dev/null || true
fi

# The marker line's own timestamp is the twin's real first-paint time;
# t_since_marker_s is negative for frames captured before it.
marker_epoch=""
marker_line="$(grep -m1 'waterui_reference_first_paint_ms=' "${marker_log}" 2>/dev/null || true)"
if [[ -n "${marker_line}" ]]; then
  # An unparseable timestamp degrades t_since_marker_s to "-" rather than
  # costing the run its frames and timeline.
  marker_epoch="$(python3 -c '
import datetime, sys
print(f"{datetime.datetime.strptime(sys.argv[1], \"%Y-%m-%d %H:%M:%S.%f\").timestamp():.3f}")
' "$(printf '%s' "${marker_line}" | awk '{print $1" "$2}')" 2>/dev/null)" || true
fi

{
  printf 'frame\tt_since_launch_s\tt_since_marker_s\tdiff_vs_previous\tdiff_vs_final\n'
  last_frame="$(tail -1 "${capture_times}" | cut -f1)"
  prev=""
  while IFS=$'\t' read -r frame t; do
    rel_launch="$(awk -v a="${t}" -v b="${launch_epoch}" 'BEGIN{printf "%.3f", a-b}')"
    if [[ -n "${marker_epoch}" ]]; then
      rel_marker="$(awk -v a="${t}" -v b="${marker_epoch}" 'BEGIN{printf "%.3f", a-b}')"
    else
      rel_marker="-"
    fi
    if [[ -n "${prev}" ]]; then
      diff_prev="$(compare_fraction "${prev}" "${frame}")"
    else
      diff_prev="-"
    fi
    diff_final="$(compare_fraction "${frame}" "${last_frame}")"
    printf '%s\t%s\t%s\t%s\t%s\n' \
      "$(basename "${frame}")" "${rel_launch}" "${rel_marker}" "${diff_prev}" "${diff_final}"
    prev="${frame}"
  done < "${capture_times}"
} > "${out}/timeline.tsv"

rm -rf "${scratch}"
echo "::notice::probe captured $((i)) frames for ${example}; marker epoch ${marker_epoch:-missing}"
