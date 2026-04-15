#!/bin/bash
# Run a command with elapsed time reporting.
#
# Usage: ./scripts/timed.sh <description> -- <command...>
set -euo pipefail

DESC="$1"
shift

if [ "$1" = "--" ]; then
    shift
fi

printf '%s ...\n' "$DESC"
START=$SECONDS
"$@"
ELAPSED=$(( SECONDS - START ))
H=$(( ELAPSED / 3600 ))
M=$(( (ELAPSED % 3600) / 60 ))
S=$(( ELAPSED % 60 ))
if [ $H -gt 0 ]; then
    printf '%s done (%dh%02dm%02ds)\n' "$DESC" "$H" "$M" "$S"
elif [ $M -gt 0 ]; then
    printf '%s done (%dm%02ds)\n' "$DESC" "$M" "$S"
else
    printf '%s done (%ds)\n' "$DESC" "$S"
fi
