#!/usr/bin/env bash
# Register (or remove) the Windows scheduled task that runs client/health-check.sh every 5 minutes
# through Git Bash. Run from Git Bash on the client machine:
#
#   client/install-health-task.sh            # create / replace the task "mesh-router health"
#   client/install-health-task.sh --remove   # delete it
#
# The task runs as the current user while logged on, inside a hidden console (conhost.exe
# --headless), so no window flashes and Windows notifications still reach the desktop. Leave it on
# "Run only when user is logged on": the other mode runs in a session that cannot show
# notifications. Settings for the check go in %LOCALAPPDATA%\mesh-router\health.env (see README).
# SCHTASKS_DRY_RUN=1 prints the schtasks command instead of running it.
set -uo pipefail

case "${BASH_SOURCE[0]}" in */*) SCRIPT_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd)";; *) SCRIPT_DIR="$(pwd)";; esac
TASK="${HEALTH_TASK_NAME:-mesh-router health}"
die() { printf 'ERROR: %s\n' "$*" >&2; exit 2; }

if [[ "${1:-}" == "--remove" ]]; then
  cmd=(schtasks //Delete //F //TN "$TASK")
  done_msg="Task \"$TASK\" removed."
else
  script="$SCRIPT_DIR/health-check.sh"            # POSIX path: Git Bash resolves it, dirname works inside
  if command -v cygpath >/dev/null 2>&1; then bash_exe="$(cygpath -w "$BASH")"; else bash_exe="$BASH"; fi
  # /TR takes ONE string. The quotes inside it are written plainly: bash escapes them for the Windows
  # command line and schtasks unescapes them. (Writing \" here stores literal backslashes in the task
  # and it never starts.) conhost.exe --headless runs bash without a console window.
  tr_cmd="conhost.exe --headless \"$bash_exe\" -l \"$script\""
  cmd=(schtasks //Create //F //SC MINUTE //MO 5 //TN "$TASK" //TR "$tr_cmd")
  done_msg="Task \"$TASK\" installed: client/health-check.sh runs every 5 minutes (CSV + notifications, see README)."
fi

if [[ -n "${SCHTASKS_DRY_RUN:-}" ]]; then
  printf '%s' "${cmd[0]}"
  for a in "${cmd[@]:1}"; do
    a="${a//\/\//\/}"
    [[ "$a" == *" "* && "$a" != *\"* ]] && a="\"$a\""   # the task name; /TR already carries its quotes
    printf ' %s' "$a"
  done
  echo
  exit 0
fi
command -v schtasks >/dev/null 2>&1 || die "schtasks not found: this installer is for Git Bash on Windows; use cron elsewhere (README)."
"${cmd[@]}" && echo "$done_msg"
