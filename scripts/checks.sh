#!/usr/bin/env bash
set -u

# verify.sh passes the check name as $1 and runs this file from the project
# folder. Give each check one case arm that execs the project's own command,
# and end with an arm that refuses an unknown name with exit 2.

echo "checks.sh: no project checks are configured; replace this preserved starter driver" >&2
exit 2
