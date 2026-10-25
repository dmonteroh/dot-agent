# Optional lifecycle capture prototype

`capture.sh` records a starting fingerprint in private runtime state. It compares that fingerprint with live inputs after work or interruption. It never creates memory, learned rules, verification claims, or session-log entries.

```sh
bash .agents/scripts/capture.sh begin --id <session-id>
bash .agents/scripts/capture.sh end --id <session-id>
bash .agents/scripts/capture.sh show --id <session-id>
bash .agents/scripts/capture.sh clear --id <session-id>
```

Use `--root` when the caller runs elsewhere. A runtime hook adapter must supply a stable, unique session ID. No vendor-specific hook or JSON parser is installed automatically.

The `begin` operation refuses an existing ID. Repeated `end` or `show` calls return the same comparison without appending data. `show` also works when interruption prevented the end hook from running.

This is a changed-content signal. A commit, configuration edit, or another writer can change the fingerprint. It does not establish who changed the files or whether work succeeded. The ordinary checkpoint remains responsible for the outcome record.

State lives in the worktree's self-ignored `.agents/.state` directory. Capture is opt-in and adds no always-loaded prose. Clear completed session snapshots when the adapter no longer needs them.
