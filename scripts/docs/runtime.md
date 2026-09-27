# runtime.sh

Shared Bash primitives for verification and checkpoint bookkeeping. This file is sourced by managed helpers and installs no traps. It is not an agent-facing command.

`da_root` resolves a physical project root. `da_state_dir` uses `.agent/.state` in Git and non-Git nodes. Its self-ignore file keeps receipts and locks out of Git. This shared location works in sandboxes that protect `.git/` from writes.

`da_fingerprint` hashes current inputs without staging files. It includes worktree identity, source content, and index state. Runtime state, session-log output, and generated caches are excluded to keep completion retries stable.

`da_lock` and `da_unlock` serialize cooperating writers through an ownership record. An unknown or live owner is not a stale lock. These functions do not protect against a separate process that ignores the protocol.

Non-Git verification needs declared input roots in `verify.conf`. Ordinary node bookkeeping uses `.agent/` without recursively scanning the user's home. Receipts are local execution records, not an adversarial attestation mechanism.
