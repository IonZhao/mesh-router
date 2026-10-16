#!/usr/bin/env bash
# Register (or remove) the Windows scheduled task that runs client/health-check.sh every 5 minutes
# through Git Bash. Run from Git Bash on the client machine:
#
#   client/install-health-task.sh            # create / replace the task
#   client/install-health-task.sh --remove   # delete it
#
# The task runs as the current user while logged on; a console window may flash for a moment every
# 5 minutes. To avoid that, open Task Scheduler, find "mesh-router health" and tick "Run whether user
# is logged on or not". SCHTASKS_DRY_RUN=1 prints the command instead of running it.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TASK="${HEALTH_TASK_NAME:-mesh-router health}"
die() { printf 'ERROR: %s\n' "$*" >&2; exit 2; }

if [[ "${1:-}" == "--remove" ]]; then
  cmd=(schtasks //Delete //F //TN "$TASK")
else
  command -v cygpath >/dev/null 2>&1 || die "this installer is for Git Bash on Windows (Task Scheduler); use cron elsewhere."
  bash_exe="$(cygpath -w "$(command -v bash)")"
  script="$SCRIPT_DIR/health-check.sh"
  # schtasks /TR takes ONE string: "<bash.exe>" -lc "<script>"; inner quotes are escaped for cmd.
  tr_cmd="\\\"$bash_exe\\\" -lc \\\"$script\\\""
  cmd=(schtasks //Create //F //SC MINUTE //MO 5 //TN "$TASK" //TR "$tr_cmd")
fi

if [[ -n "${SCHTASKS_DRY_RUN:-}" ]]; then
  printf '%s' "${cmd[0]}"; for a in "${cmd[@]:1}"; do printf ' %s' "${a//\/\//\/}"; done; echo
  exit 0
fi
"${cmd[@]}" && echo "Task \"$TASK\" ${1:---installed}: it runs client/health-check.sh every 5 minutes (CSV + alerts, see README)."
