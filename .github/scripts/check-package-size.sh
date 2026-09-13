#!/usr/bin/env bash
# Nightly package-size gate. Builds a minimal hello-world playground against
# the waterui checkout that setup-e2e.sh prepared (which already carries the
# backend under test), packages it in release mode for each platform, and
# compares the produced .app bundle and its main executable against the byte
# baseline in Tests/E2EBaselines/package-size.json. A regression beyond a
# fixed 5% tolerance fails the job; a record run (RECORD=1) writes fresh
# measurements for the publish-baselines flow instead of gating.
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
    local platform="$1"
    local log_file="${work_dir}/package-${platform}.log"

    echo "=== Packaging hello world for ${platform} (release)"
    if ! water package --platform "${platform}" --backend apple --release --path "${project_dir}" \
        > "${log_file}" 2>&1; then
        tail -40 "${log_file}" || true
        echo "::error::water package failed for ${platform}; see output above"
        return 1
    fi

    local app_path
    app_path="$(sed -n 's/.*Packaged at //p' "${log_file}" | tail -1 | sed 's/\x1b\[[0-9;]*m//g' | tr -d '\r')"
    if [[ -z "${app_path}" || ! -d "${app_path}" ]]; then
        app_path="$(find "${project_dir}" "${HOME}/.water/build_cache" -name "*.app" -type d -print -quit 2>/dev/null || true)"
    fi
    if [[ -z "${app_path}" || ! -d "${app_path}" ]]; then
        echo "::error::Packaged .app not found for ${platform}"
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

    echo "${platform}: app=${app_bytes}B executable=${executable_bytes}B (${app_path})"
    printf '%s %s %s\n' "${platform}" "${app_bytes}" "${executable_bytes}" >> "${work_dir}/measured.txt"
}

failed=0
for platform in macos ios-simulator; do
    measure_platform "${platform}" || failed=1
done
[[ -f "${work_dir}/measured.txt" ]] || { echo "::error::No platform packaged successfully"; exit 1; }

if [[ "${record}" == "1" ]]; then
    mkdir -p "${record_dir}"
    {
        echo '{'
        first=1
        while read -r platform app_bytes executable_bytes; do
            [[ "${first}" == 1 ]] || echo ','
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

while read -r platform app_bytes executable_bytes; do
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
