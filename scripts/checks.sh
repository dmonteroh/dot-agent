#!/usr/bin/env bash
set -u

# verify.sh passes the check name as $1. It runs this file from the project
# folder, and verify.sh prove also runs it from a throwaway checkout with
# DA_PROVE=1. That checkout holds no Git-ignored file, so a check links what
# it needs from the project, which DA_PROVE_MAIN names. A driver for a Node.js
# project, with one check that runs a single scratch test:
#
#   [ -z "${DA_PROVE:-}" ] || [ -e node_modules ] || ln -s "$DA_PROVE_MAIN/node_modules" node_modules
#   case "${1:-}" in
#     test) exec npm test ;;
#     scratch-*) exec node --test "tmp/scratch/${1#scratch-}.test.js" ;;
#     *) echo "Unknown check: ${1:-}" >&2; exit 2 ;;
#   esac

echo "checks.sh: no project checks are configured; replace this preserved starter driver" >&2
exit 2
