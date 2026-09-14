#!/usr/bin/env bash
# Nightly e2e shard. For every example assigned to this shard: build it, launch
# it, wait for the app's own readiness log, capture a settled screenshot, and
# verify it — a capture must carry real content (not a uniform fill), and when
# a recorded baseline exists under Tests/E2EBaselines it must match within the
# compare budget. A `.skip` marker next to a baseline opts an example out of
# pixel comparison only; launch and content are still verified. With RECORD=1,
# captures are written to ${RECORD_DIR} for the baseline-publish job instead of
# being compared. Failures are collected so one broken example does not hide
# the state of the rest; the script exits nonzero if any example failed.
set -euo pipefail

platform="${PLATFORM:-${1:-}}"
shard_index="${SHARD_INDEX:-${2:-}}"
shard_total="${SHARD_TOTAL:-${3:-}}"
workspace="${GITHUB_WORKSPACE:-$(pwd)}"
waterui_dir="${WATERUI_DIR:-${workspace}/waterui}"
logs_dir="${EXAMPLE_LOG_DIR:-${workspace}/e2e-logs}"
shots_dir="${SHOTS_DIR:-${workspace}/e2e-shots}"
baselines_dir="${BASELINES_DIR:-${workspace}/Tests/E2EBaselines}"
record_dir="${RECORD_DIR:-${workspace}/e2e-baselines}"
record="${RECORD:-0}"
parity_budgets="${PARITY_BUDGETS:-${baselines_dir}/parity-budgets.json}"
reference_dir="${workspace}/Tests/E2EReference"

if [[ "${platform}" != "ios" && "${platform}" != "macos" ]]; then
  echo "::error::Unsupported platform '${platform}'. Expected ios or macos."
  exit 1
fi
if [[ -z "${shard_index}" || -z "${shard_total}" ]]; then
  echo "::error::SHARD_INDEX and SHARD_TOTAL are required"
  exit 1
fi
if (( shard_index < 0 || shard_total <= 0 || shard_index >= shard_total )); then
  echo "::error::Invalid shard configuration: index=${shard_index}, total=${shard_total}"
  exit 1
fi
if [[ ! -d "${waterui_dir}" ]]; then
  echo "::error::Missing waterui checkout at ${waterui_dir}"
  exit 1
fi
if [[ "${platform}" == "ios" && -z "${SIMULATOR_UDID:-}" ]]; then
  echo "::error::SIMULATOR_UDID is required for iOS runs"
  exit 1
fi

mkdir -p "${logs_dir}" "${shots_dir}"
startup_entries="${logs_dir}/.startup-${platform}-${shard_index}.entries"
memory_entries="${logs_dir}/.memory-${platform}-${shard_index}.entries"
: > "${startup_entries}"
: > "${memory_entries}"
if [[ "${record}" == "1" ]]; then
  mkdir -p "${record_dir}/${platform}"
fi

all_examples=()
while IFS= read -r example; do
  all_examples+=("${example}")
done < <("${workspace}/.github/scripts/discover-examples.sh" "${waterui_dir}")
declare -a shard_examples=()

# The `${arr[@]+...}` form: under the system bash 3.2 an empty array expands to
# an unbound-variable error, and shards legitimately assign no examples.
for example in ${all_examples[@]+"${all_examples[@]}"}; do
  checksum=$(printf '%s' "${example}" | cksum | awk '{print $1}')
  if (( checksum % shard_total == shard_index )); then
    shard_examples+=("${example}")
  fi
done

if (( ${#shard_examples[@]} == 0 )); then
  echo "Shard ${shard_index}/${shard_total} has no examples for ${platform}."
  echo "{}" > "${logs_dir}/startup-times-${platform}-${shard_index}.json"
  echo "{}" > "${logs_dir}/memory-${platform}-${shard_index}.json"
  exit 0
fi

echo "Running ${#shard_examples[@]} examples on ${platform}: ${shard_examples[*]}"

# One frame from the current platform target. macOS captures need the pid that
# owns the window; the running example is the default, the SwiftUI reference
# host passes its own.
capture_frame() {
  local target="$1"
  local pid="${2:-${app_pid}}"
  if [[ "${platform}" == "ios" ]]; then
    xcrun simctl io "${SIMULATOR_UDID}" screenshot "${target}" >/dev/null
  else
    local window_id
    window_id="$(swift "${workspace}/.github/scripts/window-id.swift" "${pid}")"
    screencapture -x -o -l"${window_id}" "${target}"
  fi
}

# Captures until two consecutive frames agree within the compare budget — the
# app has settled once its output stops changing — or the deadline passes, in
# which case the last frame is kept. Fails when no frame could be captured.
capture_settled() {
  local target="$1"
  local pid="${2:-}"
  local previous=""
  local deadline=$((SECONDS + 90))
  while (( SECONDS < deadline )); do
    if capture_frame "${target}" ${pid:+"${pid}"} && [[ -f "${target}" ]]; then
      if [[ -n "${previous}" ]] && \
         DIFF_BUDGET=0.01 swift "${workspace}/.github/scripts/compare-screenshots.swift" \
           compare "${previous}" "${target}" "${shots_dir}/.settle-diff.png" >/dev/null 2>&1; then
        rm -f "${previous}"
        return 0
      fi
      [[ -z "${previous}" ]] && previous="$(mktemp -t e2e-settle).png"
      cp "${target}" "${previous}"
    fi
    sleep 1
  done
  rm -f "${previous}"
  if [[ ! -f "${target}" ]]; then
    return 1
  fi
  echo "::warning::${example} never settled to a stable frame; using the last capture."
}

# ── SwiftUI parity ──────────────────────────────────────────────────────────
# Examples with a registered twin in Tests/E2EReference are also compared
# against the twin rendered live by the reference host on the same runner —
# the backend must stay pixel-faithful to what SwiftUI produces for the same
# layout, not only to its own recorded baseline. The twin registry is read
# from Twins.swift so a new twin joins the sweep automatically.
twin_names=()
if [[ -f "${reference_dir}/Sources/Twins.swift" ]]; then
  while IFS= read -r twin; do
    twin_names+=("${twin}")
  done < <(sed -n 's/.*case "\([^"]*\)":.*/\1/p' "${reference_dir}/Sources/Twins.swift" | sort -u)
fi

has_twin() {
  local t
  for t in ${twin_names[@]+"${twin_names[@]}"}; do
    [[ "${t}" == "$1" ]] && return 0
  done
  return 1
}

# Built lazily on the first twinned example in the shard; a shard with no
# twins never pays for it.
reference_app=""
build_reference_host() {
  [[ -n "${reference_app}" ]] && return 0
  local out_dir="${shots_dir}/.reference-host"
  if "${reference_dir}/build-reference-host.sh" "${platform}" "${out_dir}" \
      >"${logs_dir}/${platform}-reference-build.log" 2>&1; then
    reference_app="${out_dir}/E2EReference.app"
  else
    echo "::error::Failed to build the SwiftUI reference host."
    tail -n 60 "${logs_dir}/${platform}-reference-build.log" || true
    return 1
  fi
}

# Launches the reference host for `example`, settles, captures to $1, and
# shuts it down again. The reference never runs concurrently with the example
# under test, so the runner's single screen needs no window choreography.
capture_reference() {
  local target="$1" example="$2" title="$3"
  build_reference_host || return 1
  if [[ "${platform}" == "ios" ]]; then
    xcrun simctl install "${SIMULATOR_UDID}" "${reference_app}" >/dev/null
    xcrun simctl launch "${SIMULATOR_UDID}" dev.waterui.E2EReference \
      -E2EExample "${example}" -E2ETitle "${title}" >/dev/null
    sleep 2
    capture_settled "${target}"
    local rc=$?
    xcrun simctl terminate "${SIMULATOR_UDID}" dev.waterui.E2EReference >/dev/null 2>&1 || true
    return ${rc}
  else
    "${reference_app}/Contents/MacOS/E2EReference" \
      -E2EExample "${example}" -E2ETitle "${title}" \
      >>"${logs_dir}/${platform}-${example}-ref.log" 2>&1 &
    local ref_pid=$!
    capture_settled "${target}" "${ref_pid}"
    local rc=$?
    kill "${ref_pid}" 2>/dev/null || true
    wait "${ref_pid}" 2>/dev/null || true
    return ${rc}
  fi
}

# The allowed diff fraction for this twin on this platform: the recorded
# budget when the twin is known-divergent, the strict default otherwise.
parity_budget() {
  local budget=""
  if [[ -f "${parity_budgets}" ]]; then
    budget="$(python3 -c '
import json, sys
try:
  budgets = json.load(open(sys.argv[1]))
  value = budgets.get(sys.argv[2], {}).get(sys.argv[3], "")
  print(value)
except Exception:
  print("")
' "${parity_budgets}" "${platform}" "$1")"
  fi
  echo "${budget:-${DIFF_BUDGET:-0.02}}"
}

declare -a failures=()
declare -a report=()

for example in ${shard_examples[@]+"${shard_examples[@]}"}; do
  mem_cell="—"
  example_path="${waterui_dir}/examples/${example}"
  run_log="${logs_dir}/${platform}-${example}.log"
  shot="${shots_dir}/${platform}-${example}.png"
  rm -f "${shot}"

  echo "::group::${platform} example ${example}"

  # The product name is Water.toml's package.name; the running process is the
  # executable inside the built .app bundle.
  product="$(sed -n 's/^name = "\([^"]*\)"$/\1/p' "${example_path}/Water.toml" | head -1)"
  bundle_id="$(sed -n 's/^bundle_identifier = "\([^"]*\)"$/\1/p' "${example_path}/Water.toml" | head -1)"

  # `--logs info` streams the app's own dev.waterui log lines back into the
  # run log, which is where the backend's launch-time marker lands (#88).
  : > "${run_log}"
  if [[ "${platform}" == "ios" ]]; then
    water run --platform ios --path "${example_path}" --device "${SIMULATOR_UDID}" --logs info > "${run_log}" 2>&1 &
  else
    water run --platform macos --path "${example_path}" --logs info > "${run_log}" 2>&1 &
  fi
  runner_pid=$!

  ready=0
  for _ in $(seq 1 45); do
    if ! kill -0 "${runner_pid}" 2>/dev/null; then
      break
    fi
    if grep -q "Application started" "${run_log}"; then
      ready=1
      break
    fi
    sleep 2
  done

  if (( ready == 0 )); then
    if kill -0 "${runner_pid}" 2>/dev/null; then
      echo "::error::Timed out waiting for readiness for ${example} (${platform})."
      kill "${runner_pid}" 2>/dev/null || true
      failures+=("${example}: launch timeout")
      report+=("| \`${example}\` | launch timeout | — | — | ${mem_cell} |")
      printf '  "%s": null,\n' "${example}" >> "${startup_entries}"
    else
      echo "::error::water run failed for ${example} (${platform})."
      failures+=("${example}: build/launch")
      report+=("| \`${example}\` | build/launch failed | — | — | ${mem_cell} |")
      printf '  "%s": null,\n' "${example}" >> "${startup_entries}"
    fi
    tail -n 120 "${run_log}" || true
    wait "${runner_pid}" || true
    echo "::endgroup::"
    continue
  fi

  # Launch-to-first-paint, self-reported by the backend (#88): the app logs
  # `waterui_first_paint_ms=N` once its first window paints. The os_log stream
  # races the launch, so give the marker a short grace window and record
  # whatever arrived — a missing marker is data, not a failure.
  startup_ms=""
  for _ in $(seq 1 10); do
    startup_ms="$(sed -n 's/.*waterui_first_paint_ms=\([0-9][0-9]*\).*/\1/p' "${run_log}" | head -1)"
    [[ -n "${startup_ms}" ]] && break
    sleep 1
  done
  if [[ -n "${startup_ms}" ]]; then
    echo "::notice::${example} first paint in ${startup_ms} ms (${platform})"
    printf '  "%s": %s,\n' "${example}" "${startup_ms}" >> "${startup_entries}"
    fp_cell="${startup_ms} ms"
  else
    echo "::warning::${example} did not report a first-paint time"
    printf '  "%s": null,\n' "${example}" >> "${startup_entries}"
    fp_cell="—"
  fi

  app_pid=""
  if [[ "${platform}" == "macos" ]]; then
    # The window server only knows the app once it has presented; poll briefly
    # past the readiness log before declaring the process missing.
    for _ in $(seq 1 10); do
      app_pid="$(pgrep -f "${product}\.app/Contents/MacOS/" | head -1 || true)"
      [[ -n "${app_pid}" ]] && break
      sleep 1
    done
    if [[ -z "${app_pid}" ]]; then
      echo "::error::No running process found for ${example}."
      kill "${runner_pid}" 2>/dev/null || true
      wait "${runner_pid}" || true
      failures+=("${example}: no process")
      report+=("| \`${example}\` | no process | — | ${fp_cell} | ${mem_cell} |")
      echo "::endgroup::"
      continue
    fi
  fi

  if ! capture_settled "${shot}"; then
    echo "::error::Could not capture a screenshot for ${example}."
    kill "${runner_pid}" 2>/dev/null || true
    wait "${runner_pid}" || true
    failures+=("${example}: capture")
    report+=("| \`${example}\` | capture failed | — | ${fp_cell} | ${mem_cell} |")
    echo "::endgroup::"
    continue
  fi

  # Post-launch memory footprint: peak resident set sampled over a short idle
  # window while the app is still up. Simulator apps are host processes, so
  # `ps` covers both platforms; the iOS pid is recovered from the bundle path
  # under the booted device's data directory.
  mem_pid="${app_pid}"
  if [[ "${platform}" == "ios" ]]; then
    mem_pid="$(pgrep -f "CoreSimulator/Devices/${SIMULATOR_UDID}/.*${product}\.app/" | head -1 || true)"
  fi
  peak_rss=0
  if [[ -n "${mem_pid}" ]]; then
    for _ in $(seq 1 4); do
      rss="$(ps -o rss= -p "${mem_pid}" 2>/dev/null | tr -d ' ' || true)"
      if [[ -n "${rss}" ]] && (( rss > peak_rss )); then peak_rss="${rss}"; fi
      sleep 0.5
    done
  fi
  if (( peak_rss > 0 )); then
    printf '  "%s": %s,\n' "${example}" "$(( peak_rss * 1024 ))" >> "${memory_entries}"
    mem_cell="$(awk -v b="${peak_rss}" 'BEGIN{printf "%.0f MB", b/1024}')"
  else
    printf '  "%s": null,\n' "${example}" >> "${memory_entries}"
    mem_cell="—"
  fi

  kill "${runner_pid}" 2>/dev/null || true
  wait "${runner_pid}" || true
  # A signal-killed runner cannot forward shutdown to the app, so the launched
  # process is ended explicitly; otherwise its window stays up and piles onto
  # the next example's.
  if [[ "${platform}" == "ios" && -n "${bundle_id}" ]]; then
    xcrun simctl terminate "${SIMULATOR_UDID}" "${bundle_id}" >/dev/null 2>&1 || true
  elif [[ "${platform}" == "macos" ]]; then
    kill "${app_pid}" 2>/dev/null || true
  fi

  if ! swift "${workspace}/.github/scripts/compare-screenshots.swift" content "${shot}"; then
    echo "::error::Captured screenshot for ${example} is blank."
    failures+=("${example}: blank")
    report+=("| \`${example}\` | blank capture | — | ${fp_cell} | ${mem_cell} |")
    echo "::endgroup::"
    continue
  fi

  baseline="${baselines_dir}/${platform}/${example}.png"
  if [[ "${record}" == "1" ]]; then
    cp "${shot}" "${record_dir}/${platform}/${example}.png"
    report+=("| \`${example}\` | recorded | — | ${fp_cell} | ${mem_cell} |")
  elif [[ -f "${baselines_dir}/${platform}/${example}.skip" ]]; then
    report+=("| \`${example}\` | launched (compare skipped) | — | ${fp_cell} | ${mem_cell} |")
  elif [[ ! -f "${baseline}" ]]; then
    report+=("| \`${example}\` | launched (no baseline yet) | — | ${fp_cell} | ${mem_cell} |")
  else
    diff_image="${shots_dir}/${platform}-${example}-diff.png"
    if compare_out="$(swift "${workspace}/.github/scripts/compare-screenshots.swift" \
        compare "${baseline}" "${shot}" "${diff_image}")"; then
      report+=("| \`${example}\` | baseline match | ${compare_out#compare: } | ${fp_cell} | ${mem_cell} |")
    else
      echo "::error::Screenshot regression for ${example}: ${compare_out}"
      failures+=("${example}: regression")
      report+=("| \`${example}\` | regression | ${compare_out#compare: } | ${fp_cell} | ${mem_cell} |")
    fi
  fi

  # SwiftUI parity: render the twin in the reference host and compare it
  # against the example capture taken above. A `.parity-skip` marker next to
  # the baselines opts a twin out while a known divergence is worked down.
  if has_twin "${example}" && \
     [[ ! -f "${baselines_dir}/${platform}/${example}.parity-skip" ]]; then
    ref_shot="${shots_dir}/${platform}-${example}-ref.png"
    parity_diff="${shots_dir}/${platform}-${example}-parity-diff.png"
    budget="$(parity_budget "${example}")"
    # Record runs measure rather than gate: an unbounded budget keeps the
    # compare green so the true fraction lands in the report and the artifact.
    [[ "${record}" == "1" ]] && budget="1.0"
    if ! capture_reference "${ref_shot}" "${example}" "${product}"; then
      echo "::error::Could not capture the SwiftUI reference for ${example}."
      failures+=("${example}: reference capture")
      report+=("| \`${example}\` (parity) | reference failed | — | ${fp_cell} | ${mem_cell} |")
    elif ! swift "${workspace}/.github/scripts/compare-screenshots.swift" \
        content "${ref_shot}" >/dev/null 2>&1; then
      echo "::error::SwiftUI reference for ${example} captured blank."
      failures+=("${example}: reference blank")
      report+=("| \`${example}\` (parity) | reference blank | — | ${fp_cell} | ${mem_cell} |")
    elif parity_out="$(DIFF_BUDGET="${budget}" \
        swift "${workspace}/.github/scripts/compare-screenshots.swift" \
        compare "${ref_shot}" "${shot}" "${parity_diff}" 2>&1)"; then
      parity_fraction="${parity_out#compare: }"
      parity_fraction="${parity_fraction%% *}"
      if [[ "${record}" == "1" ]]; then
        mkdir -p "${record_dir}/parity"
        printf '%s\n' "${parity_fraction}" \
          > "${record_dir}/parity/${platform}-${example}.txt"
        report+=("| \`${example}\` (parity) | recorded ${parity_fraction} | — | ${fp_cell} | ${mem_cell} |")
      else
        report+=("| \`${example}\` (parity) | within budget ${budget} | ${parity_out#compare: } | ${fp_cell} | ${mem_cell} |")
      fi
    else
      echo "::error::SwiftUI parity regression for ${example}: ${parity_out} (budget ${budget})"
      failures+=("${example}: parity regression")
      report+=("| \`${example}\` (parity) | drift over budget ${budget} | ${parity_out#compare: } | ${fp_cell} | ${mem_cell} |")
    fi
  fi

  echo "::endgroup::"
done

# Fold the per-example measurements into a JSON object the workflow uploads.
{
  echo "{"
  sed '$ s/,$//' "${startup_entries}"
  echo "}"
} > "${logs_dir}/startup-times-${platform}-${shard_index}.json"
rm -f "${startup_entries}"

{
  echo "{"
  sed '$ s/,$//' "${memory_entries}"
  echo "}"
} > "${logs_dir}/memory-${platform}-${shard_index}.json"
rm -f "${memory_entries}"

{
  echo "## E2E ${platform} — shard ${shard_index}/${shard_total}"
  echo ""
  echo "| Example | Result | Diff | First paint | Peak RSS |"
  echo "| --- | --- | --- | --- | --- |"
  for row in ${report[@]+"${report[@]}"}; do
    echo "${row}"
  done
} >> "${GITHUB_STEP_SUMMARY:-/dev/stdout}"

if (( ${#failures[@]} > 0 )); then
  echo "::error::${#failures[@]} example(s) failed on ${platform}: ${failures[*]}"
  exit 1
fi
