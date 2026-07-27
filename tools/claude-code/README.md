# Claude Code settings

Optional Claude Code wiring for the [dot-agent operating model](../../operating-model.md).

`settings-example.json` ships two things:

- `"autoMemoryEnabled": false`, the setting the bootstrap copies so `.agent/` stays the sole durable memory (see the operating model's [Native tool memory](../../operating-model.md#native-tool-memory)).
- A permissions allowlist for reading and writing `.agent/**`, so the self-maintenance contract doesn't hit permission prompts.

Merge the relevant sections into your `~/.claude/settings.json` (user-level) or the project's `.claude/settings.json` (committed in `track-shared`/`track-all` modes so the setting holds for every developer).

Compliance rests on the trust contract plus the load-path status check (`scripts/status.sh`); there is no mechanical enforcement layer. The V4/V5-era compliance hooks were removed in V6.1; see `CHANGELOG.md` if you're looking for them.

For the optional skills that package the rare in-session procedures (grooming, retro), see [`tools/skills/`](../skills/).
