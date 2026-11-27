#!/usr/bin/env bash
# patterns-readme.sh text|write PATTERNS RUN: the marker README, run from the repo's top. Its text is
# patterns-readme.md beside this script (RUN, how the repo runs tuteur, for @RUN@), then a list of the
# patterns .gitmodules registers in PATTERNS, by name, each linked to its guide: the USING.md at its
# recorded commit, else its README.md. Self-contained (common.sh's helpers only), so tuteur upgrade can run
# another version's (refresh.sh).
#
#   text   print it; exit 3, printing nothing, when a pattern's recorded commit isn't in its clone (an
#          empty pattern: its guide can't be told)
#   write  write it to PATTERNS/README.md when it differs ("tuteur: wrote PATTERNS/README.md"), never
#          through a symbolic link, and stage it; when a pattern is empty, a note and no change
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source-path=SCRIPTDIR source=common.sh
. "$here/common.sh"
mode=$1 PATTERNS=$2 run=$3

# readme_text: the text, or exit 3 naming the first empty pattern on stderr
readme_text() {
  local name path url link guide entries=""
  while IFS=$'\t' read -r name path url; do
    [ -n "$name" ] || continue
    link=$(gitlink "$path")
    if [ -z "$link" ] || ! git -C "$path" cat-file -e "$link^{commit}" 2>/dev/null; then
      echo "$path" >&2; return 3
    fi
    if git -C "$path" cat-file -e "$link:USING.md" 2>/dev/null; then guide=USING.md; else guide=README.md; fi
    entries+="- [$name]($name/$guide)"
    [ "$guide" = USING.md ] || entries+=" (it has no USING.md: its README)"
    entries+=$'\n'
  done < <(patterns_registered .gitmodules | sort -t $'\t' -k1,1)
  sed "s|@RUN@|$run|g" "$here/patterns-readme.md"
  if [ -n "$entries" ]; then
    printf '\n## What each pattern offers\n\n'
    printf '%s\n' "Each pattern's guide says what it ships for this repository (tools, recipes, checks, settings) and" \
      "which of its docs to read when. Read a pattern's guide before you use what it ships. Point this repository's" \
      "AGENTS.md here, then add its own rules."
    printf '\n%s' "$entries"
  fi
}

case $mode in
  text) readme_text ;;
  write)
    rc=0
    want=$(readme_text 2>"$TUTEUR_TMP/empty") || rc=$?
    if [ "$rc" = 3 ]; then
      echo "tuteur: $PATTERNS/README.md: not written: $(cat "$TUTEUR_TMP/empty") is empty (tuteur sync fills it)"
      exit 0
    fi
    [ "$rc" = 0 ] || exit "$rc"
    if [ -L "$PATTERNS/README.md" ]; then
      echo "tuteur: $PATTERNS/README.md is a symbolic link; tuteur writes only a file there: remove it, then tuteur sync" >&2
      exit 1
    fi
    if [ ! -f "$PATTERNS/README.md" ] || [ "$(cat "$PATTERNS/README.md")" != "$want" ]; then
      # F3: never through a link: a temporary file beside it, moved over
      tmp=$(mktemp "$PATTERNS/.tuteur-XXXXXX")
      printf '%s\n' "$want" > "$tmp"
      mv -fT -- "$tmp" "$PATTERNS/README.md"
      git add -- "$PATTERNS/README.md" 2>/dev/null || true
      echo "tuteur: wrote $PATTERNS/README.md"
    fi
    ;;
  *) die "usage: patterns-readme.sh text|write PATTERNS RUN" ;;
esac
