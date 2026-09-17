---
title: "nightly: the example e2e suite is red"
---

The nightly e2e suite failed: {{ env.RUN_URL }}

Certified inputs: backend `{{ env.BACKEND_SHA }}`, waterui `{{ env.WATERUI_SHA }}` ({{ env.WATERUI_REF }}), water CLI `{{ env.CLI_SHA }}` ({{ env.CLI_REF }}).

Each shard packages every runnable example from the waterui repository in
release mode and launches the `.app` on an iOS simulator and on macOS,
captures the first settled screen, and verifies it — non-blank always,
pixel-compared where a baseline exists under `Tests/E2EBaselines`. The
`e2e-shots-*` artifacts carry every capture and the amplified diff images;
`e2e-logs-*` carry the packaging and launch-marker logs for failed shards.
Read the failing job's log, fix the root cause on a topic branch, and
close this issue when the next nightly is green. If the new output is correct,
re-record the baselines by dispatching the `Nightly E2E` workflow with
`record_baselines: true`.
