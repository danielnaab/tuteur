#!/usr/bin/env bash
# refresh.sh PATTERNS FLAKE RUN TEMPLATE: the files tuteur writes for its version, run from the repo's
# top: PATTERNS/README.md (patterns-readme.sh beside this script, naming RUN, how the repo runs tuteur, and
# linking each pattern's guide), when PATTERNS is a directory, and tuteur's workflows (workflows.sh, against TEMPLATE/.forgejo/workflows).
# `tuteur sync` runs its own; `tuteur upgrade` runs the one of the tuteur version it moves to, so
# what it writes is what that version's check expects. Prints a line per file it changed.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
patterns=$1 flake=$2 run=$3 template=$4
if [ -n "$patterns" ] && [ -d "$patterns" ]; then
  bash "$here/patterns-readme.sh" write "$patterns" "$run"
fi
bash "$here/workflows.sh" refresh . "$template/.forgejo/workflows" "$run" "$flake" ${patterns:+"$patterns"}
