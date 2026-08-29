# Performance Contract

ZigUI performance claims are validated on named hardware and never inferred
from implementation style alone.

## Required behavior

- An idle window performs no redraw and no GPU submission.
- A fully occluded Windows surface stops presenting after DXGI reports
  occlusion and resumes from the next native exposure paint; it is never
  polled in an application-driven hot loop.
- An unchanged steady-state frame performs no general-purpose allocation.
- Per-window frame scratch grows lazily through a hard bounded allocator and
  releases capacity above its retention threshold on reset.
- No per-frame GPU resource is created after warm-up.
- Component reconciliation is limited to invalidated component boundaries.
  Scene generation visits the current visible retained tree; virtual lists and
  spatial canvases expose only visible plus overscan content, never their total
  logical data set.
- Every framework-owned retained cache and object table has a hard byte or
  entry limit; replacement paths may briefly own old and proposed values within
  their documented aggregate budget.
- Dynamic native event queues are bounded by both event count and aggregate
  owned payload bytes.
- GPU resources are reused only after submission completion.
- No error silently activates a CPU renderer.

## Initial budgets

- 60 Hz and 120 Hz presentation deadlines on the selected baseline hardware.
- At most 50 ms p95 input-to-present latency.
- Memory proportional to visible plus overscan rows for a 10,000-row list.
- Visibility-proportional processing for a 10,000-object spatial canvas.
- No monotonic resident-memory growth over a 10,000-frame stress run.
- At most 5 MiB for the stripped macOS arm64 `hello` executable, excluding
  system frameworks and symbols.
- A core-only compilation must not compile platform, GPU, font, image, media,
  network, serialization, inspection, or tracing implementations.
- No build invokes a third-party package manager, `pkg-config`, or a
  third-party code generator.

## Always-available counters

Low-cost counters cover frame phases, invalidations, allocations, live bytes,
scene primitives, uploads, atlas use, cache hits and misses, GPU submissions,
resource creation, dropped/coalesced events, and input-to-present latency.
`core.metrics.PresentationStats` additionally retains a fixed 256-sample ring
of successful presentation timestamps and optional input latencies, exposing
nearest-rank p50/p95/p99 values, dropped submissions, the latest
platform-reported refresh rate, and current/maximum missed-deadline streaks.
Recording happens after a successful renderer submit/present result and does
not schedule frames or impose a refresh-rate policy. A zero reported refresh
rate disables only deadline accounting; timestamp and percentile evidence
remain available.
Detailed journaling is compile-time optional.

Allocator byte counters require the caller to wrap its allocator with
`core.TrackedAllocator`; the remaining framework counters do not. Path cache
bytes describe retained command/vertex payload. Path construction is also
bounded independently by per-batch edge, work-unit, upload, and scene limits.
Retained-node, platform-text, clipboard-ownership, menu, action-name,
display/dialog, and native-protocol budgets are refusal boundaries and are
included in stress and allocation-failure coverage.

## Measured baseline

The 2026-08-24 consolidated campaign used an Apple M3 Pro MacBook Pro with
18 GB memory, macOS 27.0, and Zig `0.17.0-dev.1745+ac8a8d0c5`.

- The deterministic stress executable completed 10,000 frames and 2,580,000
  scene primitives.
- Tracked live bytes remained exactly 24,305,827 before and after the measured
  interval; peak tracked live bytes were 24,557,299.
- Allocation count remained 667 before and after warm-up, proving zero
  post-warm-up general-purpose allocations in that run.
- The stripped arm64 macOS `hello` executable was 1,065,016 bytes, including
  its embedded Metal library and excluding only system frameworks loaded by
  macOS. This is below the 5 MiB budget.

These figures are a reproducible baseline, not a universal latency claim.
The fixed presentation ring makes frame-interval and input-to-present
percentiles available to workload traces without allocations, but the values
still require workload-specific profiling on each deployment machine. A
display-link callback count is not presentation evidence; use
`frames_presented`, `presentation.presented_count`, the retained timestamps,
and the platform-reported refresh rate from the same run.
