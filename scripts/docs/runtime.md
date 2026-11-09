# runtime.sh

Shared Bash primitives for verification and checkpoint bookkeeping. This file is sourced by managed helpers and installs no traps. It is not an agent-facing command.

`da_root` resolves a physical project root. `da_node_dir` resolves its physical node. A `.agent` that is a symlink is accepted only when it resolves to a directory named `.agent` that holds `purpose.md`, in a checkout of the same Git repository (the same `git rev-parse --git-common-dir`). That is a shared node, as an orchestrator links it into worker worktrees. Any other link is refused, so a stray link cannot send node writes or private state into another project or into a directory that is not a node. A non-Git root never shares a node. `da_node_shared` tells whether a root's `.agent` is such a link.

`da_state_dir` uses `.state` inside the physical node, in Git and non-Git nodes, so every checkout sharing a node shares its locks and receipts. Receipts stay bound to the worktree that ran them. Its self-ignore file keeps receipts and locks out of Git. This location works in sandboxes that protect `.git/` from writes.

`da_fingerprint` hashes current inputs without staging files. It includes worktree identity, source content, and index state. Runtime state, session-log output, and generated caches are excluded to keep completion retries stable.

`da_lock` and `da_unlock` serialize cooperating writers through an ownership record. An unknown or live owner is not a stale lock. A lock whose owner is not yet recorded, or that is released while being checked, counts as held. A dead owner's lock is recovered only while it still names that owner, so a lock released and taken again by another writer during the check is left alone. `da_lock_wait` retries `da_lock` while the lock is held, for at most `DA_LOCK_WAIT_SECONDS` (default 10), and the record writers (`log.sh`, `memory.sh`, `absorb.sh`) take their locks through it. These functions do not protect against a separate process that ignores the protocol.

Non-Git verification needs declared input roots in `verify.conf`. Ordinary node bookkeeping uses `.agent/` without recursively scanning the user's home. Receipts are local execution records, not an adversarial attestation mechanism.
