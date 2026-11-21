#!/usr/bin/env bash
# assemble.sh: graft v2.12 and earlier built copied patterns with this script, and a v2.12 `tuteur
# upgrade` (its weekly bot too) runs the copy of the version it moves to. graft v2.13.0 has no
# copies: this stub stops that upgrade before it writes a patterns folder, saying why.
echo "tuteur: graft v2.13.0 replaced copied scions with git submodules; this upgrade can't be automatic: follow the Upgrading steps of v2.13.0 in graft's CHANGELOG.md (https://github.com/danielnaab/graft/blob/v2/CHANGELOG.md)" >&2
exit 1
