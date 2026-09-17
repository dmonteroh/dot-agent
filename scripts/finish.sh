#!/usr/bin/env bash
echo "finish.sh: deprecated — use checkpoint.sh; forwarding unchanged" >&2
exec "$(dirname "$0")/checkpoint.sh" "$@"
