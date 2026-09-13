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
  exit 0
fi

echo "Running ${#shard_examples[@]} examples on ${platform}: ${shard_examples[*]}"

# One frame from the current platform target.
capture_frame() {
  local target="$1"
  if [[ "${platform}" == "ios" ]]; then
    xcrun simctl io "${SIMULATOR_UDID}" screenshot "${target}" >/dev/null
  else
    local window_id
    window_id="$(swift "${workspace}/.github/scripts/window-id.swift" "${app_pid}")"
    screencapture -x -o -l"${window_id}" "${target}"
  fi
}

# Captures until two consecutive frames agree within the compare budget — the
# app has settled once its output stops changing — or the deadline passes, in
# which case the last frame is kept. Fails when no frame could be captured.
capture_settled() {
  local target="$1"
  local previous=""
  local deadline=$((SECONDS + 90))
  while (( SECONDS < deadline )); do
    if capture_frame "${target}" && [[ -f "${target}" ]]; then
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

declare -a failures=()
declare -a report=()

for example in ${shard_examples[@]+"${shard_examples[@]}"}; do
  example_path="${waterui_dir}/examples/${example}"
  run_log="${logs_dir}/${platform}-${example}.log"
  shot="${shots_dir}/${platform}-${example}.png"
  rm -f "${shot}"

  echo "::group::${platform} example ${example}"

  # The product name is Water.toml's package.name; the running process is the
  # executable inside the built .app bundle.
  product="$(sed -n 's/^name = "\([^"]*\)"$/\1/p' "${example_path}/Water.toml" | head -1)"
  bundle_id="$(sed -n 's/^bundle_identifier = "\([^"]*\)"$/\1/p' "${example_path}/Water.toml" | head -1)"

  : > "${run_log}"
  if [[ "${platform}" == "ios" ]]; then
    water run --platform ios --path "${example_path}" --device "${SIMULATOR_UDID}" > "${run_log}" 2>&1 &
  else
    water run --platform macos --path "${example_path}" > "${run_log}" 2>&1 &
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
      report+=("| \`${example}\` | launch timeout | — |")
    else
      echo "::error::water run failed for ${example} (${platform})."
      failures+=("${example}: build/launch")
      report+=("| \`${example}\` | build/launch failed | — |")
    fi
    tail -n 120 "${run_log}" || true
    wait "${runner_pid}" || true
    echo "::endgroup::"
    continue
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
      report+=("| \`${example}\` | no process | — |")
      echo "::endgroup::"
      continue
    fi
  fi

  if ! capture_settled "${shot}"; then
    echo "::error::Could not capture a screenshot for ${example}."
    kill "${runner_pid}" 2>/dev/null || true
    wait "${runner_pid}" || true
    failures+=("${example}: capture")
    report+=("| \`${example}\` | capture failed | — |")
    echo "::endgroup::"
    continue
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
    report+=("| \`${example}\` | blank capture | — |")
    echo "::endgroup::"
    continue
  fi

  baseline="${baselines_dir}/${platform}/${example}.png"
  if [[ "${record}" == "1" ]]; then
    cp "${shot}" "${record_dir}/${platform}/${example}.png"
    report+=("| \`${example}\` | recorded | — |")
  elif [[ -f "${baselines_dir}/${platform}/${example}.skip" ]]; then
    report+=("| \`${example}\` | launched (compare skipped) | — |")
  elif [[ ! -f "${baseline}" ]]; then
    report+=("| \`${example}\` | launched (no baseline yet) | — |")
  else
    diff_image="${shots_dir}/${platform}-${example}-diff.png"
    if compare_out="$(swift "${workspace}/.github/scripts/compare-screenshots.swift" \
        compare "${baseline}" "${shot}" "${diff_image}")"; then
      report+=("| \`${example}\` | baseline match | ${compare_out#compare: } |")
    else
      echo "::error::Screenshot regression for ${example}: ${compare_out}"
      failures+=("${example}: regression")
      report+=("| \`${example}\` | regression | ${compare_out#compare: } |")
    fi
  fi

  echo "::endgroup::"
done

{
  echo "## E2E ${platform} — shard ${shard_index}/${shard_total}"
  echo ""
  echo "| Example | Result | Diff |"
  echo "| --- | --- | --- |"
  for row in ${report[@]+"${report[@]}"}; do
    echo "${row}"
  done
} >> "${GITHUB_STEP_SUMMARY:-/dev/stdout}"

if (( ${#failures[@]} > 0 )); then
  echo "::error::${#failures[@]} example(s) failed on ${platform}: ${failures[*]}"
  exit 1
fi
