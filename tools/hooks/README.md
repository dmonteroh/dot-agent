# Session-start hooks

`install.sh` wires `.agent/scripts/session-start.sh` into Claude Code and Codex as a session-start hook. The harness then runs it at the start of each session and after each compaction, and the model receives the node's `status.sh --load` output before its first turn.

`node.sh init` and `node.sh update` run it, so most nodes never call it directly. Run it yourself to repair or remove the wiring:

```bash
bash tools/hooks/install.sh <project root>
bash tools/hooks/install.sh --remove <project root>
```

To keep a node's choice across updates, use `node.sh update --hooks session-start` or `--hooks none` instead. Those record it in the manifest, and a bare `install.sh --remove` is undone by the next update.

The node's tracking mode decides which files change, and the installer merges into them without touching other settings or other hooks. It needs `python3` for the merge. Without it, it prints the JSON to add by hand. [`scripts/docs/session-start.md`](../../scripts/docs/session-start.md) covers the file table, what a team sees, Codex's one-time `/hooks` approval, and what was verified live.

The hook loads context. It enforces nothing, so it is not a return of the compliance hooks V6.1 removed.
