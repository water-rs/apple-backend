#!/usr/bin/env bash
# Stage a twin workspace: this repository's tree replaces
# <waterui-dir>/backends/apple so the waterui examples build the backend
# revision under test instead of the checkout waterui pins. The waterui FFI
# header is layered in, and this repo's own Examples/ are staged as waterui
# workspace members — the same staging setup-e2e.sh performs for the suite.
#
# With --cocoa-ui, that repository's tree is staged into
# <waterui-dir>/backends/cocoa-ui as well and the staged apple manifest's
# cocoa-ui dependency is rewritten to the sibling path — a session testing an
# unpushed cocoa-ui commit cannot have cargo resolve it by rev. Without it
# the git-rev dependency is kept untouched.
#
# The staged trees are synced, not copied: `git archive` exports the ref to a
# scratch dir where every staged-only transform is applied, then
# `rsync -rlp --checksum --delete --exclude=/target/` overlays it. Because -t
# is absent, transferred files get the current time — always newer than the
# cargo target cache's fingerprints — while files whose checksum is unchanged
# are not transferred and keep their mtime, so re-staging an unchanged tree
# is a build no-op and a one-line change rebuilds only what changed. --delete
# drops files the ref removed, and /target is excluded so the shared cargo
# cache inside the staged backend survives each stage (#287 — `rm -rf` on the
# staged dir used to delete it and make every re-stage a cold build).
#
# usage: stage-twin-workspace.sh <waterui-dir> [--apple-repo REPO]
#          [--apple-ref REF] [--cocoa-ui REPO [--cocoa-ref REF]]
set -euo pipefail

usage() {
  echo "usage: stage-twin-workspace.sh <waterui-dir> [--apple-repo REPO] [--apple-ref REF] [--cocoa-ui REPO [--cocoa-ref REF]]" >&2
}

waterui_dir=""
apple_repo=""
apple_ref="HEAD"
cocoa_repo=""
cocoa_ref="HEAD"

while (( $# > 0 )); do
  case "$1" in
    --apple-repo) apple_repo="${2:?--apple-repo needs a value}"; shift 2 ;;
    --apple-ref) apple_ref="${2:?--apple-ref needs a value}"; shift 2 ;;
    --cocoa-ui) cocoa_repo="${2:?--cocoa-ui needs a value}"; shift 2 ;;
    --cocoa-ref) cocoa_ref="${2:?--cocoa-ref needs a value}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*)
      echo "error: unknown option '$1'" >&2
      usage
      exit 1
      ;;
    *)
      if [[ -n "${waterui_dir}" ]]; then
        echo "error: unexpected extra argument '$1'" >&2
        usage
        exit 1
      fi
      waterui_dir="$1"
      shift
      ;;
  esac
done

if [[ -z "${waterui_dir}" ]]; then
  usage
  exit 1
fi

# Default: the repository this script lives in (…/.github/scripts/), so a
# checkout's own copy always stages that checkout.
if [[ -z "${apple_repo}" ]]; then
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  apple_repo="$(git -C "${script_dir}" rev-parse --show-toplevel)"
fi

tmp_apple="$(mktemp -d)"
tmp_cocoa=""
cleanup() {
  rm -rf "${tmp_apple}"
  [[ -z "${tmp_cocoa}" ]] || rm -rf "${tmp_cocoa}"
}
trap cleanup EXIT

mkdir -p "${waterui_dir}/backends/apple"
git -C "${apple_repo}" archive "${apple_ref}" | tar -x -C "${tmp_apple}"

# The Rust library the examples link is waterui's own checkout; the Swift
# side must see its declarations, not the snapshot the backend repo last
# synced.
cp "${waterui_dir}/ffi/waterui.h" "${tmp_apple}/Sources/CWaterUI/include/waterui.h"

if [[ -n "${cocoa_repo}" ]]; then
  tmp_cocoa="$(mktemp -d)"
  mkdir -p "${waterui_dir}/backends/cocoa-ui"
  git -C "${cocoa_repo}" archive "${cocoa_ref}" | tar -x -C "${tmp_cocoa}"

  # rev-pinned git deps cannot be redirected by [patch]; a local staging
  # rewrites the dep itself to the sibling checkout. The assert fails loudly
  # when the expected line is absent — a silently kept git dep would resolve
  # the published rev instead of the tree under test.
  python3 - "${tmp_apple}/Cargo.toml" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
s2 = re.sub(
    r'cocoa-ui = \{ git = "[^"]*", rev = "[^"]*" \}',
    'cocoa-ui = { path = "../cocoa-ui" }',
    s,
)
assert 'cocoa-ui = { path = "../cocoa-ui" }' in s2, "cocoa-ui dep line not found in staged manifest"
open(p, "w").write(s2)
PY
fi

rsync -rlp --checksum --delete --exclude=/target/ "${tmp_apple}/" "${waterui_dir}/backends/apple/"

# Apple-specific examples live in this repository (Examples/README.md); staged
# into the framework checkout they are workspace members like any other
# example, so discovery, the shards, baselines, and twins all see them.
if [[ -d "${tmp_apple}/Examples" ]]; then
  for example_dir in "${tmp_apple}"/Examples/*/; do
    [[ -f "${example_dir}/Cargo.toml" ]] || continue
    example="$(basename "${example_dir}")"
    mkdir -p "${waterui_dir}/examples/${example}"
    rsync -rlp --checksum --delete --exclude=/target/ "${example_dir}/" "${waterui_dir}/examples/${example}/"
  done
fi

if [[ -n "${cocoa_repo}" ]]; then
  rsync -rlp --checksum --delete --exclude=/target/ "${tmp_cocoa}/" "${waterui_dir}/backends/cocoa-ui/"
fi

echo "twin workspace staged: ${waterui_dir}"
