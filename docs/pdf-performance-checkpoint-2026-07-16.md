# PDF translation performance checkpoint — 2026-07-16

This document archives the first complete BabelDOC performance pass for Gloss. It records
successful changes and rejected experiments so later work does not repeat measurements or
mistake normal Spark variance for an optimization.

## Scope and reference document

- Pipeline: BabelDOC 0.6.3, Gloss loopback OpenAI-compatible bridge, Codex subscription provider.
- Model: `gpt-5.3-codex-spark`, document reasoning `low`.
- Machine: Apple silicon macOS, CoreML ONNX execution provider.
- Reference PDF: *Attention Is All You Need*, 15 Letter-size pages.
- Input text: 33,487 valid characters, approximately 9,685 text tokens.
- Benchmarks below use Mono output, selectable-text scan detection skipped, and translation
  caches ignored unless noted.
- Wall time includes Python and ONNX startup. BabelDOC time begins after its CLI/model setup.
  Translation window measures the first through last Gloss model work for the document.

## Current reliable configuration

- BabelDOC upstream prefetch: qps 8 and 8 worker threads.
- Gloss model concurrency: 2 background turns.
- Codex pool: 3 prewarmed threads; one remains available for interactive work or a tail hedge.
- Cross-request batch: up to 12 items and 1,800 source characters.
- Initial fill window: 25 ms; refill delay: 0 ms.
- Document reasoning: `low`, the minimum supported by Spark.
- Slow model-wait observation: 3 seconds; hedge threshold: 8 seconds.
- Successful thread rotation: 10 turns.
- Output mode is exclusive: generate Mono or Dual, never both in one run.

The best verified run was:

| Metric | Result |
| --- | ---: |
| End-to-end wall time | 80.75 s |
| BabelDOC internal time | 66.89 s |
| Model translation window | 40.09 s |
| Codex model turns | 32 |
| Cumulative model wait across two lanes | 61.17 s |
| Longest Codex turn | 4.79 s |
| BabelDOC paragraphs | 199 |
| Successful without BabelDOC fallback | 187 |
| Fallback paragraphs | 12 |
| Mono output size | 2.3 MB |

Compared with the previous no-cache optimized run at 118.56 seconds, the best run is 31.9%
faster. Compared with the original 143.99-second run, it is 43.9% faster. These are observed
best-run comparisons, not yet p50 or p95 claims.

All 15 output pages were rendered at 100 dpi and inspected. The result retained page count and
page size, contained no empty pages, and showed no obvious clipping, black pages, missing
sections, or broken figures. Page 1 and page 10 were also inspected at full-page resolution.

Local evidence from this checkpoint remains under:

- `tmp/babeldoc-extreme-qps8-b1800-20260716-205338/`
- `tmp/pdfs/extreme-b1800-contact-sheet.png`
- `tmp/performance-analysis-20260716/`

The `tmp` tree is deliberately ignored by Git; this Markdown file is the durable record.

## Performance decomposition after service startup

Once DocLayout is ready, the fastest 66.89-second BabelDOC run divides into three useful
regions:

| Region | Approximate wall time | Notes |
| --- | ---: | --- |
| Parse and layout analysis | 14–17 s | PDF IR, page layout, paragraphs, formulas and styles |
| Model translation | 35–42 s | Dominant source of run-to-run variance |
| Typesetting, font subsetting and save | 12–13 s | Stable fixed cost for this document |

This decomposition is the basis for future work. Service startup progress should be displayed
separately and should not be mixed into document translation progress.

## Successful findings

### Bounded cross-request batching

The original bridge allowed BabelDOC request shape to determine model work too directly. A
dedicated coordinator now accepts qps 8 input, merges compatible concurrent requests, and keeps
the model at two background lanes. Moving from 8 items / 1,200 characters to 12 items / 1,800
characters reduced the model window from 76.09 seconds to about 40 seconds in the best run.

### Three prewarmed threads with only two normal PDF lanes

Two background lanes keep Spark productive without the contention observed at three normal
PDF lanes. The third lane is reserved for interactive work and may be used for a carefully
controlled tail hedge.

### Lowest supported reasoning

`low` is accepted by Spark and is the correct PDF default. A live `minimal` experiment returned
HTTP 400: the Spark deployment supports only `low`, `medium`, `high`, and `xhigh`.

### Skip scanned-document detection for reliable text PDFs

Gloss samples the PDF text layer before launch. When most sampled pages contain meaningful
selectable text, it passes `--skip-scanned-detection` without changing the layout pipeline.

### Mono/Dual exclusivity

Gloss launches BabelDOC with `--no-dual` or `--no-mono`, avoiding the previous behavior of
generating two output PDFs when the user requested one.

## Rejected or inconclusive experiments

| Experiment | Observed result | Decision |
| --- | --- | --- |
| qps 8 with 8 items / 1,200 chars | 123.13 s wall, 81.64 s model window | QPS alone does not help |
| qps 12, 24 items / 1,800 chars, 2 lanes | 82.99 s wall, 39.38 s model window | No reliable end-to-end gain |
| 3 normal PDF model lanes | 81.27 s wall, 37.52 s model window | More Spark pressure for negligible wall gain |
| 24 items / 2,400 chars | 85.73 s wall, 40.34 s model window | Larger generation offsets fewer turns |
| BabelDOC process pool | 43.78 s translation-free control and about 2 GB peak memory | Slower and much heavier |
| Skip formula offset calculation | 39.29 s control versus 37.54 s without it | Slower on the reference PDF |
| `--skip-clean` | Post stage stayed near 12 s; output grew from 2.3 MB to 27 MB | Reject as default |
| Disable same-text fallback | 30–31 turns versus 32, but 79.16–84.82 s wall | No stable gain; preserves less safety |
| Spark `minimal` reasoning | HTTP 400 unsupported-value errors | Invalid for this model |
| Hedge every model wait over 3 s | 4 hedges, 3 wins, but 82.35 s wall / 68.53 s internal | Independent hedges create scheduler contention |

The three-second hedge run is especially important. Although three hedges won their races, the
third thread temporarily raised active background work to three and normal work then waited
0.8–2.4 seconds for a thread. A local optimization made the complete pipeline slower than the
80.75-second default.

## Dispatch packing follow-up

The first dispatch-center increment replaced FIFO-prefix packing with bounded best-fit packing.
It always anchors the oldest compatible item to prevent starvation, then fills the remaining
character budget with the largest compatible waiting items that fit. The dispatcher now logs
`utilization_pct` for every batch. An opt-in end-to-end XCTest also makes the full no-cache
BabelDOC benchmark reproducible without hand-written token configuration files.

Three fresh runs used the same reference paper, a restarted Gloss process for an empty broker
cache, qps 8, 12 items, 1,800 characters, two model lanes and refill delay 0:

| Run | Wall | BabelDOC | Model turns | Model window | Cumulative model wait | Queue wait |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 82.14 s | 67.36 s | 32 | 39.46 s | 55.51 s | 0 ms |
| 2 | 84.35 s | 69.95 s | 33 | 44.02 s | 63.78 s | 0 ms |
| 3 | 78.83 s | 65.03 s | 34 | 40.36 s | 59.84 s | 0 ms |
| p50 / worst | 82.14 / 84.35 s | 67.36 / 69.95 s | 33 / 34 | 40.36 / 44.02 s | 59.84 / 63.78 s | 0 ms |

Best-fit made many large-text batches reach 95–99% of the character budget and the synthetic
`900, 900, 100, 100` case now needs two turns instead of three. It did not reduce the real
paper's median turn count below the prior 32-turn best. This is a safe queue-quality improvement,
not yet a measured end-to-end speedup.

An additional qps-aligned refill experiment waited 125 ms whenever the waiting queue was not
already full. It increased average character utilization to 64.7%, but still used 34 model
turns and regressed to 95.06 seconds wall / 80.72 seconds BabelDOC / 45.47 seconds model window.
Refill delay therefore remains 0. The result rejects fixed queue waiting as a substitute for a
dispatcher that understands upstream backlog and lane state.

### Why same-text fallback is not the next target

BabelDOC reported 12 fallback paragraphs in the reference run. Disabling same-text fallback
reduced that count to one, but the repeated text was already deduplicated or cached by
`TranslationBroker`. The model-turn reduction was only one or two turns and was smaller than
ordinary Spark variance. Visual rendering and text-layer checks found no regression in this
paper, but the option could leave a genuinely untranslated English paragraph unchanged in a
different document. It remains an opt-in experiment.

## On-demand DocLayout resource measurement

The ONNX model is 72 MB on disk. Direct local measurements produced:

| Measurement | Result |
| --- | ---: |
| Model construction | 8.3–8.7 s |
| Short startup RSS peak | about 1.1 GB |
| Idle RSS after load | about 506 MB |
| RSS after one page inference, then idle | about 556 MB |
| Idle CPU over ten seconds | below 0.04% of one core |

Gloss keeps this service on demand rather than permanently resident for the whole app. The batch
PDF window now starts one loopback-only service when the module opens, reuses it across queued
documents, and stops it when the window closes. The UI reports service startup separately from
document translation. Documents run serially so the resident model removes repeated startup cost
without multiplying BabelDOC memory peaks.

## Dispatch-center architecture

The current system has three schedulers with only partial information:

1. BabelDOC controls HTTP request concurrency through qps.
2. `BabelDOCBatchCoordinator` controls PDF merging and two active batches.
3. `CodexAppServerClient` controls thread leases and starts hedges.

The first implementation stage now routes every real cache miss through one dispatch center:

```text
web / selection / subtitles / BabelDOC producers
                    ↓
TranslationBroker cache and in-flight deduplication
                    ↓
TranslationDispatchCenter
  priority · batching · backpressure · cancellation · lane state · tail hedge
                    ↓
provider executor (Codex threads or local llama)
```

Upstream qps becomes admission and prefetch only. It may enqueue quickly, but it cannot create
model concurrency. The center enforces three total jobs and two background jobs, prioritizes
interactive then visible then background work with FIFO inside each priority, propagates
cancellation, and publishes a state snapshot. BabelDOC also reports its not-yet-dispatched
backlog into that state. Codex checks both layers before admitting a gated tail hedge, so a
hedge cannot start while known real work is queued.

Provider-local scheduling remains as an executor safety net in this stage. The dispatch center
is now the admission authority, while the provider still maps admitted work to a physical Codex
thread or llama slot. Later work can remove that duplicated safety layer after live mixed-workload
validation.

A live dispatch-center regression run took 96.23 seconds wall / 81.35 seconds BabelDOC, but the
center's 36 admissions waited only 11 ms cumulatively (2 ms maximum), background active jobs
never exceeded two, and Codex thread queue wait remained zero. The regression was explained by
79.70 seconds of cumulative Spark model wait and five 4–9.6 second turns, not local dispatch.

The previously rejected three-second hedge threshold was then repeated with dispatch admission.
The run took 84.75 seconds wall / 70.76 seconds BabelDOC with 33 model turns. Four model waits
crossed three seconds; all four were skipped because the upstream queue still held 9–13 real
items. No hedge started and normal queue wait remained zero. Gloss therefore uses a three-second
gated threshold when the shared dispatch state is available, while standalone Codex clients keep
the conservative eight-second default.

The final production build was restarted without a hedge environment override. A real background
document translation succeeded through Spark, and the runtime reported `threads=3`,
`background_limit=2`, `hedge_ms=3000`, and `dispatch_aware=true`.

The dispatch state represents:

- idle;
- running a real job;
- waiting for the model;
- streaming output;
- running a hedge;
- reserved for interactive work.

Initial scheduling policy:

1. Interactive selection work always outranks visible-page, subtitle, and background document
   work.
2. Two lanes run normal PDF batches.
3. The third lane remains interactive capacity while real work is queued.
4. A hedge is allowed only when the dispatcher is near the document tail, no real batch will be
   delayed, and a spare lane is still idle.
5. Compatible queued items use bounded best-fit packing rather than letting the first item that
   does not fit stop the batch.
6. QPS, model concurrency, and hedge budget are separate metrics and configuration values.

Expected benefit is primarily lower variance and less scheduler-induced waiting. It is not
expected to halve the 40-second model service time by itself. A realistic first target is a
stable 2–6 second reduction and near-zero normal queue wait while preserving interactive
capacity.

## Second optimization sweep

The next sweep deliberately tested fixed PDF work outside the dispatcher and more aggressive
upstream/model policies. Failed experiments were removed from production code after measurement.

### Fast PDF postprocessing: visually correct, text-layer regression

An experimental path asked BabelDOC for its unclean 28 MB output, then used the Python runtime's
PyMuPDF to subset fonts, compress, validate page count and render every page. In a warm-cache
paired run, the traditional path took 55.49 seconds wall / 36.95 seconds BabelDOC. The fast path
took 51.16 seconds wall / 33.89 seconds BabelDOC plus 0.96 seconds of postprocessing. Output size
was 3.0 MB, and all 15 pages were visually equivalent at 100 dpi.

The visual result hid a real regression: native BabelDOC output mapped spaces to usable nonbreaking
spaces, while the reconstructed text layer exposed 817 `0x01` control characters. Copy, search and
downstream extraction would be worse even though rendered pixels were nearly identical. The fast
postprocessor was therefore rejected and removed. The result also confirms that BabelDOC's font
subsetting must happen before its final save; it cannot be faithfully reconstructed from an
already-saved `--skip-clean` PDF.

### Upstream QPS after unified dispatch

Higher QPS did not violate the two-lane model limit, and normal Codex queue wait remained zero.
It did reduce model turns at QPS 24, but larger, earlier batches produced heavier Spark tails:

| Configuration | Wall | BabelDOC | Model turns | Model window | Cumulative wait | Longest wait |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| QPS 16, run 1 | 96.12 s | 80.90 s | 32 | 52.39 s | 75.79 s | 11.87 s |
| QPS 24, run 1 | 91.84 s | 77.77 s | 29 | 56.66 s | 90.97 s | 28.17 s |
| QPS 24, run 2 | 70.83 s | 57.83 s | 29 | 36.31 s | 58.53 s | 3.76 s |
| QPS 24, run 3 | 94.85 s | 81.13 s | 29 | 57.05 s | 84.84 s | 13.60 s |

QPS 24 achieved a new best run, but its 91.84-second p50 and 94.85-second worst result were worse
than the established QPS 8 p50 of 82.14 seconds. QPS 8 remains the production default. This also
shows why turn count alone is not a sufficient optimization metric.

### Forced hard-tail hedge: rejected

A two-level policy deferred the normal three-second hedge while real work was queued, then forced
one hedge after eight seconds on the reserved third thread. The hedge won, but raised active
background work to three and made the next normal batch wait 2.24 seconds for a thread. The run
took 102.45 seconds wall / 85.65 seconds BabelDOC with a 55.35-second model window. The forced
policy was removed. Dispatch-aware hedges remain allowed only when both the center and BabelDOC
upstream backlog are empty.

### Compact provider-local item identifiers: retained

The Codex prompt previously repeated BabelDOC's UUID-shaped item identifiers in both input and
model output. Codex now maps those identifiers to base-36 batch-local indices and restores the
original IDs after strict `id` and `index` validation. This changes neither the broker API nor
the output ordering.

Three no-cache QPS 8 runs completed successfully. Their model output-stream totals were 8.58,
10.12 and 11.45 seconds (p50 10.12 seconds) for 187 completed items. The adjacent long-ID QPS 8
control used 10.48 seconds. The measured median latency gain is small, about 0.36 seconds, but the
token reduction is deterministic and the mapping is isolated to the provider. All 15 pages of
the third run rendered normally, all pages retained selectable text, and every page remained
Letter size. The optimization is retained as a low-risk efficiency improvement, not presented as
an end-to-end breakthrough.

The live benchmark XCTest now accepts `GLOSS_BABELDOC_BENCHMARK_QPS`,
`GLOSS_BABELDOC_BENCHMARK_PAGE_GROUP_SIZE`, and `GLOSS_BABELDOC_BENCHMARK_OUTPUT_MODE`, so future
QPS, page-group, and Mono/Dual comparisons use the same reproducible entry point.

## Real-time progress and page-group checkpoint — 2026-07-17

BabelDOC already exposes structured `progress_start`, `progress_update`, and `progress_end`
events internally. Its CLI renders those events with Rich, which collapses to a final progress
table when stdout is a pipe. Gloss now launches the installed BabelDOC Python environment through
a small instrumentation runner. The runner replaces only the CLI progress renderer and emits
bounded NDJSON; translation configuration, parsing, translation, typesetting, and result merging
remain BabelDOC code. The runner uses a guarded `__main__` entry and `freeze_support()` so macOS
spawned parser processes import it without recursively launching the CLI.

Gloss maps the native stages into product phases and displays live progress for service startup,
parse/layout, model translation, typesetting/style restoration, and PDF save. The PDF window also
reads document-turn measurements from the shared dispatch state and shows model preparation and
model wait separately. The final runtime log persists wall time, every BabelDOC phase, cumulative
model preparation/wait/output time, and model-turn count.

A warm-cache 15-page smoke run verified the event path end to end:

| Region | Measured wall time |
| --- | ---: |
| Python, BabelDOC, and DocLayout startup | 15.88 s |
| Parse and layout | 10.89 s |
| Translation phase | 1.92 s |
| Typesetting and drawing | 3.22 s |
| Font subset and save | 7.59 s |
| End to end | 39.51 s |

The short translation phase is a warm-cache result and is not a new cold-model performance claim.
The generated Mono PDF retained all 15 Letter-size pages and a 2.3 MB cleaned output. Every page
was rendered at 90 dpi and inspected; no page was empty, clipped, black, reordered, or missing a
figure.

The same checkpoint tested BabelDOC's built-in page splitting at 12 pages per part. An initial
instrumentation run lacked a guarded Python entry point, recursively entered the CLI from a macOS
spawned child, and was discarded. After adding `__main__` and `freeze_support()`, the valid warm
12+3 page run took 59.43 seconds wall / 44.52 seconds inside BabelDOC, compared with 39.51 / 25.83
seconds for one part. Parse rose from 10.89 to 14.97 seconds and subset/save from 7.59 to 22.20
seconds. The result still retained all 15 Letter-size pages, and every page rendered normally.

BabelDOC's current split loop processes parts serially and repeats expensive parse, font, save,
and merge work, so smaller parts are not a pipeline. Production therefore keeps the existing
50-page part size while retaining an explicit request-level page-group parameter, the opt-in
`GLOSS_BABELDOC_PAGE_GROUP_SIZE` override, and native part progress for future experiments. Real
overlap still requires a BabelDOC core change that pipelines a later part's parse work with an
earlier part's model translation inside one managed process.

## Larger follow-up opportunities

After the dispatch center is measured:

1. Pipeline page-group parsing and translation so the first translated batches overlap later
   layout work. Potential gain: roughly 8–15 seconds, but this requires BabelDOC core changes.
2. Investigate reusable pre-subset target fonts. The current four target fonts make subsetting
   and clean save cost 12–13 seconds. A safe common-glyph subset could trade a moderately larger
   PDF for several seconds without the 27 MB `--skip-clean` result.
3. Cache layout/IR by source PDF hash for repeat translations or switching output mode. This does
   not improve the first run but can remove most of the 14–17 second parse stage on repeats.

## Acceptance criteria for the next checkpoint

- Run at least three no-cache translations of the same reference PDF.
- Report p50 and worst observed post-start, model-window, and end-to-end times.
- Keep normal PDF queue-wait p95 close to zero.
- Report real jobs, hedge attempts, hedge wins, and duplicated Spark work separately.
- Preserve 15/15 pages, text layer, figures, page dimensions, and normal cleaned output size.
- Render and inspect every page after any BabelDOC output-path or font change.
