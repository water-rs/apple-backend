#!/usr/bin/env bash
# Nightly release-metrics job. Builds a minimal hello-world playground against
# the waterui checkout that setup-e2e.sh prepared (which already carries the
# backend under test), packages it in release mode for each platform, and
# records three release metrics per platform in release-metrics/release-metrics.json:
#   app_bytes / executable_bytes - packaged bundle and main-binary size, gated
#     against Tests/E2EBaselines/package-size.json (5% tolerance fails the job)
#   first_paint_ms - process start to first frame, from the backend's
#     waterui_first_paint_ms os_log marker
#   peak_rss_bytes - peak resident set over a post-launch idle window
# A record run (RECORD=1) writes fresh size baselines for the
# publish-baselines flow; startup and memory are recorded, not gated.
set -euo pipefail

waterui_dir="${WATERUI_DIR:?WATERUI_DIR must point at the prepared waterui checkout}"
repo_root="${GITHUB_WORKSPACE:-$(pwd)}"
baseline_file="${repo_root}/Tests/E2EBaselines/package-size.json"
record_dir="${RECORD_DIR:-${repo_root}/e2e-baselines}"
record="${RECORD:-0}"

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/waterui-size-check.XXXXXX")"
trap 'rm -rf "${work_dir}"' EXIT
project_dir="${work_dir}/helloworld"
mkdir -p "${project_dir}/src"

# The generated project resolves the backend through waterui_path's
# backends/apple fallback — the staged checkout this suite produces — so the
# packaged app builds the commit under test, not the pinned SwiftPM release.
# Playground manifests cannot declare [backends.*], so no explicit override
# is possible or needed here.
cat > "${project_dir}/Water.toml" <<EOF
waterui_path = "${waterui_dir}"

[package]
type = "playground"
name = "Hello World"
bundle_identifier = "com.waterui.helloworld"
EOF

cat > "${project_dir}/Cargo.toml" <<EOF
[package]
name = "helloworld"
version = "0.1.0"
edition = "2024"
publish = false

[features]
dev = ["waterui/dynamic_linking"]

[dependencies]
waterui = { path = "${waterui_dir}" }
EOF

cat > "${project_dir}/src/lib.rs" <<'EOF'
use waterui::app::App;
use waterui::prelude::*;

fn hello() -> impl View {
    text("Hello, World!")
}

pub fn app(env: Environment) -> App {
    App::new(hello, env)
}
EOF

measure_platform() {
    local label="$1" platform="$2" subject_dir="$3"
    local log_file="${work_dir}/package-${label}-${platform}.log"

    echo "=== Packaging ${label} for ${platform} (release)"
    if ! water package --platform "${platform}" --backend apple --release --path "${subject_dir}" \
        > "${log_file}" 2>&1; then
        tail -40 "${log_file}" || true
        echo "::error::water package failed for ${label} on ${platform}; see output above"
        return 1
    fi

    local app_path
    app_path="$(sed -n 's/.*Packaged at //p' "${log_file}" | tail -1 | sed 's/\x1b\[[0-9;]*m//g' | tr -d '\r')"
    if [[ -z "${app_path}" || ! -d "${app_path}" ]]; then
        app_path="$(find "${subject_dir}" "${HOME}/.water/build_cache" -name "*.app" -type d -print -quit 2>/dev/null || true)"
    fi
    if [[ -z "${app_path}" || ! -d "${app_path}" ]]; then
        echo "::error::Packaged .app not found for ${label} on ${platform}"
        return 1
    fi

    local app_bytes executable_bytes executable
    app_bytes="$(find "${app_path}" -type f -exec stat -f%z {} + | awk '{s+=$1} END {print s}')"
    if [[ "${platform}" == macos ]]; then
        executable="${app_path}/Contents/MacOS/$(basename "${app_path}" .app)"
    else
        executable="${app_path}/$(basename "${app_path}" .app)"
    fi
    executable_bytes="$(stat -f%z "${executable}")"

    echo "${label}/${platform}: app=${app_bytes}B executable=${executable_bytes}B (${app_path})"
    printf '%s %s %s %s %s\n' "${label}" "${platform}" "${app_bytes}" "${executable_bytes}" "${app_path}" >> "${work_dir}/measured.txt"
}

# Launch the packaged release build and capture the two runtime metrics that
# only exist at run time:
#   first_paint_ms  - process start to first frame, self-reported by the
#                     backend's `waterui_first_paint_ms` os_log marker.
#   peak_rss_bytes  - peak resident set sampled over a short post-launch
#                     idle window. Simulator apps are host processes, so the
#                     same `ps` sampling covers both platforms.
# A launch failure is an error; a missing paint marker records null — the app
# ran, the marker pipeline broke, and that distinction belongs in the data.
sample_peak_rss() {
    local pid="$1" samples="${2:-8}" peak=0 rss
    for _ in $(seq 1 "${samples}"); do
        rss="$(ps -o rss= -p "${pid}" 2>/dev/null | tr -d ' ' || true)"
        if [[ -n "${rss}" ]] && (( rss > peak )); then peak="${rss}"; fi
        sleep 0.5
    done
    echo $(( peak * 1024 ))
}

wait_first_paint() {
    local log_file="$1" platform="${2:-}"
    for _ in $(seq 1 30); do
        if grep -q "waterui_first_paint_ms=" "${log_file}" 2>/dev/null; then
            sed -n 's/.*waterui_first_paint_ms=\([0-9][0-9]*\).*/\1/p' "${log_file}" | head -1
            return 0
        fi
        sleep 1
    done
    # The fastest apps can paint before the stream attaches; the marker is in
    # the persisted log store, so replay the recent window from the same
    # domain the stream reads before giving up.
    if [[ "${platform}" == macos ]]; then
        log show --last 2m --predicate 'subsystem == "dev.waterui"' \
            --style compact >> "${log_file}" 2>/dev/null || true
    elif [[ -n "${SIMULATOR_UDID:-}" ]]; then
        xcrun simctl spawn "${SIMULATOR_UDID}" log show --last 2m \
            --predicate 'subsystem == "dev.waterui"' --style compact \
            >> "${log_file}" 2>/dev/null || true
    fi
    if grep -q "waterui_first_paint_ms=" "${log_file}" 2>/dev/null; then
        sed -n 's/.*waterui_first_paint_ms=\([0-9][0-9]*\).*/\1/p' "${log_file}" | head -1
        return 0
    fi
    return 1
}

measure_runtime() {
    local label="$1" platform="$2" app_path="$3" bundle_id="$4"
    local marker_log="${work_dir}/paint-${label}-${platform}.log"
    local exec_name first_paint="" peak_rss="" pid=""
    exec_name="$(basename "${app_path}" .app)"

    if [[ "${platform}" == macos ]]; then
        log stream --predicate 'subsystem == "dev.waterui"' --style compact \
            > "${marker_log}" 2>/dev/null &
        local stream_pid=$!
        sleep 1  # let logd attach before the app can paint
        "${app_path}/Contents/MacOS/${exec_name}" > /dev/null 2>&1 &
        pid=$!
        first_paint="$(wait_first_paint "${marker_log}" "${platform}" || true)"
        if ! kill -0 "${pid}" 2>/dev/null; then
            kill "${stream_pid}" 2>/dev/null || true
            echo "::error::${label}/${platform} release app exited during launch"
            printf '%s %s %s %s\n' "${label}" "${platform}" "null" "null" >> "${work_dir}/runtime.txt"
            return 1
        fi
        peak_rss="$(sample_peak_rss "${pid}")"
        kill "${pid}" 2>/dev/null || true
        kill "${stream_pid}" 2>/dev/null || true
    else
        local udid="${SIMULATOR_UDID:?SIMULATOR_UDID is required for ios-simulator runtime metrics}"
        xcrun simctl install "${udid}" "${app_path}"
        xcrun simctl spawn "${udid}" log stream --level info \
            --predicate 'subsystem == "dev.waterui"' --style compact \
            > "${marker_log}" 2>/dev/null &
        local stream_pid=$!
        sleep 1  # let logd attach before the app can paint
        pid="$(xcrun simctl launch "${udid}" "${bundle_id}" | awk -F': ' '{print $2}')"
        if [[ -z "${pid}" ]]; then
            kill "${stream_pid}" 2>/dev/null || true
            echo "::error::${label}/${platform} release app failed to launch in the simulator"
            printf '%s %s %s %s\n' "${label}" "${platform}" "null" "null" >> "${work_dir}/runtime.txt"
            return 1
        fi
        first_paint="$(wait_first_paint "${marker_log}" "${platform}" || true)"
        peak_rss="$(sample_peak_rss "${pid}")"
        xcrun simctl terminate "${udid}" "${bundle_id}" > /dev/null 2>&1 || true
        xcrun simctl uninstall "${udid}" "${bundle_id}" > /dev/null 2>&1 || true
        kill "${stream_pid}" 2>/dev/null || true
    fi

    if [[ -z "${first_paint}" ]]; then
        echo "::warning::${label}/${platform} release app did not report a first-paint time"
        first_paint="null"
    fi
    [[ "${peak_rss:-0}" == 0 ]] && peak_rss="null"
    echo "${label}/${platform}: first_paint=${first_paint}ms peak_rss=${peak_rss}B"
    printf '%s %s %s %s\n' "${label}" "${platform}" "${first_paint}" "${peak_rss}" >> "${work_dir}/runtime.txt"
}

# Measurement subject: the generated hello-world — the stable minimal-app
# signal the size gate applies to. Per-example release sizes/startup/memory
# are measured by the e2e shards themselves, which package every example in
# release mode; duplicating example subjects here would pay the packaging
# cost twice (#144).
subjects=("helloworld=${project_dir}")

failed=0
for entry in ${subjects[@]+"${subjects[@]}"}; do
    label="${entry%%=*}"
    subject_dir="${entry#*=}"
    for platform in macos ios-simulator; do
        measure_platform "${label}" "${platform}" "${subject_dir}" || failed=1
    done
done
[[ -f "${work_dir}/measured.txt" ]] || { echo "::error::No platform packaged successfully"; exit 1; }

# Runtime metrics on the freshly packaged release builds. iOS needs a booted
# simulator; when SIMULATOR_UDID is unset the size gate still runs and the
# ios-simulator row records nulls rather than failing the job.
while read -r label platform app_bytes executable_bytes app_path; do
    if [[ "${platform}" != macos && -z "${SIMULATOR_UDID:-}" ]]; then
        echo "::warning::No booted simulator for ${label}/${platform}; runtime metrics skipped"
        printf '%s %s %s %s\n' "${label}" "${platform}" "null" "null" >> "${work_dir}/runtime.txt"
        continue
    fi
    subject_dir="$(printf '%s\n' "${subjects[@]}" | sed -n "s/^${label}=//p")"
    bundle_id="$(sed -n 's/^bundle_identifier = "\([^"]*\)"$/\1/p' "${subject_dir}/Water.toml" | head -1)"
    measure_runtime "${label}" "${platform}" "${app_path}" "${bundle_id}" || failed=1
done < "${work_dir}/measured.txt"

# Machine-readable record + human-readable table. Both are uploaded by the
# workflow: the JSON feeds trend diffs, the markdown lands on the run summary.
metrics_dir="${METRICS_DIR:-${repo_root}/release-metrics}"
mkdir -p "${metrics_dir}"
{
    echo '{'
    prev_label=""
    first=1
    while read -r label platform app_bytes executable_bytes app_path; do
        runtime="$(grep "^${label} ${platform} " "${work_dir}/runtime.txt" 2>/dev/null || true)"
        read -r _ _ first_paint peak_rss <<< "${runtime:-${label} ${platform} null null}"
        if [[ "${label}" != "${prev_label}" ]]; then
            if [[ -n "${prev_label}" ]]; then echo '},'; fi
            first=0
            printf '  "%s": {\n' "${label}"
            platform_first=1
        fi
        prev_label="${label}"
        if [[ "${platform_first}" != 1 ]]; then echo ','; fi
        platform_first=0
        printf '    "%s": { "app_bytes": %s, "executable_bytes": %s, "first_paint_ms": %s, "peak_rss_bytes": %s }' \
            "${platform}" "${app_bytes}" "${executable_bytes}" "${first_paint}" "${peak_rss}"
    done < "${work_dir}/measured.txt"
    if [[ -n "${prev_label}" ]]; then echo '}'; fi
    echo '}'
} > "${metrics_dir}/release-metrics.json"

{
    echo "## Release metrics (production builds)"
    echo
    echo "| App | Platform | .app size | Executable | First paint | Peak RSS |"
    echo "| --- | --- | --- | --- | --- | --- |"
    while read -r label platform app_bytes executable_bytes app_path; do
        runtime="$(grep "^${label} ${platform} " "${work_dir}/runtime.txt" 2>/dev/null || true)"
        read -r _ _ first_paint peak_rss <<< "${runtime:-${label} ${platform} null null}"
        fp_cell="—"; rss_cell="—"
        [[ "${first_paint}" != null ]] && fp_cell="${first_paint} ms"
        [[ "${peak_rss}" != null ]] && rss_cell="$(awk -v b="${peak_rss}" 'BEGIN{printf "%.1f MB", b/1048576}')"
        printf '| `%s` | `%s` | %s | %s | %s | %s |\n' "${label}" "${platform}" \
            "$(awk -v b="${app_bytes}" 'BEGIN{printf "%.1f MB", b/1048576}')" \
            "$(awk -v b="${executable_bytes}" 'BEGIN{printf "%.1f MB", b/1048576}')" \
            "${fp_cell}" "${rss_cell}"
    done < "${work_dir}/measured.txt"
} > "${metrics_dir}/release-metrics.md"
cat "${metrics_dir}/release-metrics.md"

if [[ "${record}" == "1" ]]; then
    mkdir -p "${record_dir}"
    {
        echo '{'
        first=1
        while read -r label platform app_bytes executable_bytes _app_path; do
            [[ "${label}" == helloworld ]] || continue
            if [[ "${first}" != 1 ]]; then echo ','; fi
            first=0
            printf '  "%s": { "app_bytes": %s, "executable_bytes": %s }' \
                "${platform}" "${app_bytes}" "${executable_bytes}"
        done < "${work_dir}/measured.txt"
        echo
        echo '}'
    } > "${record_dir}/package-size.json"
    echo "Recorded size baseline -> ${record_dir}/package-size.json"
    cat "${record_dir}/package-size.json"
    exit "${failed}"
fi

if [[ ! -f "${baseline_file}" ]]; then
    echo "::warning::No size baseline at ${baseline_file}; measurements reported but not gated"
    cat "${work_dir}/measured.txt"
    exit "${failed}"
fi

# Compare each measured metric against its baseline. Growth of more than
# size_tolerance (a percentage, e.g. 0.05) fails the job; shrinkage only gets
# reported — refreshing the baseline downward is a deliberate record run.
check_metric() {
    local platform="$1" metric="$2" measured="$3" baseline="$4"
    local limit growth_x100
    limit=$(( baseline + baseline / 20 ))
    growth_x100=$(( (measured - baseline) * 10000 / baseline ))
    if (( measured > limit )); then
        echo "::error::${platform} ${metric} grew $((growth_x100 / 100)).$((growth_x100 % 100))% (${baseline} -> ${measured} bytes, allowed +5%)"
        return 1
    fi
    echo "${platform} ${metric}: ${measured} bytes (baseline ${baseline}, $((growth_x100 / 100)).$((growth_x100 % 100))%)"
}

# The byte gate applies to hello-world only — it is the stable minimal-app
# signal. Example sizes are recorded for visibility, not gated.
while read -r label platform app_bytes executable_bytes _app_path; do
    [[ "${label}" == helloworld ]] || continue
    baseline_app="$(plutil -extract "${platform}.app_bytes" raw "${baseline_file}" 2>/dev/null || true)"
    baseline_exe="$(plutil -extract "${platform}.executable_bytes" raw "${baseline_file}" 2>/dev/null || true)"
    if [[ -z "${baseline_app}" || -z "${baseline_exe}" ]]; then
        echo "::warning::No baseline entry for ${platform}; skipping gate"
        continue
    fi
    check_metric "${platform}" "app" "${app_bytes}" "${baseline_app}" || failed=1
    check_metric "${platform}" "executable" "${executable_bytes}" "${baseline_exe}" || failed=1
done < "${work_dir}/measured.txt"

if [[ "${failed}" == 1 ]]; then
    echo "Package size regression detected — refresh the baseline only if the growth is intended (record_baselines run)."
    exit 1
fi
echo "Package sizes within baseline."
