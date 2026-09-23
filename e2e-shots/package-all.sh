#!/usr/bin/env bash
# Sequential `water package` for every discovered example, mirroring
# run-e2e-shard.sh's inline packaging. Logs land in e2e-logs/pkg-<example>.log;
# the packaged bundle path is the "Packaged at" line of that log.
set -uo pipefail
cd "$(dirname "$0")/.."
mkdir -p e2e-logs
for example in animation chromium drag_drop edge_layout edge_list edge_text \
    filter flow_markdown form gallery gesture gradient hover icons \
    liquid_glass list locale map markdown media_picker menu multi_window \
    navigation picker reminders reply shape snackbar starfield stress \
    typography-rtl video_player waterkit_camera_filters webview webview-cef; do
  log="e2e-logs/pkg-${example}.log"
  if grep -q "Packaged at" "${log}" 2>/dev/null; then
    echo "skip ${example} (already packaged)"
    continue
  fi
  echo "=== packaging ${example} ==="
  ./cli-bin/bin/water package --platform macos --backend apple --release \
    --path "waterui/examples/${example}" > "${log}" 2>&1
  if grep -q "Packaged at" "${log}"; then
    echo "=== ${example} OK ==="
  else
    echo "=== ${example} FAILED ==="
  fi
done
echo "ALL DONE"
