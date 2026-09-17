#!/usr/bin/env bash
# Prepares a waterui checkout for driving the examples: checks out waterui at
# the commit matching the current flow (main for main-gate, dev otherwise),
# initializes whatever submodules that revision still records (none, since
# water-rs/waterui#937; older revisions carry workspace members there), and replaces
# `backends/apple` with this repository's tested tree so the suite exercises the
# commit under test rather than the submodule waterui has pinned. The committed
# FFI header is then synced from the cloned waterui, matching what
# `setup-waterui.sh` does for the package build legs. The `water` CLI lives in
# its own repository now (water-rs/cli); it is checked out alongside so the
# `cargo install --path` legs have a directory to build.
#
# Inputs: WATERUI_REF/WATER_CLI_REF name a branch or tag (a full 40-hex commit
# is accepted verbatim); WATERUI_SHA/WATER_CLI_SHA name the resolved commits
# directly and take precedence. Every job in the e2e workflows runs this
# script independently, so ref inputs are resolved once — in the `prepare`
# job, which publishes the SHAs as job outputs — and every consumer fetches
# exactly those commits. A branch that moves mid-run cannot split the
# certification across two different framework or CLI commits.
set -euo pipefail

repo_root="${GITHUB_WORKSPACE:-$(pwd)}"
waterui_dir="${repo_root}/waterui"
cli_dir="${repo_root}/water-cli"

if [[ -n "${WATERUI_REF:-}" ]]; then
  waterui_ref="${WATERUI_REF}"
elif [[ "${GITHUB_BASE_REF:-}" == "main" || "${GITHUB_REF_NAME:-}" == "main" ]]; then
  waterui_ref="main"
else
  waterui_ref="dev"
fi
cli_ref="${WATER_CLI_REF:-dev}"

# A 40-hex input already names a commit; anything else is a branch or tag and
# is resolved against the remote here.
resolve_commit() {
  local url="$1" ref="$2" sha
  if [[ "${ref}" =~ ^[0-9a-fA-F]{40}$ ]]; then
    printf '%s\n' "${ref}"
    return 0
  fi
  sha="$(git ls-remote "${url}" "refs/heads/${ref}" | awk 'NR == 1 {print $1}')"
  if [[ -z "${sha}" ]]; then
    sha="$(git ls-remote "${url}" "refs/tags/${ref}" | awk 'NR == 1 {print $1}')"
  fi
  if [[ -z "${sha}" ]]; then
    echo "::error::Could not resolve '${ref}' to a commit on ${url}." >&2
    return 1
  fi
  printf '%s\n' "${sha}"
}

# `git clone --branch` does not accept a bare SHA; fetch the pinned commit
# directly instead, keeping the clone shallow.
checkout_commit() {
  local url="$1" sha="$2" dir="$3"
  rm -rf "${dir}"
  git init -q "${dir}"
  git -C "${dir}" remote add origin "${url}"
  git -C "${dir}" fetch -q --depth 1 origin "${sha}"
  git -C "${dir}" checkout -q --detach FETCH_HEAD
}

waterui_sha="${WATERUI_SHA:-$(resolve_commit https://github.com/water-rs/waterui.git "${waterui_ref}")}"
cli_sha="${WATER_CLI_SHA:-$(resolve_commit https://github.com/water-rs/cli.git "${cli_ref}")}"

echo "Using waterui ${waterui_ref} (${waterui_sha})"
checkout_commit https://github.com/water-rs/waterui.git "${waterui_sha}" "${waterui_dir}"
git -C "${waterui_dir}" submodule update --init --depth 1

echo "Using water-cli ${cli_ref} (${cli_sha})"
checkout_commit https://github.com/water-rs/cli.git "${cli_sha}" "${cli_dir}"

# `backends/apple` is consumed by example builds as a SwiftPM path dependency,
# not through git; replacing the directory wholesale with the tested tree is
# the whole point of the suite.
rm -rf "${waterui_dir}/backends/apple"
mkdir -p "${waterui_dir}/backends/apple"
git -C "${repo_root}" archive HEAD | tar -x -C "${waterui_dir}/backends/apple"

# The Rust library the examples link is waterui's own checkout; the Swift side
# must see its declarations, not the snapshot the backend repo last synced.
cp "${waterui_dir}/ffi/waterui.h" "${waterui_dir}/backends/apple/Sources/CWaterUI/include/waterui.h"

# Apple-specific examples live in this repository (Examples/README.md); staged
# into the framework checkout they are workspace members like any other
# example, so discovery, the shards, baselines, and twins all see them.
for example_dir in "${repo_root}"/Examples/*/; do
  [[ -f "${example_dir}/Cargo.toml" ]] || continue
  example="$(basename "${example_dir}")"
  rm -rf "${waterui_dir}/examples/${example}"
  cp -R "${example_dir}" "${waterui_dir}/examples/${example}"
done

if [[ -n "${GITHUB_ENV:-}" ]]; then
  {
    echo "WATERUI_DIR=${waterui_dir}"
    echo "WATERUI_REF=${waterui_ref}"
    echo "WATERUI_SHA=${waterui_sha}"
    echo "WATER_CLI_DIR=${cli_dir}"
    echo "WATER_CLI_REF=${cli_ref}"
    echo "WATER_CLI_SHA=${cli_sha}"
  } >> "${GITHUB_ENV}"
fi

# The `prepare` job reads these back as job outputs and hands them to every
# consumer; writing them unconditionally is harmless in the other jobs.
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "waterui_ref=${waterui_ref}"
    echo "waterui_sha=${waterui_sha}"
    echo "cli_ref=${cli_ref}"
    echo "cli_sha=${cli_sha}"
  } >> "${GITHUB_OUTPUT}"
fi

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "### Certified inputs"
    echo "- backend: \`${GITHUB_SHA:-$(git -C "${repo_root}" rev-parse HEAD)}\`"
    echo "- waterui: \`${waterui_sha}\` (${waterui_ref})"
    echo "- water CLI: \`${cli_sha}\` (${cli_ref})"
  } >> "${GITHUB_STEP_SUMMARY}"
fi
