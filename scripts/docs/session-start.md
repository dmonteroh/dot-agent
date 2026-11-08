# session-start.sh — the session-start hook

`session-start.sh` lets a harness load the node before the agent's first turn. Claude Code and Codex both run a command when a session starts and add what it prints to the model's context. This script is that command. It prints the output of `status.sh --load` under one header line, so the session opens with the node already loaded and the entry point's load step has nothing left to do.

```
session-start.sh [--max-bytes N]
```

- It finds its node from its own location, `<node>/.agent/scripts/`, and runs `status.sh --load` there. The output is byte-identical to the entry point's own call.
- The header names the call and the node: `dot-agent session-start hook: the output of `…` for the node at .agent/ follows` (`~/.agent/` for a root node). It never names an absolute path, because the `--load` output itself carries only relative ones. Both entry-point templates tell the agent to skip the load step when this block holds the output.
- `--max-bytes` is the most the harness will take. Over it, the script prints one line instead, naming the call and telling the agent to make it first. The default, 30000, is the tool-result cap `PAYLOAD_MAX_BYTES` defaults to.
- Any problem (no `status.sh`, a failed run, a bad limit) prints nothing and exits 0. The entry point's load step then runs as it always did, so the hook can only save a call, never cost a session.

The script is vendor-neutral and ships in every node. The per-harness wiring lives in [`tools/hooks/install.sh`](../../tools/hooks/install.sh), which `node.sh` runs.

## Why the limit exists

A harness cuts hook output that passes its own limit. Claude Code replaces anything over 10,000 characters with a file path and a 2,000-character preview (code.claude.com/docs/en/hooks). A cut payload is the failure `status.sh` already refuses at its own budget, so the Claude Code hook passes `--max-bytes 10000`. Codex sets the limit per hook (`additionalContextLimit`, in tokens). Its hook sets 0, which passes everything, and the script's default applies.

Most nodes pass 10,000 bytes. A filled `contract.md` alone runs near 9,000. On Claude Code those nodes get the pointer line. That still moves the load to the first call: a measured run on a question-shaped prompt, the kind that skipped the load in the 2026-10-26 bench, made `status.sh --load` its first call.

## Which files the hook goes in

`node.sh init` and `node.sh update` run the installer. The manifest's `hooks` field, `session-start` or `none`, records the choice so updates keep it. The node's tracking mode picks the files:

| Node | Claude Code | Codex | Shared through git |
| --- | --- | --- | --- |
| `track-shared`, `track-all` | `.claude/settings.json` | `.codex/hooks.json` | yes: every developer gets the hook with the repository |
| `ignore-all` | `.claude/settings.local.json` | `.codex/hooks.json` | no: both are listed in `.git/info/exclude`, which git never shares |
| root node at `$HOME` | `~/.claude/settings.json` | `~/.codex/hooks.json` | not applicable |

The installer merges into existing files. Other settings and other hooks stay. A second run changes nothing. A file it cannot parse stays byte-identical, and the installer prints the snippet to add by hand. Under `ignore-all`, a `.codex/hooks.json` the repository already tracks is left alone, because ignore-all keeps the node out of shared files. Codex has no personal project-level file to use instead.

Where the installer creates `.claude/settings.json` or `.claude/settings.local.json`, it also sets `"autoMemoryEnabled": false` unless the file already sets the key. That is the bootstrap's native-memory step, and `status.sh` reads it from either file.

The merge needs `python3`. Without it, nothing is written and the snippets print.

## What a team sees

- **Claude Code.** In a tracked mode the hook arrives with `git pull`. It does nothing until that developer's checkout has the node's scripts: `track-shared` keeps `scripts/` out of git, so each developer runs `node.sh update` once, as before. Project hooks run after the developer trusts the folder, the same trust project settings already need.
- **Codex.** Codex runs a project hook only in a trusted project, and only after the developer approves that exact hook definition with `/hooks`. The approval is per checkout path, so a new clone or worktree asks again. Until approved, Codex warns at startup, skips the hook, and the entry point loads the node.
- **Hook definitions are frozen.** Codex asks again whenever a definition changes. The commands therefore call a fixed script path with no arguments that might change. Updating dot-agent replaces the script, not the definition, and asks nobody to approve anything.
- **Policy switches win.** `disableAllHooks`, Claude Code's managed `allowManagedHooksOnly`, or Codex's `[features] hooks = false` turn the hook off. The entry point still loads the node.

To opt a node out: `node.sh update --hooks none`. It removes the hook and records `none`, so later updates leave it out.

## When it fires

Both harnesses match on how the session started. The hook matches `startup|clear|compact`:

- **`startup`** and **`clear`** begin a session with an empty context.
- **`compact`** follows a compaction, which is when the entry point re-runs the load. A block that arrives after the compaction is that re-run.
- **`resume`** and **`fork`** are left out, because they restore a conversation that already holds the load.

## Limits

- **Working directory.** The Codex command is relative to the session's working directory, like the entry point's own call. A session started in a subdirectory gets no hook, and the entry point loads the node.
- **Generated indexes.** The hook covers the `status.sh --load` step only. The `index.sh ensure` step stays with the agent.
- **What was checked live.** The hook was checked live on Claude Code 2.1.310 and Codex 0.159.0, both headless:
  - The payload arrived and was used without a tool call (2026-10-27).
  - On Claude Code, the over-limit pointer made `status.sh --load` the first call (2026-10-27).
  - After a compaction, the hook delivered the payload again on both, and the session still answered from it (2026-11-08). On Claude Code the compaction was a manual `/compact` on a resumed session. On Codex it was an automatic compaction forced with a low `model_auto_compact_token_limit`. A resumed turn after the compaction got no extra delivery.
- **Bench result.** On 2026-10-27 the `hook-mode` comparison (`evals/HOWTO.md`, "Measure the session-start hook") ran 19 evals on both CLIs and both prompt sets at three repeats. With the hook, every session started with the load. Claude's share rose from 81% and 82% without it. Pass rates did not move, with no regression and no discriminating assertion. Claude sessions cost 4.1% to 4.9% less at list price. Codex ran the load again after a delivered payload in 2 of 114 sessions. A rerun of those two evals (2026-11-08, six sessions) showed none, so the entry point's skip sentence is unchanged. Eval fixtures still build without the hook unless a run asks for it, so the corpus and node-mode comparisons are unchanged.
