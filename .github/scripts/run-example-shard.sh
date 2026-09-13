#!/usr/bin/env bash
set -euo pipefail

platform="${PLATFORM:-${1:-}}"
shard_index="${SHARD_INDEX:-${2:-}}"
shard_total="${SHARD_TOTAL:-${3:-}}"
waterui_dir="${WATERUI_DIR:-${GITHUB_WORKSPACE:-$(pwd)}/waterui}"
logs_dir="${EXAMPLE_LOG_DIR:-${GITHUB_WORKSPACE:-$(pwd)}/example-logs}"

if [[ -z "${platform}" ]]; then
  echo "::error::PLATFORM is required"
  exit 1
fi
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

mkdir -p "${logs_dir}"

all_examples=()
while IFS= read -r example; do
  all_examples+=("${example}")
done < <("${GITHUB_WORKSPACE:-$(pwd)}/.github/scripts/discover-examples.sh" "${waterui_dir}")
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

for example in ${shard_examples[@]+"${shard_examples[@]}"}; do
  example_path="${waterui_dir}/examples/${example}"
  run_log="${logs_dir}/${platform}-${example}.log"

  echo "::group::${platform} example ${example}"

  # Examples are playground projects: `water build` rejects them and `water
  # run` performs the build itself before launching.
  : > "${run_log}"
  if [[ "${platform}" == "ios" ]]; then
    water run --platform ios --path "${example_path}" --device "${SIMULATOR_UDID}" > "${run_log}" 2>&1 &
  else
    water run --platform macos --path "${example_path}" > "${run_log}" 2>&1 &
  fi

  app_pid=$!
  ready=0
  max_attempts=45

  for _ in $(seq 1 "${max_attempts}"); do
    if ! kill -0 "${app_pid}" 2>/dev/null; then
      echo "::error::water run exited before readiness for ${example} (${platform})."
      tail -n 120 "${run_log}" || true
      wait "${app_pid}" || true
      echo "::endgroup::"
      exit 1
    fi

    if grep -q "Application started" "${run_log}"; then
      ready=1
      break
    fi

    sleep 2
  done

  if (( ready == 0 )); then
    echo "::error::Timed out waiting for readiness for ${example} (${platform})."
    tail -n 120 "${run_log}" || true
    kill "${app_pid}" 2>/dev/null || true
    wait "${app_pid}" || true
    echo "::endgroup::"
    exit 1
  fi

  kill "${app_pid}" 2>/dev/null || true
  wait "${app_pid}" || true

  echo "::endgroup::"
done
