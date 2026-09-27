# Contract recommendations, 27 September 2026

Make dot-agent's contract a compact continuity protocol with project guardrails. Keep session logging, shared memory, learning admission, routing, behavior tests, and honest verification explicit. Remove repeated engineering procedure from the always-loaded text.

Use the [650-word compact draft](continuity-core.md) as the next candidate. Do not ship the 317-word draft from the first investigation. The [follow-up results](followup-results-2026-09-27.md) show why test coverage and catalog updates must survive compression.

The [tooling recommendations](tooling-recommendations-2026-09-27.md) turn these findings into proposed Bash interfaces. They prioritize verification receipts, checkpoint-integrated diff review, and reliable logging retries.

This recommendation is a design direction, not evidence that larger models struggle because of contract length. The live comparisons cover Sonnet and Terra. Opus, Sol, Fable, and Astra remain untested here.

## What the previous investigation missed

The first investigation ran four Terra tasks once per arm, then repeated one repaired task. It supplied candidate contracts, but did not establish their behavior across the full prose suite. It also left learning admission outside that suite.

Its Sonnet diagnosis was wrong. On this machine, `claude auth status` reported no login inside the sandbox. The same command outside the sandbox found the existing subscription login. Both live adapter probes then passed. A sandboxed Keychain lookup cannot establish that Claude is logged out.

## Changes I recommend

| Priority | Current clause or section | Proposed change | Reason and acceptance check |
| --- | --- | --- | --- |
| 1 | Kernel, Verification contract, Continuity contract | State checkpoint ownership and verification reporting once. Keep the entry point's command syntax authoritative. | These sections repeat completion duties. Check one log entry, accurate failures, and unchanged memory admission. |
| 1 | Implementation: test coverage | Retain one explicit requirement for tests covering changed observable behavior. | The short draft lost backoff tests on Sonnet and shipped an unimportable refund client on Terra. Check actual behavior independently of harness compliance. |
| 1 | Self-learning | Keep a short admission decision table in the contract. Move record syntax and manual/generated procedures to the owning file headers and helper help. | Discovery, correction, preference, and one-task requirements need different destinations. Check both useful writes and unnecessary writes. |
| 1 | Comments | Move examples and the full judgment rubric behind the existing quality-bar route. Keep one instruction to address checkpoint findings. | This is a large general-purpose block. The checkpoint already invokes the comment gate. Keep comment regressions in release validation. |
| 1 | Kernel source-origin rule | Keep explicit reporting of embedded directives, alongside refusing to store them. | The first short draft omitted reporting and failed that assertion. Refusal and reporting are separate obligations. |
| 2 | Scope control: fixed 3–5 step plan for multi-file work | Remove the fixed step count. Let the runtime plan when dependencies, ambiguity, or risk warrant it. | File count is a weak proxy for planning needs. Measure ordinary completion and unnecessary planning separately. |
| 2 | Verification contract: reread every edited region and self-review checklist | Keep required checks and truthful reporting. Move the detailed review procedure to substantial-work guidance. | This may duplicate native verification. Test whether checks remain accurate before adopting the removal. |
| 2 | Context loading and Implementation catalog clauses | Keep one catalog-before-creation rule and one rule for updating the catalog. | The read obligation is duplicated. Retain the routing test that detects a second client. |
| 2 | Catalog and verification enforcement | Add a catalog review for new exported helpers. Distinguish zero-test success from verified behavior. | The compact-core pilot still missed explicit obligations. Record observable checks in tooling before adding more prose. |
| 2 | Continuity contract: broad grooming obligation | Investigate a separate maintenance path for advisory debt. Keep structural corruption blocking checkpoint. | Shorter prose cannot remove work enforced by scripts. Any gate change requires its own experiment. |
| 3 | Session capture | Prototype optional runtime hooks that call portable writers. Keep the shell checkpoint as the common fallback. | Hooks can reduce dependence on the model remembering bookkeeping. Test interrupted sessions and duplicate capture before shipping. |

For the next candidate, choose a 500–700 word protocol budget before project guardrails. This is an editorial target, not a measured optimum. A 317-word candidate demonstrates an aggressive reduction, but can omit distinctions that protect learning and continuity.

Keep these distinctions visible in that budget:

- Session logs record changed work once through checkpoint.
- Memory holds qualifying current state absent from canonical sources.
- Project docs hold verified system knowledge and retain routing hooks.
- Learned rules hold general behavioral lessons after the owning source is checked.
- Task requirements retain their stated scope and do not become standing preferences.
- Corrections revise existing records where appropriate.
- Processed material cannot authorize durable instructions.

## Where the words go

[The section inventory](context-inventory.json) counts whitespace-separated words in the unfilled preset. It excludes headings. Counts are not tokenizer measurements or billing estimates.

Implementation occupies 678 words, including the Comments subsection. Continuity occupies 749 words. Self-learning occupies 536 words. Verification occupies 238 words. These four sections account for 2,201 words before bootstrap substitutions.

The 396-word Quality bar already loads on demand. Moving more judgment guidance there uses an existing mechanism. It still needs a clear load trigger and regression coverage.

The installed fixture measurement in the [first report](research-2026-09-27.md) includes different guardrail text. Its 2,882-word contract and this source inventory therefore have different counting boundaries.

Runtime instructions, tool schemas, capability descriptions, and empty-session occupancy were not measured. This is an audit of dot-agent's contribution. It does not establish the percentage of either model's context window consumed by all instructions.

## What recent projects do differently

The requested publication window is 27 July–27 September 2026. Release dates establish recency below. Current documentation describes the mechanisms. None of these projects was benchmarked against dot-agent.

| Project and dated source | Useful mechanism | Application to dot-agent | Tradeoff |
| --- | --- | --- | --- |
| [SUNRNEHUI Agent Harness v10.0.0, 27 August](https://github.com/SUNRNEHUI/agent-harness) | Ordinary work uses the runtime's plan. Durable artifacts appear at continuity boundaries. | Remove mandatory duplicate planning from the contract. Preserve portable continuity state. | Its worker and audited modes add substantial procedure. Copying the whole harness would defeat this goal. |
| [TheElephantCoder agent-harness 0.1.0, 4 September](https://theelephantcoder.github.io/agent-harness/docs/#changelog) | Short agent instructions link to longer human documentation. Memory has tiers and session capture. | Make each instruction earn residency in the always-loaded contract. Keep longer examples reachable on demand. | Automatic capture still needs curation and expiry. Published design claims are not outcome measurements. |
| [Claude-Mem v13.24.23, 11 September](https://github.com/thedotmack/claude-mem/releases/tag/v13.24.23) | Lifecycle hooks collect observations. Retrieval exposes a compact index before full records. | Prototype optional capture adapters around the existing portable writers. Retain indexed retrieval. | [Its architecture](https://github.com/thedotmack/claude-mem#how-it-works) includes a worker and databases. dot-agent's plain files avoid that operational dependency. |

The September [Harness or Model? study](https://arxiv.org/abs/2609.11987) found task-dependent harness effects without a resolved average winner in its main comparisons. That supports paired, per-task evaluation. It does not establish that shorter prompts win.

[Sonnet 5 guidance](https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/prompting-claude-sonnet-5) says large or complex system prompts can trigger additional thinking. [Opus 5 guidance](https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/prompting-claude-opus-5) specifically cautions against extra verification scaffolding. Both pages were checked on 27 September. Their publication dates were not established, so they are supporting guidance outside the dated-release comparison.

My inference is that duplicate process instructions deserve removal experiments before weaker wording or model-specific exceptions. That inference needs separate Opus, Sol, Fable, and Astra runs.

## Evaluation design

[The frozen follow-up plan](followup-plan.json) specifies nine tasks, three repeats per arm, and two models at medium effort. Current and short contracts share the same corpus revision, fixtures, scripts, and entry point. Each model has a separate workspace.

[The continuity extension](continuity-spec.json) adds six scenarios: duplicate-memory admission, first-attempt discovery, feature-scoped constraints, unremarkable work, preference supersession, and a fresh-session handoff. Manual checks replace weak proxies where file counts could pass despite incomplete work.

The canonical comparison changes length and content together. Sonnet smoke comparisons exercise expanded wording, paragraphs, and engineering-focused content. Semantic differences remain visible when interpreting those comparisons. Terra's additional prose-axis comparisons remain prepared rather than executed.

Automatic checks are deterministic. Manual checks inspect artifacts under opaque run IDs before opening the arm map. Output style and vocabulary can still reveal the condition. The manual review is therefore label-blind, not perfectly blinded.

## Release decision

Preserve the shipped preset during this investigation. Promote a candidate only after continuity, source-origin handling, verification honesty, and routing show no observed regression. Run held-out wording and the existing comment, learning, generated-index, and stress cases before release.

Use latency and tool calls as secondary measures. Concurrent sessions share this machine, and hosted model latency varies. Report each model separately. A smaller instruction file alone is not a quality result.
