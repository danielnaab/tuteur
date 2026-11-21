#!/usr/bin/env bash
# tuteur.sh [COMMAND [ARGS...]]: the one command, `nix run .#tuteur` in a repo that uses tuteur (its
# own app, from mkFlake: TUTEUR_IN_REPO and TUTEUR_DIR set) and `nix run github:danielnaab/tuteur --
# COMMAND -C REPO` against any checkout. Its package (flake.nix) puts every tool the commands need
# on PATH, and TUTEUR_TEMPLATE names this version's workflows.
#
#   add       add another repository's pattern as a submodule at a release tag (lib/patterns.sh)
#   sync      fill empty patterns, write tuteur's README and workflows (the default in a repo's own app)
#   check     every pattern registered, initialised, clean and at a release tag (lib/patterns.sh)
#   status    check's facts and outdated's newest release, per pattern; --json is status/1 (lib/patterns.sh)
#   try       make Nix builds read the patterns' working trees, new files included, and undo it
#             (lib/patterns.sh)
#   outdated  tuteur's and each pattern's tag against the newest upstream (lib/tools.sh)
#   upgrade   move tuteur and patterns to newer tags (lib/tools.sh)
#   changelog what upstream changed between each pin and the tag upgrade would take (lib/tools.sh)
#   migrate   print a migration brief for an upgraded branch (lib/migrate.sh)
#   ci        the steps of tuteur's Forgejo workflows (lib/ci.sh)
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

usage() {
  cat <<'USAGE'
usage: nix run .#tuteur [COMMAND] (a flag needs `--`: nix run .#tuteur -- outdated --json)
   or: nix run github:danielnaab/tuteur -- COMMAND -C REPO

  add [-C REPO] [--dir PATH] URL[@TAG] [NAME]
                                        add URL as a submodule at its newest (or TAG) release
  sync                                  fill empty patterns; write tuteur's README and workflows (the
                                        default; a repo's own app only)
  check [-C REPO] [--committed]         every pattern registered, initialised, clean, at a release tag
  status [-C REPO] [--json]             each pattern's pin, its state and the newest release (status/1)
  try [-C REPO] [NAME...]               make Nix builds read the patterns' working trees until
                                        try --stop; say how to make the named ones' (default: all)
                                        new files visible
  try [-C REPO] --stop                  undo what try did
  outdated [-C REPO] [--json]           tags against the newest upstream
  upgrade [-C REPO] [NAME[@TAG]...]     move tuteur and patterns to newer tags
  changelog [-C REPO] [--json] [NAME[@TAG]...]
                                        what upstream changed between each pin and its target
  migrate [-C REPO] [--base REF] [--no-check] [--json]
                                        a migration brief for an upgraded branch
  ci check|upgrade|pr                   the steps of tuteur's Forgejo workflows
USAGE
}

cmd=${1:-}
[ $# -eq 0 ] || shift
if [ -z "$cmd" ] && [ -n "${TUTEUR_IN_REPO:-}" ]; then cmd=sync; fi
case $cmd in
  add|sync|check|status|try) exec bash "$here/patterns.sh" "$cmd" "$@" ;;
  outdated|upgrade|changelog) exec bash "$here/tools.sh" "$cmd" "$@" ;;
  migrate) exec bash "$here/migrate.sh" "$@" ;;
  ci) exec bash "$here/ci.sh" "$@" ;;
  help|-h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
