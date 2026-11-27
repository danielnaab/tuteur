#!/usr/bin/env bash
# patterns.sh add|sync|check [ARGS...]: tuteur's commands on the patterns themselves.
#
#   add [-C REPO] [--dir PATH] URL[@TAG] [NAME]
#             add URL at TAG (default: its newest release) as the submodule PATTERNS/NAME (NAME
#             default: URL's last segment, without .git), checked out at the tag's commit; writes
#             the patterns README (with the new pattern's guide); stages .gitmodules, the gitlink and the README.
#   sync      (a repo's own app only) initialise every pattern not yet initialised (never one level
#             further down, never moving one already there), then write tuteur's README and
#             workflows for this version (refresh.sh). Never moves a gitlink.
#   check [-C REPO] [--committed]
#             every pattern registered, initialised, clean, checked out at its gitlink, and the gitlink
#             a release tag upstream; tuteur's workflows this version's. --committed (tuteur ci check)
#             checks only what a commit holds: no initialised pattern needed.
#   try [-C REPO] [NAME...] | try [-C REPO] --stop
#             make a git flake's builds read the working tree, every pattern's included, by marking
#             .tuteur-try at the top with intent to add (never a pattern's index); report what Nix builds
#             of each pattern, and for the named patterns (default: all) the `git -C … add` that makes
#             their new files visible. --stop removes .tuteur-try. A path: flake reads its working tree
#             always: try only reports.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source-path=SCRIPTDIR source=common.sh
. "$here/common.sh"
template=${TUTEUR_TEMPLATE:-$here/../template}

short() { echo "${1:0:7}"; }

# the patterns README for this flake (patterns-readme.sh)
write_readme() { bash "$here/patterns-readme.sh" write "$PATTERNS" "$TUTEUR_RUN" >/dev/null; }

# fill_nested PATH: initialise the pattern's own submodules that aren't, recursively, at the commits
# it records. Nix reads them from the working tree whenever a tracked file of the repo is modified,
# and fails on an empty one; git leaves them empty unless asked.
fill_nested() {
  local sub
  [ -f "$1/.gitmodules" ] || return 0
  git config -f "$1/.gitmodules" --get-regexp '^submodule\..*\.path$' 2>/dev/null | while read -r _ sub; do
    [ -e "$1/$sub/.git" ] || git -C "$1" submodule update -q --init --recursive -- "$sub" \
      || echo "tuteur: can't fill $1/$sub (see above): Nix fails on it while the repo's tree has a modified file" >&2
  done
}

# empty_nested PATH: the pattern's own submodules that are empty, space-separated
empty_nested() {
  local sub out=""
  [ -f "$1/.gitmodules" ] || return 0
  while read -r _ sub; do
    [ -e "$1/$sub/.git" ] || out+="$sub "
  done < <(git config -f "$1/.gitmodules" --get-regexp '^submodule\..*\.path$' 2>/dev/null)
  echo "${out% }"
}

# nested NAME PATH: a note when the pattern has submodules of its own
nested() {
  local subs
  [ -f "$2/.gitmodules" ] || return 0
  subs=$(git config -f "$2/.gitmodules" --get-regexp '^submodule\..*\.path$' 2>/dev/null | awk '{ print $2 }' | paste -sd ' ' -) || true
  [ -z "$subs" ] || echo "tuteur: note: $2 has its own submodules ($subs); tuteur fills them, and Nix fetches them too, so each must be reachable"
}

# A flake at the repo's top must declare inputs.self.submodules, or a git flake sees no patterns. A
# flake that can't (tuteur's own, used as a path: input) says so with `# tuteur: no self.submodules` (or graft's
# `# graft: no self.submodules`).
declares_submodules() {
  grep -qE '(self\.submodules|submodules)[[:space:]]*=[[:space:]]*true' "$FLAKE_NIX" \
    || grep -qF -e '# tuteur: no self.submodules' -e '# graft: no self.submodules' "$FLAKE_NIX"
}

# submodules_problem N: tuteur check's message when a top-level git flake with N patterns doesn't declare
# inputs.self.submodules (it sees no patterns), or nothing
submodules_problem() {
  if [ "$FLAKE" = . ] && [ -f "$FLAKE_NIX" ] && [ "$1" -gt 0 ] && ! declares_submodules; then
    echo "$FLAKE_NIX doesn't declare inputs.self.submodules = true;, so Nix sees no patterns: add it (Nix 2.27 or later)"
  fi
}

cmd_add() {
  local repo="" patterns="" spec="" name="" url tag="" commit list path p
  while [ $# -gt 0 ]; do
    case $1 in
      -C) if [ $# -lt 2 ] || [ -z "$2" ]; then die "-C needs a repository"; fi; repo=$2; shift 2 ;;
      --dir|--scions)
        if [ $# -lt 2 ] || [ -z "$2" ]; then die "$1 needs a path from the repo's top, like nix/agent-tools/.patterns"; fi
        [ "$1" != --scions ] || alias_line "--scions" "use --dir"
        patterns=$2; shift 2 ;;
      --dir=*) patterns=${1#--dir=}; shift ;;
      --scions=*) alias_line "--scions" "use --dir"; patterns=${1#--scions=}; shift ;;
      -h|--help) sed -n '4,7p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
      -*) die "unknown option $1 (usage: tuteur add [-C REPO] [--dir PATH] URL[@TAG] [NAME])" ;;
      *) if [ -z "$spec" ]; then spec=$1; elif [ -z "$name" ]; then name=$1; else die "usage: tuteur add [-C REPO] [--dir PATH] URL[@TAG] [NAME]"; fi; shift ;;
    esac
  done
  [ -n "$spec" ] || die "usage: tuteur add [-C REPO] [--dir PATH] URL[@TAG] [NAME]"
  locate "$repo"
  # URL@TAG only when what follows the last @ is a version (git@host:x.git keeps its @)
  url=$spec
  if [[ $spec == *@* ]] && is_semver "${spec##*@}"; then url=${spec%@*}; tag=${spec##*@}; fi
  ! relative_url "$url" || die "a relative URL ($url) won't resolve for Nix; give an absolute URL"
  if [ -z "$name" ]; then name=${url%/}; name=${name##*/}; name=${name##*:}; name=${name%.git}; fi
  [[ $name =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && $name != self ]] \
    || die "$name: a pattern's name must be letters, digits, . _ and - (starting with a letter or digit), and not self: give one (tuteur add URL NAME)"
  if [ -n "$patterns" ]; then
    patterns=${patterns%/}
    [[ $patterns =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ && ! $patterns =~ (^|/)\.\.?(/|$) && ! $patterns =~ ^\.git(/|$) ]] \
      || die "--dir $patterns: give a plain path from the repo's top, like nix/agent-tools/.patterns"
    [ -z "$PATTERNS" ] || [ "$PATTERNS" = "$patterns" ] || die "this repository's patterns are in $PATTERNS; tuteur supports one patterns folder per repository"
    p=.; [[ $patterns != */* ]] || p=${patterns%/*}
    [ "$p" = . ] || [ -f "$p/flake.nix" ] || die "--dir $patterns: no flake.nix in $p; the patterns folder goes beside the flake that uses them"
  else
    patterns=$PATTERNS_NEW
  fi
  PATTERNS=$patterns
  if [[ $PATTERNS == */* ]]; then FLAKE=${PATTERNS%/*}; else FLAKE=.; fi
  flake_vars
  path=$PATTERNS/$name
  # a copied pattern (graft v2.12) still in the index: `git add` would record the clone as files
  [ -z "$(git ls-files -s -- "$path" | awk '$1 != "160000"')" ] || die "$path is still tracked as files (a copied pattern?): git rm -r -q --cached $path, delete the folder, then tuteur add again"
  [ ! -e "$path" ] || die "$path exists"
  list=$(tags_of "$url") || die "can't list $url's tags (see above)"
  [ -n "$list" ] || die "$url has no semver tags"
  if [ -n "$tag" ]; then
    commit=$(awk -v t="$tag" '$2 == t { print $1 }' <<<"$list")
    [ -n "$commit" ] || die "$name: no tag $tag upstream"
  else
    tag=$(awk '{ print $2 }' <<<"$list" | sort -V | tail -1)
    commit=$(awk -v t="$tag" '$2 == t { print $1 }' <<<"$list")
  fi
  mkdir -p "$PATTERNS"
  # a pattern removed and added again: git keeps its clone, and reuses it with --force
  if [ -d "$(git rev-parse --git-path "modules/$path")" ]; then
    git submodule add -q --force -- "$url" "$path" >/dev/null 2>&1 || die "git submodule add $url $path failed"
    git -C "$path" remote set-url origin "$url"
  else
    git submodule add -q -- "$url" "$path" || die "git submodule add $url $path failed (see above)"
  fi
  git -C "$path" cat-file -e "$commit^{commit}" 2>/dev/null \
    || git -C "$path" fetch -q origin "refs/tags/$tag:refs/tags/$tag" 2>/dev/null \
    || git -C "$path" fetch -q origin "$commit" || die "can't fetch $tag ($commit) from $url"
  git -C "$path" -c advice.detachedHead=false checkout -q --detach "$commit"
  fill_nested "$path"
  git add -- .gitmodules "$path"
  [ "$(gitlink "$path")" = "$commit" ] || die "$path was not recorded as a submodule (git ls-files -s $path); remove it (git rm -r -q --cached $path) and try again"
  # after the gitlink: the README links the guide at the recorded commit
  write_readme
  git add -- "$PATTERNS/README.md"
  echo "tuteur: $path <- $tag ($(short "$commit"))"
  nested "$name" "$path"
  requires_note "$name" "$path"
  # the new pattern's recipes (v2.18.0), from the repository's own app, where the repository uses kits.just
  [ -z "${TUTEUR_IN_REPO:-}" ] || kits_just_write || true
  if [ "$FLAKE" = . ] && [ -f "$FLAKE_NIX" ] && ! declares_submodules; then
    echo "tuteur: next: commit; a git flake also needs inputs.self.submodules = true;"
  else
    echo "tuteur: next: commit"
  fi
}

# requires_note NAME PATH: a note for each sibling the pattern's tuteur.nix requires that this repo
# doesn't tuteur (read from the text: `requires.X = "URL";` or `requires = { X = "URL"; };`)
requires_note() {
  local f text pairs sib u
  f=$(provider_file "$2") || return 0
  text=$(tr '\n' ' ' < "$f")
  pairs=$( { grep -oE 'requires\.[A-Za-z0-9._-]+[[:space:]]*=[[:space:]]*"[^"]*"' <<<"$text" | sed -E 's/^requires\.//'
             grep -oE 'requires[[:space:]]*=[[:space:]]*\{[^}]*\}' <<<"$text" | grep -oE '[A-Za-z0-9._-]+[[:space:]]*=[[:space:]]*"[^"]*"'; } || true)
  while IFS= read -r sib; do
    [ -n "$sib" ] || continue
    u=${sib#*\"}; u=${u%\"}; sib=${sib%%[[:space:]=]*}
    if ! patterns_registered .gitmodules | cut -f1 | grep -qxF -- "$sib"; then
      echo "tuteur: note: $1 requires $sib, which this repository does not have: tuteur add $u"
    fi
  done <<<"$pairs"
}

# files_msg PATH: a submodule path the index holds as files
files_msg() { echo "$1 is tracked as files, not as a submodule: git rm -r -q --cached $1, then git add $1 if $1/.git exists; otherwise delete the folder and tuteur add its URL@TAG again"; }

# status_line NAME PATH: where an initialised pattern is
status_line() {
  local head link v
  head=$(git -C "$2" rev-parse -q --verify HEAD 2>/dev/null) || head=""
  link=$(gitlink "$2")
  if [ -z "$head" ]; then echo "tuteur: $2 is empty"; return; fi
  v=$(local_version_at "$2" "$head")
  if [ -n "$v" ]; then v="$v ($(short "$head"))"; else v="$(short "$head") (untagged)"; fi
  if [ -n "$link" ] && [ "$head" != "$link" ]; then
    echo "tuteur: $2 at $v, not the recorded $(short "$link"): left as it is (git add $2 records it; git submodule update --recursive -- $2 goes back)"
  else
    echo "tuteur: $2 at $v"
  fi
}

cmd_sync() {
  [ -n "${TUTEUR_IN_REPO:-}" ] || die "sync runs from the repo's own flake (it writes that tuteur version's files): nix run .#tuteur sync, or nix run 'path:DIR#tuteur' sync"
  [ $# -eq 0 ] || die "sync takes no arguments"
  locate ""
  local name path url
  if [ -z "$PATTERNS" ]; then
    echo "tuteur: no patterns here yet: tuteur add URL"
  else
    while IFS=$'\t' read -r name path url; do
      [ -n "$name" ] || continue
      [ -n "$(gitlink "$path")" ] || [ -z "$(git ls-files -- "$path")" ] || die "$(files_msg "$path")"
      if [ ! -e "$path/.git" ]; then
        git submodule update -q --init -- "$path" || die "can't initialise $path from $url (see above)"
      fi
      fill_nested "$path"
      status_line "$name" "$path"
    done < <(patterns_registered .gitmodules)
  fi
  bash "$here/refresh.sh" "$PATTERNS" "$FLAKE" "$TUTEUR_RUN" "$template"
  kits_just_write
  [ -z "$(try_state)" ] || echo "tuteur: note: tuteur try is on: tuteur try --stop turns it off before you commit"
}

# try_problem: tuteur check's message for tuteur try's state, or nothing
try_problem() {
  case $(try_state) in
    on) echo "tuteur try is on ($TRY): Nix builds read the working tree, patterns included: tuteur try --stop turns it off" ;;
    committed) echo "$TRY is committed (tuteur try's marker): tuteur try --stop, then commit its removal" ;;
    left) echo "$TRY is left from tuteur try but untracked, so Nix builds read the recorded patterns: tuteur try --stop removes it, or tuteur try turns try on again" ;;
  esac
  # graft try's marker (graft v2): Nix reads the working tree while it is marked, as with tuteur's
  if [ -n "$(git ls-files -- "$OLD_TRY")" ] || [ -e "$OLD_TRY" ]; then
    echo "$OLD_TRY is graft try's marker: tuteur try --stop removes it (then commit, if its removal is staged)"
  fi
}

# stray_patterns REGISTERED: what is in the patterns folder that .gitmodules (REGISTERED: patterns_registered's
# lines) does not register, as PATH<TAB>MESSAGE: a folder that isn't a submodule, a submodule not registered;
# and any gitlink whose folder is gone, registered or not
stray_patterns() {
  local registered=$1 d mode
  for d in "$PATTERNS"/*/ "$PATTERNS"/.[!.]*/; do
    [ -d "$d" ] || continue
    d=${d%/}
    mode=$(git ls-files -s -- "$d" | awk 'NR == 1 { print $1 }')
    if [ "$mode" != 160000 ]; then
      # one .gitmodules registers is pattern_facts'
      awk -F'\t' -v p="$d" '$2 == p { f = 1 } END { exit !f }' <<<"$registered" || printf '%s\t%s\n' "$d" "$d is not a submodule: tuteur add URL, or remove it"
    elif ! awk -F'\t' -v p="$d" '$2 == p { f = 1 } END { exit !f }' <<<"$registered"; then
      printf '%s\t%s\n' "$d" "$d is a submodule .gitmodules doesn't register: git rm --cached $d, then tuteur add its URL"
    fi
  done
  # gitlinks git knows of whose folder is gone (committed mode: a clean checkout has every folder)
  while IFS= read -r d; do
    [ -n "$d" ] && [ ! -d "$d" ] && printf '%s\t%s\n' "$d" "$d is a submodule with no folder: git submodule update --init --recursive -- $d, or git rm $d"
  done < <(git ls-files -s -- "$PATTERNS" | awk '$1 == "160000" { sub(/^[^\t]*\t/, ""); print }')
  return 0
}

# pattern_facts NAME PATH URL [COMMITTED]: what tuteur check reads of one registered pattern, and its messages,
# in globals. COMMITTED (non-empty): only what a commit holds, as tuteur check --committed.
#   SF_LINK      the gitlink in the index, or ""
#   SF_FILLED    1 when PATH holds a clone; SF_HEAD its checked-out commit; SF_DIRT its first five edited
#                tracked files, space-separated ("" when clean)
#   SF_TAG       the highest semver tag at the gitlink, or ""; SF_TAG_FROM where it was read (upstream,
#                local: the pattern's clone, when the upstream can't be listed; "" when neither); SF_REASON
#                why the upstream couldn't be listed
#   SF_PROBLEMS  tuteur check's messages for the pattern, without `tuteur: `
pattern_facts() {
  local name=$1 path=$2 url=$3 committed=${4:-} list lt nearest why
  SF_LINK=$(gitlink "$path") SF_FILLED="" SF_HEAD="" SF_DIRT="" SF_TAG="" SF_TAG_FROM="" SF_REASON="" SF_PROBLEMS=()
  if [ -e "$path/.git" ]; then
    SF_FILLED=1
    SF_HEAD=$(git -C "$path" rev-parse -q --verify HEAD 2>/dev/null) || SF_HEAD=""
    SF_DIRT=$(git -C "$path" status --porcelain --untracked-files=no 2>/dev/null | head -5 | cut -c4- | paste -sd ' ' -)
  fi
  if [ -z "$SF_LINK" ] && [ -n "$(git ls-files -- "$path")" ]; then
    SF_PROBLEMS+=("$(files_msg "$path")"); return 0
  elif [ -z "$SF_LINK" ]; then
    SF_PROBLEMS+=(".gitmodules registers $path, which is not a submodule here: tuteur add its URL again, or remove its entry (git config -f .gitmodules --remove-section submodule.$path)")
    return 0
  fi
  if [ -z "$url" ]; then SF_PROBLEMS+=("$path has no URL in .gitmodules"); return 0; fi
  if relative_url "$url"; then
    SF_PROBLEMS+=("$path: .gitmodules gives a relative URL ($url), which Nix can't resolve: give an absolute one (git config -f .gitmodules submodule.$path.url URL)")
  fi
  if [ -z "$committed" ]; then
    if [ -z "$SF_FILLED" ]; then
      SF_PROBLEMS+=("$path is empty: git submodule update --init --recursive -- $path (or tuteur sync)")
    else
      if [ -n "$SF_DIRT" ]; then
        if [ "$FLAKE" != . ]; then why="a path: flake's builds use them"
        elif [ "$(try_state)" = on ]; then why="tuteur try is on: Nix builds use them"
        else why="Nix builds ignore them while the rest of the tree is clean"; fi
        SF_PROBLEMS+=("uncommitted edits in $path: $SF_DIRT ($why)")
      fi
      if [ "$SF_HEAD" != "$SF_LINK" ]; then
        SF_PROBLEMS+=("$path is checked out at $(short "$SF_HEAD") but the repository records $(short "$SF_LINK"): git add $path to record it, or git submodule update --recursive -- $path to go back")
      fi
      lt=$(empty_nested "$path")
      [ -z "$lt" ] || SF_PROBLEMS+=("$path's own submodules are empty ($lt): git -C $path submodule update --init --recursive (or tuteur sync); Nix fails on them while the repo's tree has a modified file")
    fi
  fi
  # the gitlink is a release: upstream, else (unreadable) the pattern's own tags
  if list=$(tags_of "$url" 2>/dev/null); then
    SF_TAG=$(awk -v c="$SF_LINK" '$1 == c { print $2 }' <<<"$list" | sort -V | tail -1) SF_TAG_FROM=upstream
  else
    SF_REASON=$(tags_error "$url")
    if [ -n "$SF_FILLED" ]; then SF_TAG=$(local_version_at "$path" "$SF_LINK") SF_TAG_FROM=local; fi
  fi
  if [ -z "$SF_TAG" ]; then
    nearest="" lt=""
    if [ -n "$SF_FILLED" ]; then
      lt=$(local_version_at "$path" "$SF_LINK")
      nearest=$(git -C "$path" describe --tags "$SF_LINK" 2>/dev/null) || nearest=""
    fi
    if [ -n "$lt" ]; then
      SF_PROBLEMS+=("$path: tag $lt exists locally but not at $url: push it (git -C $path push origin $lt)")
    else
      SF_PROBLEMS+=("$path at $(short "$SF_LINK") is not a release tag of $url${nearest:+ (nearest: $nearest)}: release it, then tuteur upgrade $name@TAG (or tuteur upgrade $name, the newest release of its major)")
    fi
  fi
}

cmd_check() {
  local repo="" committed="" rc=0 name path url lt n=0 registered err system p msg pf rt
  while [ $# -gt 0 ]; do
    case $1 in
      -C) if [ $# -lt 2 ] || [ -z "$2" ]; then die "-C needs a repository"; fi; repo=$2; shift 2 ;;
      --committed) committed=1; shift ;;
      *) die "usage: tuteur check [-C REPO] [--committed]" ;;
    esac
  done
  locate "$repo"
  bad() { echo "tuteur: $*" >&2; rc=1; }
  msg=$(try_problem)
  [ -z "$msg" ] || bad "$msg"
  if [ -z "$PATTERNS" ]; then
    echo "tuteur: no patterns here (no README.md carrying tuteur's marker); tuteur add URL adds one" >&2
  else
    registered=$(patterns_registered .gitmodules)
    # the repo's own app knows mkFlake's dir: tuteur's README must be in it
    if [ -n "${TUTEUR_IN_REPO:-}" ] && [ -n "${TUTEUR_DIR:-}" ] && [ "${PATTERNS##*/}" != "$TUTEUR_DIR" ]; then
      bad "tuteur's README is in $PATTERNS/ but mkFlake's dir is \"$TUTEUR_DIR\": set dir = \"${PATTERNS##*/}\"; in $FLAKE_NIX (or move the patterns)"
    fi
    while IFS=$'\t' read -r p msg; do [ -z "$msg" ] || bad "$msg"; done < <(stray_patterns "$registered")
    while IFS=$'\t' read -r name path url; do
      [ -n "$name" ] || continue
      pattern_facts "$name" "$path" "$url" "$committed"
      if [ -n "$SF_REASON" ]; then
        if [ -n "${POT:-}" ]; then
          # one note for the whole check, not one per pattern
          [ -f "$TUTEUR_TMP/sandbox-note" ] || { touch "$TUTEUR_TMP/sandbox-note"; echo "tuteur: upstream tags are not reachable from this pot run: checked each pattern's local tags" >&2; }
        else
          echo "tuteur: $path: $SF_REASON (upstream unreadable: checked local tags)" >&2
        fi
      fi
      for msg in "${SF_PROBLEMS[@]}"; do bad "$msg"; done
      [ -n "$SF_LINK" ] || continue
      n=$((n + 1))
      if [ -z "$committed" ] && [ -n "$SF_FILLED" ] && [ -n "$url" ]; then
        nested "$name" "$path"
        # a tuteur.nix that doesn't parse breaks every output of the flake, tuteur's app too
        if pf=$(provider_file "$path") && ! err=$(nix_ eval --impure --expr "builtins.isFunction (import $(pwd -P)/$pf)" 2>&1); then
          echo "$err" | tail -5 >&2
          bad "$pf doesn't evaluate (above): every output of this flake fails until it does, tuteur's own app too; move the pattern back (git submodule update --recursive -- $path), or from outside: nix run github:danielnaab/tuteur/v0.1.0 -- upgrade -C . $name@TAG"
        fi
      fi
    done <<<"$registered"
    # a top-level git flake sees no patterns without inputs.self.submodules
    msg=$(submodules_problem "$n")
    [ -z "$msg" ] || bad "$msg"
  fi
  # each pin at a version tag in the flake's lock (tuteur's own) holds its tag's tree: a polluted fetch cache's
  # isn't, and fails CI's NAR hash check
  while IFS= read -r msg; do [ -z "$msg" ] || bad "$msg"; done < <(pin_hash_problems)
  bash "$here/workflows.sh" check . "$template/.forgejo/workflows" "$TUTEUR_RUN" "$FLAKE" ${PATTERNS:+"$PATTERNS"} || rc=1
  # every provider evaluates (a tuteur.nix that throws fails here, naming it): from the repo's own app,
  # which has evaluated the flake already (from outside, -C, nothing of the repo's is evaluated)
  if [ -z "$committed" ] && [ -n "${TUTEUR_IN_REPO:-}" ] && [ "$rc" = 0 ] && [ -n "$PATTERNS" ]; then
    system=$(nix_ eval --impure --raw --expr builtins.currentSystem)
    if ! err=$( { nix_ eval --raw "$FLAKE_REF#packages.$system.tools.drvPath" >/dev/null && nix_ eval --json "$FLAKE_REF#checks.$system" --apply builtins.attrNames >/dev/null; } 2>&1); then
      grep -v "^warning: Git tree" <<<"$err" | tail -15 >&2
      bad "the flake's tools or checks don't evaluate (above): a provider's tuteur.nix fails"
    fi
  fi
  # kits.just (v2.18.0): the bytes the flake's kits generate, where the repository uses it
  if [ -z "$committed" ] && [ -n "${TUTEUR_IN_REPO:-}" ] && [ "$rc" = 0 ] && kits_just_wanted; then
    if ! has_pot_kits; then
      [ ! -e "$PATTERNS/kits.just" ] || bad "$PATTERNS/kits.just is here but this flake has no pot-kits (no inputs.pot): add inputs.pot, or remove the file"
    elif ! lt=$(kits_just_text 2>"$TUTEUR_TMP/kj.err"); then
      tail -5 "$TUTEUR_TMP/kj.err" >&2
      bad "$PATTERNS/kits.just: the flake's pot-kits doesn't evaluate (above)"
    elif [ -L "$PATTERNS/kits.just" ]; then
      bad "$PATTERNS/kits.just is a symbolic link; tuteur writes only a file there: remove it, then tuteur sync"
    elif ! kits_just_clashes "$lt" >"$TUTEUR_TMP/kjc"; then
      while IFS= read -r l; do bad "${l#tuteur: }"; done <"$TUTEUR_TMP/kjc"
    elif [ ! -f "$PATTERNS/kits.just" ] || [ "$(cat "$PATTERNS/kits.just")" != "$lt" ]; then
      if [ -n "${POT:-}" ]; then
        bad "$PATTERNS/kits.just is stale or edited: run tuteur sync on the host (the patterns folder is read-only in a run)"
      else
        bad "$PATTERNS/kits.just is stale or edited: tuteur sync"
      fi
    fi
  fi
  # the marker README: the text this tuteur writes, from the repository's own app (which knows how it runs
  # tuteur), once every pattern is filled (an empty one's guide can't be told). graft's README is an alias
  # through 0.1.x: aliases_in_use names it, and sync rewrites it
  if [ -z "$committed" ] && [ -n "${TUTEUR_IN_REPO:-}" ] && [ -n "$PATTERNS" ] \
     && ! grep -qsF -- "$OLD_MARKER" "$PATTERNS/README.md" \
     && rt=$(bash "$here/patterns-readme.sh" text "$PATTERNS" "$TUTEUR_RUN" 2>/dev/null); then
    if [ -L "$PATTERNS/README.md" ]; then
      bad "$PATTERNS/README.md is a symbolic link; tuteur writes only a file there: remove it, then tuteur sync"
    elif [ "$(cat "$PATTERNS/README.md")" != "$rt" ]; then
      if [ -n "${POT:-}" ]; then
        bad "$PATTERNS/README.md is stale or edited: run tuteur sync on the host (the patterns folder is read-only in a run)"
      else
        bad "$PATTERNS/README.md is stale or edited: tuteur sync"
      fi
    fi
  fi
  [ -n "$committed" ] || aliases_in_use
  if [ "$rc" = 0 ] && [ -n "$PATTERNS" ]; then
    local noun=patterns
    [ "$n" != 1 ] || noun=pattern
    if [ -n "$committed" ]; then echo "tuteur: $n $noun registered and at release tags"
    else echo "tuteur: $n $noun clean and at release tags"; fi
  fi
  return "$rc"
}

# aliases_in_use: one line each (alias_line, never a failure) for the names of graft's that tuteur 0.1.x still reads
# and this repository uses: the app graft, the patterns README's old marker, graft's marked workflows, and what
# mkFlake reports (the folder found by graft's default name, a provider's graft.nix, the arguments scion and
# scions). The input name graft is read through 0.x, so it gets no line.
aliases_in_use() {
  local f system json t w
  [ "${TUTEUR_VIA:-}" != graft ] || alias_line "the app graft (nix run .#graft)" "run nix run .#tuteur (tuteur sync renames graft's workflows, which run the old name)"
  if [ -n "$PATTERNS" ] && grep -qsF -- "$OLD_MARKER" "$PATTERNS/README.md"; then
    alias_line "the marker in $PATTERNS/README.md" "tuteur sync rewrites it"
  fi
  for f in .forgejo/workflows/graft-*.yaml; do
    if [ ! -f "$f" ] || ! grep -q "^# managed by graft: " "$f"; then continue; fi
    alias_line "$f" "tuteur sync renames it to ${f/graft-/tuteur-}"
  done
  if [ -n "${TUTEUR_IN_REPO:-}" ] && [ -n "$PATTERNS" ]; then
    system=$(nix_ eval --impure --raw --expr builtins.currentSystem) || return 0
    # (a flake whose tools mkFlake did not make has none)
    json=$(nix_ eval --json "$FLAKE_REF#packages.$system.tools.passthru.tuteurAliases" 2>/dev/null) || json='[]'
    while IFS=$'\t' read -r t w; do
      [ -z "$t" ] || alias_line "$t" "$w"
    done < <(jq -r '.[]? | "\(.thing)\t\(.todo)"' <<<"$json" 2>/dev/null || true)
  fi
  return 0
}

# latest_json URL ROW REASON: status/1's latest, from one of tuteur outdated's rows (row's fields) and
# the reason its upstream couldn't be read
latest_json() {
  local url=$1 status=$2 latest=$3 major=$4 reason=$5
  if [ "$status" = unknown ]; then
    [ -n "$reason" ] || reason=$(tags_error "$url")
    [ -n "$reason" ] || reason="found no release tags at $url to compare with"
    latest=- major=-
  else
    reason=""
  fi
  jq -n -c --arg s "$status" --arg t "$latest" --arg m "$major" --arg r "$reason" \
    '{status: $s, tag: (if $t == "-" or $t == "" then null else $t end), major: (if $m == "-" or $m == "" then null else $m end),
      reason: (if $r == "" then null else $r end)}'
}

# tuteur_pin_json: status/1's `graft` field (its name stays: a contract's fields are its interface): tuteur's own
# input (own_input: tuteur, else graft), or null (none, or a pattern by that name)
tuteur_pin_json() {
  local n url ref rev tag="" r own
  own=$(own_input "$FLAKE_LOCK")
  [ -n "$own" ] || { echo null; return; }
  n=$(lock_node "$FLAKE_LOCK" "$own")
  if [ -z "$n" ] || patterns_registered .gitmodules | cut -f1 | grep -qxF "$own"; then echo null; return; fi
  url=$(remote "$n"); ref=$(jq -r '.original.ref // empty' <<<"$n"); rev=$(jq -r '.locked.rev // empty' <<<"$n")
  if [ -n "$url" ] && is_semver "$ref"; then
    tag=$ref
    IFS=$'\t' read -r -a r < <(row "$own" - "$url" "$ref" 2>/dev/null)
  else
    r=(tuteur - - - untagged -)
  fi
  jq -n -c --arg u "$url" --arg c "$rev" --arg t "$tag" --argjson l "$(latest_json "$url" "${r[4]}" "${r[3]}" "${r[5]}" "")" \
    '{url: (if $u == "" then null else $u end), commit: (if $c == "" then null else $c end), tag: (if $t == "" then null else $t end), latest: $l}'
}

# pattern_json NAME PATH URL REGISTERED [PROBLEM...]: one status/1 pattern entry, from pattern_facts' globals (a
# registered pattern) or, for one .gitmodules doesn't register, from PROBLEMs
pattern_json() {
  local name=$1 path=$2 url=$3 reg=$4 r=() reason="" latest
  shift 4
  if [ "$reg" = true ]; then
    if [ -z "$SF_LINK" ]; then reason="$path is not a submodule in the index"
    elif [ -z "$url" ]; then reason="no URL in .gitmodules"
    else IFS=$'\t' read -r -a r < <(row "$name" "$PATTERNS" "$url" "$(pattern_pin "$path" "$url" 2>/dev/null)" 2>/dev/null); fi
    [ -z "$reason" ] || r=("$name" "$PATTERNS" - - unknown -)
    set -- "${SF_PROBLEMS[@]}"
  else
    SF_LINK=$(gitlink "$path") SF_FILLED="" SF_HEAD="" SF_DIRT="" SF_TAG="" SF_TAG_FROM="" url=""
    if [ -e "$path/.git" ]; then
      SF_FILLED=1
      SF_HEAD=$(git -C "$path" rev-parse -q --verify HEAD 2>/dev/null) || SF_HEAD=""
      SF_DIRT=$(git -C "$path" status --porcelain --untracked-files=no 2>/dev/null | head -5 | cut -c4- | paste -sd ' ' -)
    fi
    r=("$name" "$PATTERNS" - - unknown -) reason=".gitmodules does not register it"
  fi
  latest=$(latest_json "$url" "${r[4]}" "${r[3]}" "${r[5]}" "$reason")
  jq -n -c --arg name "$name" --arg path "$path" --arg url "$url" --argjson reg "$reg" --arg c "$SF_LINK" --arg t "$SF_TAG" \
    --arg tf "$SF_TAG_FROM" --arg filled "$SF_FILLED" --arg h "$SF_HEAD" --arg dirt "$SF_DIRT" --argjson l "$latest" \
    'def n: if . == "" then null else . end;
     {name: $name, path: $path, url: ($url | n), registered: $reg, commit: ($c | n), tag: ($t | n), tag_from: ($tf | n),
      filled: ($filled != ""), head: (if $filled == "" then null else ($h | n) end),
      clean: (if $filled == "" then null else $dirt == "" end), latest: $l, problems: $ARGS.positional}' --args "$@"
}

# status_text: the table and the problems of a status/1 report on stdin
status_text() {
  jq -r 'def s: tostring | gsub("[\\t\\n\\r]"; " ");
    def latest: if .status == "current" then "current" + (if .major then "; \(.major) is a breaking version" else "" end)
      elif .status == "outdated" then "\(.tag) (outdated" + (if .major then "; \(.major) is a breaking version" else "" end) + ")"
      elif .status == "untagged" then "untagged" + (if .tag then " (newest \(.tag))" else "" end)
      else "unknown" end;
    (["NAME", "PATH", "TAG", "COMMIT", "CHECKOUT", "LATEST"] | join("\t")),
    (.graft // empty | ["tuteur", "-", (.tag // "-"), ((.commit // "-")[0:7]), "-", (.latest | latest)] | map(s) | join("\t")),
    (.scions[] | [.name, .path,
      (if .tag then .tag elif .tag_from == "upstream" then "untagged" elif .commit then "?" else "-" end),
      ((.commit // "-")[0:7]),
      (if .registered | not then "unregistered" elif .filled | not then "empty" elif .clean == false then "dirty"
       elif .head != .commit then "moved" else "clean" end),
      (.latest | latest)] | map(s) | join("\t"))' | column -t -s $'\t'
  jq -r 'def s: tostring | gsub("[\\t\\n\\r]"; " ");
    (.graft // empty | select(.latest.reason) | "tuteur: tuteur: \(.latest.reason | s)"),
    (.scions[] | select(.latest.status == "unknown" and .registered) | "tuteur: \(.name | s): \(.latest.reason | s)"),
    (.problems[] | "tuteur: \(s)"), (.scions[] | .problems[] | "tuteur: \(s)")'
}

cmd_status() {
  local repo="" json="" registered name path url p msg entries=() probs=() n=0 report
  while [ $# -gt 0 ]; do
    case $1 in
      -C) if [ $# -lt 2 ] || [ -z "$2" ]; then echo "tuteur: -C needs a repository" >&2; echo "usage: tuteur status [-C REPO] [--json]" >&2; exit 2; fi; repo=$2; shift 2 ;;
      --json) json=1; shift ;;
      --) shift ;;
      -h|--help) echo "usage: tuteur status [-C REPO] [--json]: each pattern's pin, its state and the newest release; status/1 with --json"; exit 0 ;;
      *) echo "tuteur: status takes no argument $1" >&2; echo "usage: tuteur status [-C REPO] [--json]" >&2; exit 2 ;;
    esac
  done
  locate "$repo"
  msg=$(try_problem)
  [ -z "$msg" ] || probs+=("$msg")
  if [ -n "$PATTERNS" ]; then
    registered=$(patterns_registered .gitmodules)
    declare -A stray=()
    while IFS=$'\t' read -r p msg; do
      [ -n "$p" ] || continue
      stray[$p]+="$msg"$'\n'
    done < <(stray_patterns "$registered")
    while IFS=$'\t' read -r name path url; do
      [ -n "$name" ] || continue
      pattern_facts "$name" "$path" "$url"
      # a registered pattern's gitlink with no folder: stray_patterns' message is its own
      if [ -n "${stray[$path]:-}" ]; then
        while IFS= read -r msg; do [ -z "$msg" ] || SF_PROBLEMS+=("$msg"); done <<<"${stray[$path]}"
        unset "stray[$path]"
      fi
      [ -z "$SF_LINK" ] || n=$((n + 1))
      entries+=("$(pattern_json "$name" "$path" "$url" true)")
    done <<<"$registered"
    for p in "${!stray[@]}"; do
      mapfile -t probs_p < <(printf '%s' "${stray[$p]}")
      entries+=("$(pattern_json "${p##*/}" "$p" "" false "${probs_p[@]}")")
    done
    msg=$(submodules_problem "$n")
    [ -z "$msg" ] || probs+=("$msg")
  fi
  report=$(printf '%s\n' "${entries[@]}" | jq -s -c --arg repo "$(pwd -P)" --arg dir "$PATTERNS" --argjson graft "$(tuteur_pin_json)" \
    '{version: 1, repo: $repo, scions_dir: (if $dir == "" then null else $dir end), graft: $graft,
      scions: (map(select(. != null)) | sort_by((.registered | not), .name)), problems: $ARGS.positional}' --args "${probs[@]}")
  if [ -n "$json" ]; then
    jq . <<<"$report"
  elif [ -z "$PATTERNS" ] && [ "$(jq -r .graft <<<"$report")" = null ]; then
    echo "tuteur: no patterns here (no README.md carrying tuteur's marker), and no tuteur input; tuteur add URL adds one"
  else
    status_text <<<"$report"
  fi
}

# describe_commit PATH COMMIT: a pattern's commit and the release tag it is, or the nearest before it
describe_commit() {
  local t n
  if t=$(git -C "$1" describe --tags --exact-match "$2" 2>/dev/null); then echo "$t ($(short "$2"))"
  elif t=$(git -C "$1" describe --tags --abbrev=0 "$2" 2>/dev/null); then
    n=$(git -C "$1" rev-list --count "$t..$2")
    if [ "$n" = 1 ]; then n="1 commit"; else n="$n commits"; fi
    echo "$(short "$2"), $n after $t"
  else echo "$(short "$2") (no tag before it)"; fi
}

# new_files PATH: the untracked files git doesn't ignore in the repo at PATH and, recursively, in its
# filled submodules, as REPO<TAB>FILE (REPO from the top)
new_files() {
  local sub f
  while IFS= read -r -d '' f; do
    [[ $f != */ && $f != *$'\n'* && $f != *$'\t'* ]] || continue
    printf '%s\t%s\n' "$1" "$f"
  done < <(git -C "$1" ls-files -z --others --exclude-standard)
  while IFS= read -r sub; do
    { [ -n "$sub" ] && [ -e "$1/$sub/.git" ]; } || continue
    new_files "$1/$sub"
  done < <(git -C "$1" ls-files -s | awk '$1 == "160000" { sub(/^[^\t]*\t/, ""); print }')
}

# try_line PATH KIND: what Nix builds of the pattern at PATH: its checkout, against the gitlink, and its
# edits. KIND: git (a git flake sees tracked files only: untracked ones are counted apart) or path (a
# path: flake copies them)
try_line() {
  local p=$1 head link branch where rec mod new un parts=()
  head=$(git -C "$p" rev-parse -q --verify HEAD 2>/dev/null) || head=""
  if [ ! -e "$p/.git" ] || [ -z "$head" ]; then echo "tuteur: $p is empty: tuteur sync fills it"; return; fi
  link=$(gitlink "$p")
  if branch=$(git -C "$p" symbolic-ref -q --short HEAD); then where="branch $branch at"; else where="detached at"; fi
  if [ "$head" = "$link" ]; then rec="as recorded"; else rec="not the recorded $(describe_commit "$p" "$link")"; fi
  mod=$(git -C "$p" diff HEAD --name-status --no-renames | awk '$1 != "A"' | wc -l)
  new=$(git -C "$p" diff HEAD --name-status --no-renames | awk '$1 == "A"' | wc -l)
  un=$(new_files "$p" | wc -l)
  [ "$mod" = 0 ] || parts+=("$mod modified")
  if [ "$2" = path ]; then new=$((new + un)); un=0; fi
  [ "$new" = 0 ] || parts+=("$new new")
  [ "$un" = 0 ] || parts+=("$un new Nix doesn't see")
  [ ${#parts[@]} -gt 0 ] || parts=("no edits")
  echo "tuteur: $p: $where $(describe_commit "$p" "$head"), $rec: $(printf '%s, ' "${parts[@]}" | sed 's/, $//')"
}

# try_add_hint PATH: for each repo (the pattern, or one of its own submodules) with new files, the
# command that stages them for real, so that a git flake sees them
try_add_hint() {
  local repo files
  while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    files=$(new_files "$1" | awk -F'\t' -v r="$repo" '$1 == r { print substr($0, length(r) + 2) }' | while IFS= read -r f; do printf ' %q' "$f"; done)
    echo "tuteur: $repo: Nix sees a new file only once git tracks it: git -C $repo add --$files"
  done < <(new_files "$1" | cut -f1 | awk '!seen[$0]++')
}

cmd_try() {
  local repo="" stop="" names=() all name path url n super
  while [ $# -gt 0 ]; do
    case $1 in
      -C) if [ $# -lt 2 ] || [ -z "$2" ]; then die "-C needs a repository"; fi; repo=$2; shift 2 ;;
      --stop) stop=1; shift ;;
      --) shift ;;
      -h|--help) sed -n '/^#   try /,/^set /p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
      -*) die "unknown option $1 (usage: tuteur try [-C REPO] [NAME...], or tuteur try [-C REPO] --stop)" ;;
      *) names+=("$1"); shift ;;
    esac
  done
  [ -z "$stop" ] || [ ${#names[@]} -eq 0 ] || die "try --stop takes no names: it undoes all that try did"
  locate "$repo"
  if [ -z "$PATTERNS" ] && super=$(git rev-parse --show-superproject-working-tree 2>/dev/null) && [ -n "$super" ]; then
    die "$TOP is a submodule of $super: run tuteur from the repository's top (-C $super)"
  fi
  if [ -n "$stop" ]; then try_stop; return; fi
  all=$(patterns_registered .gitmodules)
  [ -n "$all" ] || die "no patterns here: tuteur add URL adds one"
  for name in "${names[@]}"; do
    cut -f1 <<<"$all" | grep -qxF -- "$name" || die "no pattern named $name"
  done
  if [ "$FLAKE" != . ]; then
    echo "tuteur: $FLAKE is a path: flake: every build reads its working tree, patterns and new files included; try has nothing to turn on"
    while IFS=$'\t' read -r name path url; do try_line "$path" path; done <<<"$all"
    echo "tuteur: build from the repository's top: nix build 'path:$FLAKE#tools', nix shell 'path:$FLAKE#tools' -c TOOL, or nix flake check 'path:$FLAKE'"
    return
  fi
  # HEAD holding the marker: refuse before writing anything (marking it again would leave it committed)
  if git cat-file -e "HEAD:$TRY" 2>/dev/null; then
    if [ -n "$(git diff --cached --name-only --diff-filter=D -- "$TRY")" ]; then
      die "$TRY is committed and its removal is staged; nothing changed: commit the removal (git commit -m 'Remove tuteur try marker'), then tuteur try"
    fi
    die "$TRY is committed, so the tree is clean to Nix; nothing changed: tuteur try --stop, commit its removal, then tuteur try"
  fi
  # Nix reads every pattern from the work tree while try is on, and fails on an empty one
  while IFS=$'\t' read -r name path url; do
    [ -e "$path/.git" ] || die "$path is empty, and Nix fails on an empty pattern while try is on; nothing changed: git submodule update --init --recursive -- $path (or tuteur sync)"
    n=$(empty_nested "$path")
    [ -z "$n" ] || die "$path's own submodules are empty ($n), and Nix fails on them while try is on; nothing changed: git -C $path submodule update --init --recursive (or tuteur sync)"
  done <<<"$all"
  if [ ! -f "$TRY" ] || [ -n "$(git diff HEAD --name-only -- "$TRY")" ] || [ -z "$(git ls-files -- "$TRY")" ]; then
    printf '%s\n' "# tuteur try is on: Nix builds of this repository read its working tree, and its patterns'." \
      "# tuteur try --stop turns it off (nix run .#tuteur -- try --stop); tuteur check fails until then. Never commit this file." > "$TRY"
  fi
  [ -n "$(git ls-files -- "$TRY")" ] || git add -N -f -- "$TRY"
  # a file marked with intent to add is a change against HEAD: Nix reads the work tree
  [ -n "$(git diff HEAD --name-only -- "$TRY")" ] || die "$TRY is marked but the tree is still clean to git: tuteur try --stop, then tuteur try"
  echo "tuteur: try is on: Nix builds of this repository read its working tree, and its patterns' ($TRY marks it)"
  while IFS=$'\t' read -r name path url; do try_line "$path" git; done <<<"$all"
  while IFS=$'\t' read -r name path url; do
    [ ${#names[@]} -eq 0 ] || printf '%s\n' "${names[@]}" | grep -qxF -- "$name" || continue
    try_add_hint "$path"
  done <<<"$all"
  echo "tuteur: build from the repository's top: nix build .#tools, nix shell .#tools -c TOOL, or nix flake check"
  echo "tuteur: tuteur try --stop turns try off (before git stash or a pull with --autostash here), and tuteur check fails until then"
}

# try_stop: undo what try did: remove its marker (a committed one: the removal is staged). Never
# touches a pattern.
try_stop() {
  local state name path url head link
  # graft try's marker (graft v2)
  if [ -n "$(git ls-files -- "$OLD_TRY")" ] || [ -e "$OLD_TRY" ]; then
    [ -z "$(git ls-files -- "$OLD_TRY")" ] || git update-index --force-remove -- "$OLD_TRY"
    rm -f -- "$OLD_TRY"
    echo "tuteur: removed $OLD_TRY, graft try's marker"
  fi
  state=$(try_state)
  if [ -z "$state" ]; then echo "tuteur: try is not on; nothing to undo"; return 0; fi
  [ -z "$(git ls-files -- "$TRY")" ] || git update-index --force-remove -- "$TRY"
  rm -f -- "$TRY"
  echo "tuteur: try is off: Nix builds the recorded patterns while the tree is clean"
  [ "$state" != committed ] || echo "tuteur: $TRY was committed: its removal is staged; commit it"
  while IFS=$'\t' read -r name path url; do
    { [ -n "$name" ] && [ -e "$path/.git" ]; } || continue
    head=$(git -C "$path" rev-parse -q --verify HEAD 2>/dev/null) || continue
    link=$(gitlink "$path")
    if [ -n "$(git -C "$path" status --porcelain --untracked-files=no)" ]; then
      echo "tuteur: $path stays as you left it: git submodule update --recursive -- $path goes back to its pin (commit or stash its edits first)"
    elif [ "$head" != "$link" ]; then
      echo "tuteur: $path stays as you left it: git submodule update --recursive -- $path goes back to its pin"
    fi
  done < <(patterns_registered .gitmodules)
}

sub=${1:-}; shift || true
case $sub in
  add) cmd_add "$@" ;;
  sync) cmd_sync "$@" ;;
  check) cmd_check "$@" ;;
  status) cmd_status "$@" ;;
  try) cmd_try "$@" ;;
  *) die "usage: patterns.sh add|sync|check|status|try" ;;
esac
