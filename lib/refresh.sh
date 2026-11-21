#!/usr/bin/env bash
# refresh.sh PATTERNS FLAKE RUN TEMPLATE: the files tuteur writes for its version, run from the repo's
# top: PATTERNS/README.md (patterns-readme.md beside this script, naming RUN, how the repo runs tuteur),
# when PATTERNS is a directory, and tuteur's workflows (workflows.sh, against TEMPLATE/.forgejo/workflows).
# `tuteur sync` runs its own; `tuteur upgrade` runs the one of the tuteur version it moves to, so
# what it writes is what that version's check expects. Prints a line per file it changed.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
patterns=$1 flake=$2 run=$3 template=$4
if [ -n "$patterns" ] && [ -d "$patterns" ]; then
  want=$(sed "s|@RUN@|$run|g" "$here/patterns-readme.md")
  if [ -L "$patterns/README.md" ]; then
    echo "tuteur: $patterns/README.md is a symbolic link; tuteur writes only a file there: remove it, then tuteur sync" >&2
    exit 1
  fi
  if [ ! -f "$patterns/README.md" ] || [ "$(cat "$patterns/README.md")" != "$want" ]; then
    # F3: never through a link: a temporary file beside it, moved over
    tmp=$(mktemp "$patterns/.tuteur-XXXXXX")
    printf '%s\n' "$want" > "$tmp"
    mv -fT -- "$tmp" "$patterns/README.md"
    git add -- "$patterns/README.md" 2>/dev/null || true
    echo "tuteur: wrote $patterns/README.md"
  fi
fi
bash "$here/workflows.sh" refresh . "$template/.forgejo/workflows" "$run" "$flake" ${patterns:+"$patterns"}
