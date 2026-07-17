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

Gloss will keep this service on demand rather than permanently resident. Future UI should show
`Starting translation service` separately from document translation and may keep the service
alive briefly while the PDF window remains active.

## Next architecture: one dispatch center

The current system has three schedulers with only partial information:

1. BabelDOC controls HTTP request concurrency through qps.
2. `BabelDOCBatchCoordinator` controls PDF merging and two active batches.
3. `CodexAppServerClient` controls thread leases and starts hedges.

The next stage should replace their independent execution decisions with one dispatch center:

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
model concurrency. The dispatch center owns the source of truth for each lane:

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
