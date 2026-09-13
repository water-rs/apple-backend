# E2E screenshot baselines

Each nightly run (`nightly.yml`) builds and launches every runnable example in
the waterui repository on an iOS simulator and on macOS, captures the first
settled screen, and compares the capture against the PNG recorded here, per
platform (`ios/`, `macos/`).

- `<example>.png` — the recorded baseline. When no baseline exists the example
  still has to launch and produce a non-blank capture; only the pixel
  comparison is skipped.
- `<example>.skip` — an empty marker that skips pixel comparison for an
  example whose first screen cannot be made deterministic (continuous
  animation, live media). The launch and non-blank checks still apply.
- `<example>.parity-skip` — an empty marker that skips the SwiftUI parity
  comparison for an example with a registered twin while a known divergence
  is worked down.

## SwiftUI parity

Examples with a twin registered in `Tests/E2EReference` are additionally
compared against the twin rendered live by the reference host on the same
runner — the backend must stay pixel-faithful to what SwiftUI produces for the
same layout, not only to its own recorded baseline. `parity-budgets.json`
holds the allowed diff fraction per platform per twin; twins absent from the
file are held to the strict default (2%). Recorded budgets are the measured
divergence plus headroom — raise them only alongside a filed issue for the
divergence they bless.

## Recording

Baselines are recorded on CI, not locally: window metrics, scale factors, and
OS rendering all differ across machines, so a locally recorded baseline fails
on the runner. Dispatch the `Nightly E2E` workflow with
`record_baselines: true`; the `publish-baselines` job merges the captures and
opens a PR against `dev`. Review that PR image by image — an unexpected visual
change is a regression report, not a rubber stamp.

## Tuning

`run-e2e-shard.sh` accepts `DIFF_TOLERANCE` (per-channel delta, default 16/255)
and `DIFF_BUDGET` (fraction of pixels allowed to differ, default 0.02), both
read by `compare-screenshots.swift`.
