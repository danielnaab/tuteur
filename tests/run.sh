#!/usr/bin/env bash
# End-to-end test of tuteur: providers are local bare repositories with release tags, added into
# consumers as git submodules with file:// URLs. Sections: mkflake (discovery, wiring, the errors),
# nix (the Nix behaviours tuteur relies on: regression tests against Nix changes), kits (mkFlake's seam with pot), add, sync, check, outdated, status, changelog, upgrade, tuteur
# (tuteur's own pin), workflows, ci, migrate. Needs nix, git and jq; fetches nixpkgs on the first run.
# Usage: tests/run.sh [SECTION...] (from anywhere; default: every section, in order). KEEP=1 leaves the
# work directory, to debug a failure.
set -euo pipefail

src=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap '[ -n "${KEEP:-}" ] || rm -rf "$work"' EXIT
[ -z "${KEEP:-}" ] || echo "work: $work"
# tuteur as the consumers use it: a copy of this checkout's working tree, unchanged, used as a path:
# input (a scheme without submodules, like github: and tarballs: Nix refuses an input whose flake.nix
# declares inputs.self.submodules there)
tuteur=$work/tuteur
mkdir -p "$tuteur" && (cd "$src" && tar --exclude=./.git --exclude=./result -cf - .) | tar -C "$tuteur" -xf -
# git as a reader's would run, with what tests need: file:// submodules (git >= 2.38 refuses them by
# default), no signing, a name. Through the environment, so tuteur's own git calls get it too.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_COUNT=6 \
  GIT_CONFIG_KEY_0=protocol.file.allow GIT_CONFIG_VALUE_0=always \
  GIT_CONFIG_KEY_1=user.name GIT_CONFIG_VALUE_1=test \
  GIT_CONFIG_KEY_2=user.email GIT_CONFIG_VALUE_2=test@example.com \
  GIT_CONFIG_KEY_3=commit.gpgsign GIT_CONFIG_VALUE_3=false \
  GIT_CONFIG_KEY_4=tag.gpgsign GIT_CONFIG_VALUE_4=false \
  GIT_CONFIG_KEY_5=init.defaultBranch GIT_CONFIG_VALUE_5=main
git_() { git "$@"; }
# tools the test runs from nixpkgs, at the commit tuteur's flake.lock pins (already fetched for tuteur)
# shellcheck disable=SC2034 # used by later sections
np="github:NixOS/nixpkgs/$(jq -r '.nodes.nixpkgs.locked.rev' "$tuteur/flake.lock")"
sys=$(nix eval --impure --raw --expr builtins.currentSystem)
pass() { echo "ok   $*"; }
fail() { echo "FAIL $*" >&2; [ -z "${out:-}" ] || { echo "(last output:)" >&2; tail -8 <<<"$out" >&2; }; exit 1; }
# expect <description> <command...>: the command must succeed
expect() { local d=$1; shift; if "$@"; then pass "$d"; else fail "$d"; fi; }
# refuse <description> <command...>: the command must fail
refuse() { local d=$1; shift; if "$@"; then fail "$d"; else pass "$d"; fi; }
quiet() { "$@" >/dev/null 2>&1; }
# ran <description> <command...>: the command must succeed; its output (both streams) in $out
ran() { local d=$1; shift; if out=$("$@" 2>&1); then pass "$d"; else echo "$out" >&2; fail "$d"; fi; }
# refused <description> <command...>: the command must fail; its output (both streams) in $out
refused() { local d=$1; shift; if out=$("$@" 2>&1); then echo "$out" >&2; fail "$d"; else pass "$d"; fi; }
# has TEXT: $out holds TEXT as a whole line; holds TEXT: anywhere
has() { grep -qxF -- "$1" <<<"$out"; }
holds() { grep -qF -- "$1" <<<"$out"; }
# jsv ARGS: check-jsonschema (the contracts' validator), from the nixpkgs tuteur's flake.lock pins, built once
jsv_bin=""
jsv() {
  [ -n "$jsv_bin" ] || jsv_bin=$(nix build --no-link --print-out-paths --impure \
    --expr "(builtins.getFlake \"path:$tuteur\").inputs.nixpkgs.legacyPackages.$sys.check-jsonschema")/bin/check-jsonschema
  "$jsv_bin" "$@"
}
# valid SCHEMA [FILE...]: each FILE (default: $out, one JSON document) validates against SCHEMA, a path in the checkout
valid() {
  local s=$1 r; shift
  if [ $# -eq 0 ]; then printf '%s\n' "$out" > "$work/valid.json"; set -- "$work/valid.json"; fi
  r=$(jsv --default-filetype json --schemafile "$src/$s" "$@" 2>&1) || { echo "$r" >&2; return 1; }
}
# stdout_of CMD...: CMD's stdout alone (its stderr in $work/stderr), for ran: a JSON document to parse
stdout_of() { "$@" 2>"$work/stderr"; }
# exit_of CMD...: CMD's exit status, printed (its output in $work/exit.out)
exit_of() { local rc=0; "$@" >"$work/exit.out" 2>&1 || rc=$?; echo "$rc"; }
# rest_first TEXT: the first quoted line of upstream notes' "The rest of its CHANGELOG.md" part
rest_first() { awk '/^The rest of its CHANGELOG.md/ { getline; getline; print; exit }' <<<"$1"; }
# tuteur ci as CI runs it: the nixos/nix image has little beyond nix, so every tool tuteur ci needs
# must come from its own runtimeInputs. ci_ runs it with nothing but nix and git on PATH (the image has git,
# which the workflows' checkout step uses, and Nix runs it to read a git flake's submodules).
bare=$work/bare-bin
mkdir -p "$bare" && ln -s "$(command -v nix)" "$bare/nix" && ln -s "$(command -v git)" "$bare/git"
# ci_ [VAR=VALUE...] STEP
ci_() { local vars=(); while [[ ${1:-} == *=* ]]; do vars+=("$1"); shift; done; env "${vars[@]}" PATH="$bare" nix run .#tuteur -- ci "$@"; }
# tuteur from tuteur's own flake, as `nix run github:danielnaab/tuteur -- ...` runs it
G() { nix run "path:$tuteur" -- "$@"; }
# tuteur as the repo in the current directory runs it
g() { nix run .#tuteur -- "$@"; }

# Providers. prov NAME: a provider's work tree $work/src/NAME, with its origin $work/NAME.git (its
# URL file://$work/NAME.git); release NAME TAG [-a]: commit everything, tag (annotated with -a), push.
url() { echo "file://$work/$1.git"; }
prov() {
  mkdir -p "$work/src/$1"
  git_ -C "$work/src/$1" init -q
  git_ init -q --bare "$work/$1.git"
  git_ -C "$work/src/$1" remote add origin "$(url "$1")"
  echo "# $1" > "$work/src/$1/README.md"
}
release() {
  local d=$work/src/$1
  git_ -C "$d" add -A && git_ -C "$d" commit -q --allow-empty -m "$2"
  if [ "${3:-}" = -a ]; then git_ -C "$d" tag -a -m "$1 $2" "$2"; else git_ -C "$d" tag "$2"; fi
  git_ -C "$d" push -q origin HEAD:refs/heads/main "refs/tags/$2"
}
sha() { git_ -C "$work/src/$1" rev-parse "$2^{commit}"; }

# kb: a tool that prints its version (a file in the pattern), and a check on the consumer's
# knowledge-base.yaml, skipped when it has none
prov kb
cat > "$work/src/kb/tuteur.nix" <<'EOF'
{ pkgs, consumer, ... }:
{
  tools.kb-lint = pkgs.writeShellScriptBin "kb-lint" "echo kb-lint ${builtins.readFile ./version}";
  checks.lint = pkgs.runCommand "kb-lint-check" { } (
    if builtins.pathExists "${consumer}/knowledge-base.yaml"
    then "grep -qx ok ${consumer}/knowledge-base.yaml || { echo 'kb: knowledge-base.yaml is not ok' >&2; exit 1; }; touch $out"
    else "touch $out");
}
EOF
printf 'v1.0.0' > "$work/src/kb/version"
release kb v1.0.0

# nk: needs kb, and uses its tool and its files
prov nk
cat > "$work/src/nk/tuteur.nix" <<EOF
{ pkgs, patterns, ... }:
{
  requires.kb = "$(url kb)";
  tools.nb-index = pkgs.writeShellScriptBin "nb-index" ''
    \${patterns.kb.tools.kb-lint}/bin/kb-lint
    echo "nb-index reads \$(cat \${patterns.kb}/version)"
  '';
  apps.nb = { type = "app"; program = "\${patterns.nk.tools.nb-index}/bin/nb-index"; };
}
EOF
release nk v1.0.0

# mk: a tool named like nk's
prov mk
cat > "$work/src/mk/tuteur.nix" <<'EOF'
{ pkgs, ... }: { tools.nb-index = pkgs.writeShellScriptBin "nb-index" "echo mk"; }
EOF
release mk v1.0.0

# same: passes nk's tool on under the same name (one store path: one tool)
prov same
cat > "$work/src/same/tuteur.nix" <<'EOF'
{ patterns, ... }: { tools.nb-index = patterns.nk.tools.nb-index; }
EOF
release same v1.0.0

# docs: no tuteur.nix, only files
prov docs
echo "policy v1" > "$work/src/docs/policy.md"
release docs v1.0.0

# rs: takes tuteur's own names
prov rs
cat > "$work/src/rs/tuteur.nix" <<'EOF'
{ ... }: { apps.tuteur = { type = "app"; program = "/bin/sh"; }; }
EOF
release rs v1.0.0

# lk: a tool from its own pinned source (an eval-time fetch with a hash), not the consumer's nixpkgs
prov lk
mkdir -p "$work/dep" && echo "pinned-dep-ok" > "$work/dep/msg"
tar -C "$work" -czf "$work/dep.tar.gz" dep
dep_hash=$(nix-prefetch-url --unpack "file://$work/dep.tar.gz" 2>/dev/null)
cat > "$work/src/lk/tuteur.nix" <<EOF
{ pkgs, ... }:
let dep = builtins.fetchTarball { url = "file://$work/dep.tar.gz"; sha256 = "$dep_hash"; };
in { tools.lk = pkgs.writeShellScriptBin "lk" "cat \${dep}/msg"; }
EOF
release lk v1.0.0

# Consumers. consumer DIR [FLAKE_BODY]: a git repo at DIR with a flake.nix (a top-level git flake
# with inputs.self.submodules, by default), nothing committed
consumer() {
  local c=$1
  mkdir -p "$c"
  git_ -C "$c" init -q
  local body
  body=$(printf '  inputs.self.submodules = true;\n  inputs.tuteur.url = "path:%s";\n  outputs = inputs: inputs.tuteur.lib.mkFlake { inherit inputs; };' "$tuteur")
  printf '{\n%s\n}\n' "${2:-$body}" > "$c/flake.nix"
}
# by_hand NAME [TAG [DIR]]: tuteur NAME at TAG (default v1.0.0) into DIR (default patterns) of the repo in
# the current directory, with plain git, as tuteur add does; staged
by_hand() {
  local d=${3:-.patterns}
  git_ submodule add -q --force -- "$(url "$1")" "$d/$1" 2>/dev/null
  git_ -C "$d/$1" checkout -q --detach "${2:-v1.0.0}"
  [ -f "$d/README.md" ] || cp "$tuteur/lib/patterns-readme.md" "$d/README.md"
  git_ add -- "$d/$1" "$d/README.md" .gitmodules
}
commit() { git_ add -A && git_ commit -q --allow-empty -m "${1:-commit}"; }
# tools_out TOOL: run TOOL from the current directory's tools
tools_out() { nix build -o "$work/result" .#tools && "$work/result/bin/$1"; }

sec_mkflake() {
  c=$work/c1 && consumer "$c" && cd "$c"
  commit init
  ran "mkflake: no patterns: tools is an empty env" nix build --no-link .#tools
  by_hand kb && by_hand nk && commit "kb, nk"
  ran "mkflake: discovery: nk's tool, from the patterns alone" tools_out nb-index
  expect "and it runs kb's tool, a sibling's" has "kb-lint v1.0.0"
  expect "and reads kb's files" has "nb-index reads v1.0.0"
  ran "mkflake: a provider's app" nix run .#nb
  expect "runs" has "nb-index reads v1.0.0"
  ran "mkflake: checks, prefixed by the pattern" nix eval --json ".#checks.$sys" --apply builtins.attrNames
  expect "kb-lint" holds '"kb-lint"'
  expect "mkflake: a check that skips without its settings file" quiet nix build --no-link ".#checks.$sys.kb-lint"
  echo bad > knowledge-base.yaml && commit "settings"
  refused "mkflake: a check reading the repo's settings file" nix build --no-link ".#checks.$sys.kb-lint"
  expect "fails on them" holds "kb: knowledge-base.yaml is not ok"
  echo ok > knowledge-base.yaml && commit "settings ok"
  expect "and passes on good ones" quiet nix build --no-link ".#checks.$sys.kb-lint"
  ran "mkflake: devShells.default holds the tools" nix eval --raw ".#devShells.$sys.default.name"
  # isolation: each pattern is copied alone, so a commit of the repo's own doesn't change a tool
  before=$(nix eval --raw .#tools.outPath)
  echo "more" > notes.md && commit "an unrelated commit"
  expect "mkflake: isolation: the tools are the same store path after a repo commit" test "$(nix eval --raw .#tools.outPath)" = "$before"

  # a missing sibling
  git_ rm -q .patterns/kb && commit "no kb"
  refused "mkflake: requires: a missing sibling" nix build --no-link .#tools
  expect "says how to add it" holds "tuteur: nk needs kb, which this repository does not have: tuteur add $(url kb)"
  ran "mkflake: and tuteur's own app still evaluates" nix eval --raw ".#apps.$sys.tuteur.type"
  by_hand kb && commit "kb again"

  # a collision, and one store path given twice
  by_hand mk && commit "mk"
  refused "mkflake: two providers' tools with one name" nix build --no-link .#tools
  expect "names both" holds "tuteur: tools nb-index (from mk and nk): two patterns provide the same name"
  ran "mkflake: tuteur's app evaluates beside it" nix eval --raw ".#apps.$sys.tuteur.type"
  git_ rm -q .patterns/mk && by_hand same && commit "same, not mk"
  ran "mkflake: the same store path from two providers is one tool" tools_out nb-index
  expect "nk's" has "nb-index reads v1.0.0"
  git_ rm -q .patterns/same && commit "no same"

  # tuteur's names
  by_hand rs && commit "rs"
  refused "mkflake: a provider's apps.tuteur" nix build --no-link .#tools
  expect "is an error" holds "tuteur: apps tuteur (from rs): that name is tuteur's; the provider must rename it"
  ran "mkflake: and tuteur's app is tuteur's" nix eval --raw ".#apps.$sys.tuteur.meta.description"
  expect "tuteur's" holds "tuteur: add, sync"
  git_ rm -q .patterns/rs && commit "no rs"

  # a provider whose tuteur.nix throws fails the tools and the checks, naming it (never dropped)
  prov bad
  printf '{ pkgs, ... }: throw "bad: unsupported configuration"\n' > "$work/src/bad/tuteur.nix" && release bad v1.0.0
  by_hand bad && commit "bad"
  refused "mkflake: a provider that throws fails the tools" nix build --no-link .#tools
  expect "with its message" holds "bad: unsupported configuration"
  expect "naming its tuteur.nix" holds "while evaluating .patterns/bad/tuteur.nix"
  refused "mkflake: and nix flake check" nix flake check --no-build
  ran "mkflake: tuteur's app still evaluates" nix eval --raw ".#apps.$sys.tuteur.type"
  refused "check: fails on it, from the repo's own app" g check
  expect "says why" holds "tuteur: the flake's tools or checks don't evaluate (above): a provider's tuteur.nix fails"
  # one that doesn't parse breaks every output (Nix can't catch it): check from outside names it
  printf '{ pkgs, ... }: { tools.x = pkgs.hello;\n' > "$work/src/bad/tuteur.nix" && release bad v1.0.1
  git_ -C .patterns/bad fetch -q --tags && git_ -C .patterns/bad checkout -q --detach v1.0.1 && commit "bad v1.0.1"
  refused "check: a tuteur.nix that doesn't parse, from tuteur's own flake" G check -C .
  expect "names it" holds "tuteur: .patterns/bad/tuteur.nix doesn't evaluate (above): every output of this flake fails until it does, tuteur's own app too; move the pattern back (git submodule update --recursive -- .patterns/bad), or from outside: nix run github:danielnaab/tuteur/v0.1.0 -- upgrade -C . bad@TAG"
  git_ rm -q .patterns/bad && commit "no bad"

  # a pattern with no tuteur.nix, and one with its own pinned source
  by_hand docs && by_hand lk && commit "docs, lk"
  ran "mkflake: a docs-only pattern beside providers; a provider's own pinned fetch" tools_out lk
  expect "the pinned source" has "pinned-dep-ok"

  # the repo's own tools, apps and checks (perSystem): merged like a provider's, named self
  # shellcheck disable=SC2016 # Nix's own expressions
  sed -i 's|mkFlake { inherit inputs; }|mkFlake { inherit inputs; perSystem = { pkgs, patterns, ... }: { tools.mine = pkgs.writeShellScriptBin "mine" "cat ${patterns.docs}/policy.md"; checks.own = pkgs.runCommand "own" { } "touch $out"; devShells.default = pkgs.mkShell { name = "own-shell"; }; }; }|' flake.nix
  commit "perSystem"
  ran "mkflake: perSystem: the repo's own tool, beside the providers'" tools_out mine
  expect "reads a pattern" has "policy v1"
  expect "and the providers' tools are still there" test -x "$work/result/bin/lk"
  ran "mkflake: perSystem's checks, unprefixed" nix eval --json ".#checks.$sys" --apply builtins.attrNames
  expect "own" holds '"own"'
  ran "mkflake: perSystem's devShells.default replaces tuteur's" nix eval --raw ".#devShells.$sys.default.name"
  expect "own-shell" has "own-shell"
  sed -i 's|tools.mine = |tools.lk = |' flake.nix && commit "perSystem lk"
  refused "mkflake: perSystem: a tool named like a provider's" nix build --no-link .#tools
  expect "is a collision, naming self" holds "tuteur: tools lk (from pattern lk and the consumer's perSystem): both provide the same name; rename the consumer's own"
  git_ checkout -q HEAD~2 -- flake.nix && commit "no perSystem"

  # the repo's own outputs: merged last, per name; tuteur's app stays tuteur's
  sed -i 's|inputs.tuteur.lib.mkFlake { inherit inputs; }|inputs.tuteur.lib.mkFlake { inherit inputs; outputs = { apps.'"$sys"'.nb = { type = "app"; program = "/bin/echo"; }; packages.'"$sys"'.extra = inputs.self; }; }|' flake.nix
  commit "own outputs"
  ran "mkflake: the repo's own app replaces a provider's" nix eval --raw ".#apps.$sys.nb.program"
  expect "the repo's" has "/bin/echo"
  expect "mkflake: the repo's own package beside the tools" quiet nix eval --raw ".#packages.$sys.extra.outPath"
  expect "and the tools" quiet nix eval --raw ".#packages.$sys.tools.outPath"
  sed -i 's|apps.'"$sys"'.nb = |apps.'"$sys"'.tuteur = |' flake.nix && commit "own tuteur app"
  refused "mkflake: the repo's own apps.tuteur" nix eval --raw ".#apps.$sys.tuteur.type"
  expect "is an error" holds "tuteur: mkFlake's outputs has apps.$sys.tuteur: that name is tuteur's; rename the repo's own"
  git_ checkout -q HEAD~2 -- flake.nix && commit "outputs back"

  # Without inputs.self.submodules a git flake's source has no patterns at all (absent, not empty):
  # .gitmodules says what should be there
  sed -i '/inputs.self.submodules/d' flake.nix && commit "no self.submodules"
  refused "mkflake: registered but absent (no inputs.self.submodules)" nix build --no-link .#tools
  expect "says what to add" holds "tuteur: .gitmodules registers .patterns/docs, .patterns/kb, .patterns/lk, .patterns/nk but the flake's source lacks them: add inputs.self.submodules = true; to flake.nix (Nix >= 2.27). Fetched with github:? use git+https://…, which keeps submodules."
  git_ checkout -q HEAD~1 -- flake.nix && commit "self.submodules back"
  # a tarball of the repo (what github: fetches) has no submodules either
  git_ archive --format=tar.gz -o "$work/c1.tar.gz" --prefix=c1/ HEAD
  ran "mkflake: a tarball of the repo (github:): the tools build without the patterns" nix build --no-link "tarball+file://$work/c1.tar.gz#tools"
  expect "warning, and saying use git+https" holds "tuteur: .patterns/docs, .patterns/kb, .patterns/lk, .patterns/nk are empty in the flake's source, so the tools leave out what they give: run git submodule update --init --recursive (or tuteur sync). Fetched with github:? use git+https://…, which keeps submodules."

  # a folder that isn't a submodule
  mkdir -p .patterns/stray && echo x > .patterns/stray/x.md && commit "stray"
  refused "mkflake: a folder in the patterns folder that isn't a submodule" nix build --no-link .#tools
  expect "is named" holds "tuteur: .patterns/stray is not a submodule: tuteur add URL, or remove it"
  git_ rm -rq .patterns/stray && commit "no stray"

  # the wrong dir: tuteur's marker README is how it knows
  sed -i 's|mkFlake { inherit inputs; }|mkFlake { inherit inputs; dir = "patterns"; }|' flake.nix && commit "dir = patterns"
  refused "mkflake: dir names no folder, and tuteur's README is elsewhere" nix build --no-link .#tools
  expect "says where it is" holds "tuteur: tuteur's README is in .patterns/ but mkFlake's dir is \"patterns\": set dir = \".patterns\"; (or move the patterns)"
  ran "mkflake: and tuteur's app still evaluates" nix eval --raw ".#apps.$sys.tuteur.type"
  refused "check: from the repo's own app, too" g check
  expect "says so" holds "tuteur: tuteur's README is in .patterns/ but mkFlake's dir is \"patterns\""
  sed -i 's|dir = "patterns";|dir = "docs";|' flake.nix
  mkdir -p docs && echo "# docs" > docs/README.md && commit "dir = docs"
  refused "mkflake: dir names a folder without tuteur's README" nix build --no-link .#tools
  expect "says where it is" holds "tuteur: tuteur's README is in .patterns/ but mkFlake's dir is \"docs\": set dir = \".patterns\"; (or move the patterns)"
  sed -i 's|dir = "docs";|dir = "a/b";|' flake.nix && commit "dir = a/b"
  refused "mkflake: dir must be one folder name" nix build --no-link .#tools
  expect "says so" holds "tuteur: mkFlake's dir must be one folder name (letters, digits, . _ -; not ., .. or .git), got \"a/b\""
  sed -i 's|mkFlake { inherit inputs; dir = "a/b"; }|mkFlake { inherit inputs; }|' flake.nix && git_ rm -rq docs && commit "dir back"

  # a copy-mode patterns README (graft v2.12): the upgrade steps, not a confusing error
  cp .patterns/README.md "$work/readme" && printf '\n| Scion | Commit |\n|---|---|\n' >> .patterns/README.md && commit "copy mode"
  refused "mkflake: a copy-mode patterns README" nix build --no-link .#tools
  expect "points to the Upgrading steps" holds "tuteur: .patterns/README.md is graft's copy-mode README (v2.12 or earlier): graft v2.13.0 pins scions with git submodules; follow the Upgrading steps of v2.13.0 in graft's CHANGELOG.md"
  cp "$work/readme" .patterns/README.md && commit "readme back"

  # A flake in a subdirectory, run as path: (keeps the rest of the repo out of the store): the
  # patterns live under it; a fresh clone has them empty until git initialises them
  s=$work/sub && mkdir -p "$s/nix/tools" "$s/notebook" && git_ -C "$s" init -q && cd "$s"
  echo "private" > notebook/secret.md
  cat > nix/tools/flake.nix <<EOF
{
  inputs.tuteur.url = "path:$tuteur";
  outputs = inputs: inputs.tuteur.lib.mkFlake { inherit inputs; dir = ".patterns"; outputs.own = "mine"; };
}
EOF
  by_hand kb v1.0.0 nix/tools/.patterns && by_hand nk v1.0.0 nix/tools/.patterns && commit init
  ran "mkflake: a path: flake in a subdirectory" nix build -o "$work/result" "path:$s/nix/tools#tools"
  expect "with its patterns" quiet "$work/result/bin/nb-index"
  git_ clone -q "$s" "$work/sub-clone" && cd "$work/sub-clone"
  ran "mkflake: path: flake, fresh clone: the tools build without the empty patterns" nix build -o "$work/result" "path:$PWD/nix/tools#tools"
  expect "warning which" holds "tuteur: .patterns/kb, .patterns/nk are empty in the flake's source, so the tools leave out what they give: run git submodule update --init --recursive (or tuteur sync)"
  expect "and leave their tools out" test ! -e "$work/result/bin/nb-index"
  ran "mkflake: and tuteur's app evaluates, to fill them" nix eval --raw "path:$PWD/nix/tools#apps.$sys.tuteur.type"
  ran "mkflake: and the repo's own outputs" nix eval --raw "path:$PWD/nix/tools#own"
  expect "evaluate" has "mine"
  git_ submodule update -q --init
  expect "mkflake: path: flake after git submodule update --init" quiet nix build --no-link "path:$PWD/nix/tools#tools"
  mkdir -p nix/tools/.patterns/copy && echo x > nix/tools/.patterns/copy/a.md
  refused "mkflake: path: flake, a folder without .git is not a submodule" nix build --no-link "path:$PWD/nix/tools#tools"
  expect "is named" holds "tuteur: .patterns/copy is not a submodule: tuteur add URL, or remove it"
  rm -rf nix/tools/.patterns/copy
}

# The Nix behaviours the model depends on (design finding 1): a regression test, so a Nix release
# that changes them fails here rather than in a consumer.
sec_nix() {
  c=$work/n1 && consumer "$c" && cd "$c"
  by_hand kb && commit init && quiet nix flake lock && commit lock
  ran "nix: a clean tree builds the pattern at its gitlink" tools_out kb-lint
  expect "v1.0.0" has "kb-lint v1.0.0"
  printf 'edited' > .patterns/kb/version
  ran "nix: clean parent, uncommitted edit in a pattern" tools_out kb-lint
  expect "ignored (Nix fetches the gitlink)" has "kb-lint v1.0.0"
  echo "# dirty" >> flake.nix
  ran "nix: dirty parent (a tracked file modified), uncommitted edit in a pattern" tools_out kb-lint
  expect "used (Nix reads the working tree)" has "kb-lint edited"
  git_ checkout -q -- flake.nix
  ran "nix: path: reads the working tree" sh -c "nix build -o '$work/result' 'path:$c#tools' && '$work/result/bin/kb-lint'"
  expect "the edit" has "kb-lint edited"
  git_ -C .patterns/kb commit -qam "local only" && git_ add .patterns/kb && commit "an unpushed gitlink"
  refused "nix: a committed gitlink the provider's remote lacks" nix build --no-link .#tools
  expect "fails to fetch it" holds "Cannot find Git revision"
  # a commit reachable only from a tag
  git_ -C "$work/src/kb" checkout -q --detach v1.0.0
  printf 'v1.0.1' > "$work/src/kb/version" && git_ -C "$work/src/kb" commit -qam v1.0.1
  git_ -C "$work/src/kb" tag v1.0.1 && git_ -C "$work/src/kb" push -q origin refs/tags/v1.0.1
  git_ -C "$work/src/kb" checkout -q main
  git_ -C .patterns/kb fetch -q --tags && git_ -C .patterns/kb checkout -q --detach v1.0.1 && git_ add .patterns/kb && commit "tag-only"
  ran "nix: a commit only a tag reaches" tools_out kb-lint
  expect "is fetched" has "kb-lint v1.0.1"
  # nested: a provider's own submodules are fetched by Nix (git doesn't initialise them)
  prov pv
  git_ -C "$work/src/pv" submodule add -q "$(url docs)" .patterns/docs 2>/dev/null
  cat > "$work/src/pv/tuteur.nix" <<'EOF'
{ pkgs, pattern, ... }: { tools.pv = pkgs.writeShellScriptBin "pv" "cat ${pattern}/.patterns/docs/policy.md"; }
EOF
  release pv v1.0.0
  by_hand pv && commit "pv"
  expect "nix: git leaves a pattern's own submodules empty" test ! -e .patterns/pv/.patterns/docs/policy.md
  ran "nix: Nix fetches them" tools_out pv
  expect "nested" has "policy v1"
  git_ -C "$work/src/pv" config -f .gitmodules submodule..patterns/docs.url "file://$work/nonexistent.git"
  release pv v1.1.0
  git_ -C .patterns/pv fetch -q --tags && git_ -C .patterns/pv checkout -q --detach v1.1.0 && git_ add .patterns/pv && commit "pv v1.1.0"
  refused "nix: a nested submodule Nix can't fetch fails the consumer" nix build --no-link .#tools
  expect "names it" holds "nonexistent.git"
  git_ rm -q .patterns/pv && commit "no pv"
}

# The command sections share one consumer, $work/cmd, and the providers below: run them in order
# (add first). pa: a tool printing its version; releases v1.0.0, v1.0.1, v1.1.0 (annotated).
cmd_setup() {
  prov pa
  mkdir -p "$work/src/pa/docs/old"
  cat > "$work/src/pa/tuteur.nix" <<'EOF'
{ pkgs, ... }: { tools.pa = pkgs.writeShellScriptBin "pa" "echo pa ${builtins.readFile ./version}"; }
EOF
  echo "policy" > "$work/src/pa/docs/policy.md" && echo "old" > "$work/src/pa/docs/old/x.md"
  printf v1.0.0 > "$work/src/pa/version" && release pa v1.0.0
  printf v1.0.1 > "$work/src/pa/version" && release pa v1.0.1
  printf v1.1.0 > "$work/src/pa/version" && release pa v1.1.0 -a
  git_ -C "$work/src/pa" tag not-a-version && git_ -C "$work/src/pa" push -q origin not-a-version
  # nest: a provider with a submodule of its own
  prov nest
  git_ -C "$work/src/nest" submodule add -q "$(url docs)" .patterns/docs 2>/dev/null
  release nest v1.0.0
  # notag: no release
  prov notag && git_ -C "$work/src/notag" add -A && git_ -C "$work/src/notag" commit -qm init \
    && git_ -C "$work/src/notag" push -q origin HEAD:main
  c=$work/cmd && consumer "$c" && cd "$c"
  commit init && quiet nix flake lock && commit lock
}

sec_add() {
  cmd_setup
  ran "add: URL at its newest release" g add "$(url pa)"
  expect "says where and at what" has "tuteur: .patterns/pa <- v1.1.0 ($(sha pa v1.1.0 | cut -c1-7))"
  expect "and what's next" has "tuteur: next: commit"
  expect "add: the gitlink is the annotated tag's commit" test "$(git_ ls-files -s .patterns/pa | cut -d' ' -f2)" = "$(sha pa v1.1.0)"
  expect "add: staged: .gitmodules, the gitlink and the README" \
    test "$(git_ diff --cached --name-only | paste -sd ' ')" = ".gitmodules .patterns/README.md .patterns/pa"
  expect "add: the README carries tuteur's marker" test "$(head -1 .patterns/README.md)" = "<!-- managed by tuteur: https://github.com/danielnaab/tuteur -->"
  # shellcheck disable=SC2016 # markdown backticks
  expect "and names the repo's command" grep -qF '`nix run .#tuteur check`' .patterns/README.md
  expect "add: the URL in .gitmodules as given" test "$(git_ config -f .gitmodules submodule..patterns/pa.url)" = "$(url pa)"
  ran "add: URL@TAG" g add "$(url docs)@v1.0.0"
  expect "at that tag" has "tuteur: .patterns/docs <- v1.0.0 ($(sha docs v1.0.0 | cut -c1-7))"
  ran "add: a provider with submodules of its own" g add "$(url nest)"
  expect "says Nix fetches them" has "tuteur: note: .patterns/nest has its own submodules (.patterns/docs); tuteur fills them, and Nix fetches them too, so each must be reachable"
  expect "and fills them" test -f .patterns/nest/.patterns/docs/policy.md
  refused "add: an existing pattern" g add "$(url pa)"
  expect "says so" has "tuteur: .patterns/pa exists"
  refused "add: a relative URL" g add ../pa.git
  expect "says why" has "tuteur: a relative URL (../pa.git) won't resolve for Nix; give an absolute URL"
  refused "add: a provider with no release" g add "$(url notag)"
  expect "says so" has "tuteur: $(url notag) has no semver tags"
  refused "add: a tag that isn't upstream" g add "$(url pa)@v9.9.9" other
  expect "says so" has "tuteur: other: no tag v9.9.9 upstream"
  refused "add: git@host:path keeps its @ (only @TAG is split off)" G add 'git@nonexistent.invalid:x/y.git@v1.0.0'
  expect "lists that URL" holds "can't list tags at git@nonexistent.invalid:x/y.git"
  mkdir -p "$work/nongit"
  refused "add: outside a git work tree" G add -C "$work/nongit" "$(url pa)"
  expect "says so" holds "tuteur: not inside a git work tree"
  commit "pa, docs, nest"
  ran "add: the tools build from the new pattern" tools_out pa
  expect "at v1.1.0" has "pa v1.1.0"
  # a flake without inputs.self.submodules: add says to add it
  n=$work/noself && consumer "$n" "$(printf '  inputs.tuteur.url = "path:%s";\n  outputs = inputs: inputs.tuteur.lib.mkFlake { inherit inputs; };' "$tuteur")"
  ran "add: a top flake without inputs.self.submodules" G add -C "$n" "$(url docs)"
  expect "says it needs it" has "tuteur: next: commit; a git flake also needs inputs.self.submodules = true;"
  # a flake in a subdirectory: --dir from the top, or the repo's own app run from there
  s=$work/subcmd && mkdir -p "$s/nix/tools" && git_ -C "$s" init -q
  printf '{\n  inputs.tuteur.url = "path:%s";\n  outputs = inputs: inputs.tuteur.lib.mkFlake { inherit inputs; dir = ".patterns"; };\n}\n' "$tuteur" > "$s/nix/tools/flake.nix"
  refused "add: --dir beside no flake" G add -C "$s" --dir nix/.patterns "$(url docs)"
  expect "says so" has "tuteur: --dir nix/.patterns: no flake.nix in nix; the patterns folder goes beside the flake that uses them"
  ran "add: --dir PATH" G add -C "$s" --dir nix/tools/.patterns "$(url docs)"
  expect "there" has "tuteur: nix/tools/.patterns/docs <- v1.0.0 ($(sha docs v1.0.0 | cut -c1-7))"
  expect "and its README names the path: command" grep -qF "\`nix run 'path:nix/tools#tuteur' check\`" "$s/nix/tools/.patterns/README.md"
  ran "add: the next pattern goes to the same directory" G add -C "$s" "$(url kb)@v1.0.0"
  expect "found by tuteur's README" has "tuteur: nix/tools/.patterns/kb <- v1.0.0 ($(sha kb v1.0.0 | cut -c1-7))"
  s2=$work/subcmd2 && mkdir -p "$s2/nix/tools" && git_ -C "$s2" init -q && cp "$s/nix/tools/flake.nix" "$s2/nix/tools/" && git_ -C "$s2" add -A
  ran "add: the repo's own app, run from its subdirectory, puts the first pattern beside it" \
    sh -c "cd '$s2/nix/tools' && nix run 'path:$s2/nix/tools#tuteur' -- add '$(url docs)'"
  expect "in its dir" has "tuteur: nix/tools/.patterns/docs <- v1.0.0 ($(sha docs v1.0.0 | cut -c1-7))"
  cd "$c"
}

sec_sync() {
  cd "$work/cmd"
  git_ clone -q "$work/cmd" "$work/cmd-clone" && cd "$work/cmd-clone"
  expect "sync: a fresh clone's patterns are empty" test ! -e .patterns/pa/version
  ran "sync: fills them" g sync
  expect "says where each is" has "tuteur: .patterns/pa at v1.1.0 ($(sha pa v1.1.0 | cut -c1-7))"
  expect "filled" test -f .patterns/pa/version
  expect "sync: and a pattern's own submodules (Nix reads them while the tree is dirty)" test -f .patterns/nest/.patterns/docs/policy.md
  git_ -C .patterns/pa checkout -q v1.0.0
  ran "sync: a pattern checked out elsewhere (an agent's fix branch)" g
  expect "is left there, and said" has "tuteur: .patterns/pa at v1.0.0 ($(sha pa v1.0.0 | cut -c1-7)), not the recorded $(sha pa v1.1.0 | cut -c1-7): left as it is (git add .patterns/pa records it; git submodule update --recursive -- .patterns/pa goes back)"
  expect "not moved" test "$(git_ -C .patterns/pa rev-parse HEAD)" = "$(sha pa v1.0.0)"
  git_ -C .patterns/pa checkout -q --detach "$(sha pa v1.1.0)"
  echo "mine" >> .patterns/README.md
  ran "sync: rewrites tuteur's README" g sync
  expect "says so" has "tuteur: wrote .patterns/README.md"
  refuse "and the edit is gone" grep -q mine .patterns/README.md
  mkdir -p .forgejo/workflows && cp "$tuteur"/template/.forgejo/workflows/*.yaml .forgejo/workflows/
  echo "# old" >> .forgejo/workflows/tuteur-check.yaml && git_ add -A
  ran "sync: refreshes tuteur's workflows" g sync
  expect "says so" has "tuteur: refreshed .forgejo/workflows/tuteur-check.yaml"
  refused "sync: from tuteur's own flake" G sync -C .
  expect "says why" holds "tuteur: sync runs from the repo's own flake"
  cd "$work/cmd" && mkdir -p .forgejo/workflows && cp "$tuteur"/template/.forgejo/workflows/*.yaml .forgejo/workflows/ && commit "workflows"
}

sec_check() {
  cd "$work/cmd"
  ran "check: every pattern clean and at a release tag" g check
  expect "says so" has "tuteur: 3 patterns clean and at release tags"
  # a submodule the index holds as files (what `git add` does over a copied pattern still in the index)
  git_ rm -q --cached .patterns/docs && git_ update-index --add --cacheinfo "100644,$(git_ hash-object -w .patterns/docs/policy.md),.patterns/docs/policy.md"
  refused "check: a submodule tracked as files" G check -C .
  expect "says how to fix it" has "tuteur: .patterns/docs is tracked as files, not as a submodule: git rm -r -q --cached .patterns/docs, then git add .patterns/docs if .patterns/docs/.git exists; otherwise delete the folder and tuteur add its URL@TAG again"
  refused "check --committed: too" G check -C . --committed
  refused "sync: refuses it" g sync
  git_ reset -q -- .patterns/docs
  git_ update-index --add --cacheinfo "100644,$(git_ hash-object -w .patterns/docs/policy.md),.patterns/x/a.md"
  refused "add: over a path still tracked as files" G add -C . "$(url docs)" x
  expect "says so" has "tuteur: .patterns/x is still tracked as files (a copied pattern?): git rm -r -q --cached .patterns/x, delete the folder, then tuteur add again"
  git_ rm -q --cached .patterns/x/a.md
  # shellcheck disable=SC2016 # sh's own expressions
  refuse "check: tuteur's README outside mkFlake's dir" sh -c 'env TUTEUR_IN_REPO=1 TUTEUR_DIR=patterns nix run "path:$1" -- check -C . >"$2" 2>&1' _ "$tuteur" "$work/out"
  expect "says set dir" grep -qF "tuteur: tuteur's README is in .patterns/ but mkFlake's dir is \"patterns\": set dir = \".patterns\"; in flake.nix (or move the patterns)" "$work/out"
  ran "check: from tuteur's flake, -C" G check -C "$work/cmd"
  echo "x" > .patterns/pa/untracked.txt
  ran "check: an untracked file in a pattern (Nix doesn't read it)" g check
  rm .patterns/pa/untracked.txt
  printf edited > .patterns/pa/version
  refused "check: an uncommitted edit in a pattern" g check
  expect "names it" has "tuteur: uncommitted edits in .patterns/pa: version (Nix builds ignore them while the rest of the tree is clean)"
  git_ -C .patterns/pa checkout -q -- version
  git_ -C .patterns/pa checkout -q --detach v1.0.1
  refused "check: a pattern checked out at another commit than the gitlink" g check
  expect "says both, and the fixes" has "tuteur: .patterns/pa is checked out at $(sha pa v1.0.1 | cut -c1-7) but the repository records $(sha pa v1.1.0 | cut -c1-7): git add .patterns/pa to record it, or git submodule update --recursive -- .patterns/pa to go back"
  git_ -C .patterns/pa commit -q --allow-empty -m "a fix" && git_ add .patterns/pa
  refused "check: a gitlink at no release" g check
  expect "names the nearest" holds "tuteur: .patterns/pa at $(git_ -C .patterns/pa rev-parse --short=7 HEAD) is not a release tag of $(url pa) (nearest: v1.0.1-1-g"
  expect "and the way on" holds "release it, then tuteur upgrade pa@TAG (or tuteur upgrade pa, the newest release of its major)"
  git_ -C .patterns/pa tag v1.0.9
  refused "check: a tag only the pattern's clone has" g check
  expect "says push it" has "tuteur: .patterns/pa: tag v1.0.9 exists locally but not at $(url pa): push it (git -C .patterns/pa push origin v1.0.9)"
  git_ -C .patterns/pa tag -d v1.0.9 >/dev/null
  git_ -C .patterns/pa checkout -q --detach "$(sha pa v1.1.0)" && git_ add .patterns/pa
  command mv "$work/pa.git" "$work/pa.away"
  ran "check: an upstream it can't list: the pattern's own tags" G check -C .
  expect "says so" holds "(upstream unreadable: checked local tags)"
  command mv "$work/pa.away" "$work/pa.git"
  mkdir -p .patterns/stray && echo x > .patterns/stray/a.md
  refused "check: a folder that isn't a submodule" g check
  expect "names it" has "tuteur: .patterns/stray is not a submodule: tuteur add URL, or remove it"
  rm -rf .patterns/stray
  cp .gitmodules "$work/gm" && git_ config -f .gitmodules submodule..patterns/docs.url ../docs.git
  refused "check: a relative URL" g check
  expect "says so" has "tuteur: .patterns/docs: .gitmodules gives a relative URL (../docs.git), which Nix can't resolve: give an absolute one (git config -f .gitmodules submodule..patterns/docs.url URL)"
  cp "$work/gm" .gitmodules
  sed -i '/inputs.self.submodules/d' flake.nix
  refused "check: a top flake without inputs.self.submodules" g check
  expect "says to add it" has "tuteur: flake.nix doesn't declare inputs.self.submodules = true;, so Nix sees no patterns: add it (Nix 2.27 or later)"
  git_ checkout -q -- flake.nix
  echo "# mine" >> .forgejo/workflows/tuteur-check.yaml
  refused "check: an edited workflow of tuteur's" g check
  expect "says so" holds "tuteur: .forgejo/workflows/tuteur-check.yaml differs from the copy this tuteur version ships"
  git_ checkout -q -- .forgejo
  git_ clone -q "$work/cmd" "$work/cmd-fresh" && cd "$work/cmd-fresh"
  refused "check: a fresh clone's empty patterns" g check
  expect "says how to fill it" has "tuteur: .patterns/pa is empty: git submodule update --init --recursive -- .patterns/pa (or tuteur sync)"
  ran "check --committed: what a commit holds, with no pattern filled" g check --committed
  expect "says so" has "tuteur: 3 patterns registered and at release tags"
  cd "$work/cmd"
  # two patterns folders, a copy-mode README
  mkdir -p other && cp .patterns/README.md other/ && git_ add other
  refused "check: two patterns folders" g check
  expect "names both" has "tuteur: two patterns folders: .patterns, other; tuteur supports one per repository"
  git_ rm -rqf other
  cp .patterns/README.md "$work/readme" && printf '| Scion | Commit |\n' >> .patterns/README.md && git_ add .patterns/README.md
  refused "check: a copy-mode README" G check -C .
  expect "points to the Upgrading steps" holds "tuteur: .patterns/README.md is graft's copy-mode README (v2.12 or earlier)"
  cp "$work/readme" .patterns/README.md && git_ add .patterns/README.md
  expect "check: back to clean" quiet g check
}

# pa's next releases: v1.2.0 (a minor), v2.0.0 (a major that renames, deletes, and has Upgrading
# steps, and text a shell would expand)
pa_next() {
  printf v1.2.0 > "$work/src/pa/version" && release pa v1.2.0
  cat > "$work/src/pa/CHANGELOG.md" <<'EOF'
# Changelog

## Unreleased
- not yet released

## v2.0.0 - 2026-11-04
### Upgrading
- docs/policy.md is now docs/rules.md: update your links
- odd text: $(touch pwned) `touch pwned` "quoted" \n

## 1.2.0
- the version file says v1.2.0

## v1.1.0
- v1.1.0
EOF
  git_ -C "$work/src/pa" mv docs/policy.md docs/rules.md && git_ -C "$work/src/pa" rm -rq docs/old
  printf v2.0.0 > "$work/src/pa/version" && release pa v2.0.0
}

# The 0.y series (semver's 0.x, as Cargo reads it): each 0.y is its own series, so v0.2.0 is a breaking version
# for a pin at v0.1.x. zy: a provider tagged v0.1.0, v0.1.1 and v0.2.0, pinned at v0.1.0 in $work/zy
zy_consumer() {
  [ -d "$work/zy" ] && return 0
  prov zy && printf 'v0.1.0' > "$work/src/zy/version" && release zy v0.1.0
  printf 'v0.1.1' > "$work/src/zy/version" && release zy v0.1.1
  printf 'v0.2.0' > "$work/src/zy/version" && release zy v0.2.0
  consumer "$work/zy" && (cd "$work/zy" && by_hand zy v0.1.0 && commit init && quiet nix flake lock && commit lock)
}
sec_zy_outdated() {
  zy_consumer && cd "$work/zy"
  ran "outdated: a 0.y series" g outdated
  expect "zy: v0.1.1 the newest of its series, v0.2.0 the breaking version" grep -qE "^zy +\.patterns +v0\.1\.0 +v0\.1\.1 +outdated +v0\.2\.0$" <<<"$out"
  ran "outdated --json: a 0.y series" g outdated --json
  expect "major is the breaking series' newest" quiet jq -e '.[] | select(.name=="zy") | .latest=="v0.1.1" and .major=="v0.2.0"' <<<"$out"
  cd "$work/cmd"
}
sec_zy_upgrade() {
  zy_consumer && cd "$work/zy"
  ran "upgrade: a 0.y series" g upgrade
  expect "moves within it" has "tuteur: zy v0.1.0 -> v0.1.1"
  expect "and holds the next 0.y" has "tuteur: zy: v0.2.0 is a breaking version (new major, or new 0.y); not taken (tuteur upgrade zy@v0.2.0)"
  expect "the gitlink at v0.1.1" test "$(git_ ls-files -s .patterns/zy | cut -d' ' -f2)" = "$(sha zy v0.1.1)"
  commit "zy v0.1.1"
  ran "upgrade: again" g upgrade
  expect "nothing to move, v0.2.0 still held" has "tuteur: zy: v0.2.0 is a breaking version (new major, or new 0.y); not taken (tuteur upgrade zy@v0.2.0)"
  expect "says nothing to upgrade" has "tuteur: nothing to upgrade"
  ran "upgrade NAME@TAG: crosses the 0.y series by name" g upgrade zy@v0.2.0
  expect "moved" has "tuteur: zy v0.1.1 -> v0.2.0"
  expect "the gitlink at v0.2.0" test "$(git_ ls-files -s .patterns/zy | cut -d' ' -f2)" = "$(sha zy v0.2.0)"
  git_ reset -q --hard && git_ submodule update -q -- .patterns/zy
  cd "$work/cmd"
}

sec_outdated() {
  cd "$work/cmd"
  pa_next
  ran "outdated: lists tuteur and every pattern" g outdated
  expect "pa: newest within its series, and the breaking version" grep -qE "^pa +\.patterns +v1.1.0 +v1.2.0 +outdated +v2.0.0$" <<<"$out"
  expect "docs: current" grep -qE "^docs +\.patterns +v1.0.0 +v1.0.0 +current +-$" <<<"$out"
  expect "tuteur by path: untagged" grep -qE "^tuteur +- +path +- +untagged" <<<"$out"
  expect "says what BREAKING means" grep -q "^BREAKING: a breaking version (a new major, or a new 0.y below 1.0)" <<<"$out"
  ran "outdated --json" g outdated --json
  expect "fields" quiet jq -e '.[] | select(.name=="pa") | .pinned=="v1.1.0" and .latest=="v1.2.0" and .status=="outdated" and .major=="v2.0.0" and .dir==".patterns"' <<<"$out"
  ran "outdated -C, from tuteur's flake" G outdated -C "$work/cmd"
  expect "the same" grep -qE "^pa +\.patterns +v1.1.0 +v1.2.0 +outdated" <<<"$out"
  git_ -C .patterns/docs commit -q --allow-empty -m wip && git_ add .patterns/docs
  ran "outdated: a pattern at no release" g outdated
  expect "untagged, with its commit, and the newest release of its nearest release's major" grep -qE "^docs +\.patterns +$(git_ -C .patterns/docs rev-parse --short=12 HEAD) +v1.0.0 +untagged" <<<"$out"
  git_ -C .patterns/docs checkout -q --detach HEAD~1 && git_ add .patterns/docs
  command mv "$work/docs.git" "$work/docs.away"
  ran "outdated: an upstream it can't list" G outdated -C .
  expect "unknown" grep -qE "^docs +\.patterns +v1.0.0 +- +unknown" <<<"$out"
  command mv "$work/docs.away" "$work/docs.git"
  sec_zy_outdated
}

# The contracts' schemas are JSON Schema 2020-12, and their golden fixtures (what readers test against) validate.
# What tuteur really prints is validated where it prints it: status.
sec_contracts() {
  local st=contracts/status-1.schema.json
  expect "contracts: status/1's schema is a 2020-12 schema" quiet jsv --check-metaschema "$src/$st"
  expect "contracts: status/1's fixtures validate" valid "$st" "$src"/contracts/fixtures/status-1/*.json
  out=$(jq '.scions[0].latest.status = "unknown"' "$src/contracts/fixtures/status-1/clean.json")
  refuse "contracts: status/1 refuses an unknown latest with no reason" quiet valid "$st"
  out=$(jq '.scions[0].owner = "ada"' "$src/contracts/fixtures/status-1/clean.json")
  refuse "contracts: status/1 refuses a field it does not define (a new field is a new version)" quiet valid "$st"
  out=$(jq 'del(.graft)' "$src/contracts/fixtures/status-1/clean.json")
  refuse "contracts: status/1 refuses a report without tuteur (a value is null, never left out)" quiet valid "$st"
}

# tuteur status (status/1): every --json report validates against contracts/status-1.schema.json. Runs after
# outdated (pa at v1.1.0, with v1.2.0 and v2.0.0 upstream), and leaves $work/cmd as it found it.
sj() { stdout_of g status --json; }
# shellcheck disable=SC2016 # jq's own $variables
sec_status() {
  cd "$work/cmd"
  local pa11 rc st=contracts/status-1.schema.json
  pa11=$(sha pa v1.1.0)
  ran "status --json: a report" sj
  expect "validates against status/1's schema" valid "$st"
  expect "version 1, the top, the patterns folder" quiet jq -e --arg r "$(pwd -P)" '.version == 1 and .repo == $r and .scions_dir == ".patterns" and .problems == []' <<<"$out"
  expect "one entry per pattern, by name" test "$(jq -c '[.scions[].name]' <<<"$out")" = '["docs","nest","pa"]'
  expect "pa: its pin, its tag upstream, clean at its gitlink, no problems" quiet jq -e --arg c "$pa11" --arg u "$(url pa)" \
    '.scions[] | select(.name == "pa") | .path == ".patterns/pa" and .url == $u and .registered and .commit == $c and .tag == "v1.1.0"
       and .tag_from == "upstream" and .filled and .head == $c and .clean == true and .problems == []' <<<"$out"
  expect "pa: outdated, as tuteur outdated says, with the later major" quiet jq -e \
    '.scions[] | select(.name == "pa") | .latest == {status: "outdated", tag: "v1.2.0", major: "v2.0.0", reason: null}' <<<"$out"
  expect "docs: current" quiet jq -e '.scions[] | select(.name == "docs") | .latest == {status: "current", tag: "v1.0.0", major: null, reason: null}' <<<"$out"
  expect "tuteur by path: untagged, no commit" quiet jq -e '.graft == {url: null, commit: null, tag: null, latest: {status: "untagged", tag: null, major: null, reason: null}}' <<<"$out"
  ran "status: a table" g status
  expect "a header" grep -qE "^NAME +PATH +TAG +COMMIT +CHECKOUT +LATEST" <<<"$out"
  expect "pa's row" grep -qE "^pa +.patterns/pa +v1.1.0 +${pa11:0:7} +clean +v1.2.0 \(outdated; v2.0.0 is a breaking version\)$" <<<"$out"
  expect "tuteur's row" grep -qE "^tuteur +- +- +- +- +untagged$" <<<"$out"
  ran "status -C, from tuteur's flake" stdout_of G status -C "$work/cmd" --json
  expect "the same report" quiet jq -e '[.scions[].name] == ["docs","nest","pa"]' <<<"$out"
  # a dirty pattern, away from its gitlink: reported, exit 0 (tuteur check is the gate)
  printf edited > .patterns/pa/version
  ran "status: an uncommitted edit, still exit 0" sj
  expect "validates" valid "$st"
  expect "clean false, and check's message" quiet jq -e '.scions[] | select(.name == "pa") | .clean == false
    and (.problems | index("uncommitted edits in .patterns/pa: version (Nix builds ignore them while the rest of the tree is clean)"))' <<<"$out"
  git_ -C .patterns/pa checkout -q -- version
  git_ -C .patterns/pa checkout -q --detach v1.0.1
  ran "status: a pattern checked out away from its gitlink" sj
  expect "head is the checkout, commit the gitlink, check's message" quiet jq -e --arg c "$pa11" --arg h "$(sha pa v1.0.1)" \
    '.scions[] | select(.name == "pa") | .commit == $c and .head == $h and .clean == true
       and (.problems | any(startswith(".patterns/pa is checked out at ")))' <<<"$out"
  git_ -C .patterns/pa checkout -q --detach "$pa11"
  # a gitlink at no release
  git_ -C .patterns/docs commit -q --allow-empty -m wip && git_ add .patterns/docs
  ran "status: a gitlink at no release" sj
  expect "validates" valid "$st"
  expect "no tag (read upstream), untagged, check's message" quiet jq -e \
    '.scions[] | select(.name == "docs") | .tag == null and .tag_from == "upstream" and .latest.status == "untagged" and .latest.tag == "v1.0.0"
       and (.problems | any(contains("is not a release tag of")))' <<<"$out"
  git_ -C .patterns/docs checkout -q --detach HEAD~1 && git_ add .patterns/docs
  # an upstream it can't list: null and a reason, never left out; the tag from the pattern's own clone
  command mv "$work/pa.git" "$work/pa.away"
  ran "status: an upstream it can't list (from tuteur's flake: the repo's own would fetch pa)" stdout_of G status --json -C .
  command mv "$work/pa.away" "$work/pa.git"
  expect "validates" valid "$st"
  expect "latest unknown, with git's reason" quiet jq -e --arg u "$(url pa)" \
    '.scions[] | select(.name == "pa") | .latest.status == "unknown" and .latest.tag == null and .latest.major == null
       and (.latest.reason | startswith("can'"'"'t list tags at \($u): "))' <<<"$out"
  expect "the tag from the pattern's clone" quiet jq -e '.scions[] | select(.name == "pa") | .tag == "v1.1.0" and .tag_from == "local" and .problems == []' <<<"$out"
  # a folder .gitmodules doesn't register, and tuteur try left on
  mkdir -p .patterns/stray && echo x > .patterns/stray/a.md
  quiet g try
  ran "status: a stray folder, try on" sj
  quiet g try --stop
  rm -rf .patterns/stray
  expect "validates" valid "$st"
  expect "the folder: not registered, check's message, unknown with a reason" quiet jq -e \
    '.scions[] | select(.name == "stray") | .registered == false and .url == null and .commit == null and .filled == false
       and .problems == [".patterns/stray is not a submodule: tuteur add URL, or remove it"] and .latest.status == "unknown" and (.latest.reason | length > 0)' <<<"$out"
  expect "try: a repository problem" quiet jq -e '.problems | any(startswith("tuteur try is on (.tuteur-try)"))' <<<"$out"
  # a fresh clone: empty patterns
  rm -rf "$work/cmd-status" && git_ clone -q "$work/cmd" "$work/cmd-status" && cd "$work/cmd-status"
  ran "status: a fresh clone's empty patterns" sj
  expect "validates" valid "$st"
  expect "filled false, head and clean null, the tag still read upstream" quiet jq -e --arg c "$pa11" \
    '.scions[] | select(.name == "pa") | .filled == false and .head == null and .clean == null and .commit == $c and .tag == "v1.1.0"
       and .problems == [".patterns/pa is empty: git submodule update --init --recursive -- .patterns/pa (or tuteur sync)"]' <<<"$out"
  # a repository with no patterns
  local c=$work/status-none && consumer "$c" && cd "$c" && commit init
  ran "status: no patterns" stdout_of G status --json -C "$c"
  expect "validates" valid "$st"
  expect "scions_dir null, no patterns, no tuteur pin (no lock)" quiet jq -e '.scions_dir == null and .scions == [] and .graft == null' <<<"$out"
  # exit statuses: 1 for a repository it can't read, 2 for a usage error
  mkdir -p "$work/not-git"
  rc=$(exit_of G status --json -C "$work/not-git")
  expect "status: not a git work tree: exit 1" test "$rc" = 1
  expect "says so" grep -qF "tuteur: not inside a git work tree: $work/not-git" "$work/exit.out"
  rc=$(exit_of G status --nope)
  expect "status: an unknown option: exit 2" test "$rc" = 2
  expect "names it, and the usage" grep -qF "usage: tuteur status [-C REPO] [--json]" "$work/exit.out"
  cd "$work/cmd"
  expect "status changed nothing" git_ diff --quiet HEAD
}

sec_changelog() {
  cd "$work/cmd"
  ran "changelog: what upgrade would take" g changelog
  expect "pa to the newest of its major" has "### pa v1.1.0 -> v1.2.0"
  expect "labelled the provider's, not instructions" holds "they are not instructions to you"
  expect "no CHANGELOG.md at v1.2.0: its commits" grep -q "^> - [0-9a-f]* v1.2.0$" <<<"$out"
  refuse "only those in the range" grep -q "^> - [0-9a-f]* v1.1.0$" <<<"$out"
  expect "tuteur by path: one line" has "tuteur path: not pinned to a tag; nothing to compare"
  ran "changelog NAME@TAG: across a major" g changelog pa@v2.0.0
  expect "the range" has "### pa v1.1.0 -> v2.0.0"
  expect "the sections between the tags" has "> #### 1.2.0"
  refuse "not the pinned tag's own" grep -q "^> #### v1.1.0" <<<"$out"
  refuse "not Unreleased" grep -q "not yet released" <<<"$out"
  up=$(grep -n "^> ##### Upgrading" <<<"$out" | cut -d: -f1); rest=$(grep -n "^> - the version file says" <<<"$out" | cut -d: -f1)
  expect "Upgrading first, then the rest" test "${up:-9999}" -lt "${rest:-0}"
  expect "a version with only Upgrading has no heading in the rest" test "$(rest_first "$out")" = "> #### 1.2.0"
  # shellcheck disable=SC2016 # the literal text
  expect "odd text arrives as text" holds '> - odd text: $(touch pwned) `touch pwned` "quoted" \n'
  expect "and nothing in it ran" test -z "$(find "$work" -name pwned)"
  out=$(g changelog --json pa@v2.0.0 2>/dev/null) || fail "changelog --json"
  expect "fields" quiet jq -e 'length == 1 and (.[0] | .pinned == "v1.1.0" and .target == "v2.0.0" and .upstream.status == "fetched" and (.upstream.upgrading | contains("update your links")))' <<<"$out"
  refused "changelog: an unknown name" g changelog nonesuch
  refused "changelog: a tag that isn't upstream" g changelog pa@v1.9.0
  expect "changelog changed nothing" git_ diff --quiet
}

sec_upgrade() {
  cd "$work/cmd"
  printf edited > .patterns/pa/version
  refused "upgrade: refuses a pattern with uncommitted edits" g upgrade
  expect "says so" holds "tuteur: pa: uncommitted edits in .patterns/pa (version); nothing changed"
  git_ -C .patterns/pa checkout -q -- version
  # a pattern on a fix branch, away from its gitlink: it moves, and the branch stays
  git_ -C .patterns/pa switch -q -c fix v1.0.1
  cp .gitmodules "$work/gm-before"
  ran "upgrade: within the pinned major" g upgrade
  expect "says what moved" has "tuteur: pa v1.1.0 -> v1.2.0"
  expect "and the major not taken" has "tuteur: pa: v2.0.0 is a breaking version (new major, or new 0.y); not taken (tuteur upgrade pa@v2.0.0)"
  expect "the pattern checked out at the tag" test "$(git_ -C .patterns/pa rev-parse HEAD)" = "$(sha pa v1.2.0)"
  expect "and its gitlink staged" test "$(git_ diff --cached --name-only)" = ".patterns/pa"
  expect ".gitmodules untouched" cmp -s .gitmodules "$work/gm-before"
  expect "the fix branch kept" quiet git_ -C .patterns/pa rev-parse -q --verify refs/heads/fix
  ran "upgrade: again, nothing to do" g upgrade
  expect "says so" holds "tuteur: nothing to upgrade"
  commit "pa v1.2.0"
  ran "upgrade: the tools build the new version" tools_out pa
  expect "v1.2.0" has "pa v1.2.0"
  # from an untagged gitlink (a fix, recorded before its release): NAME@TAG, or NAME (its major's newest)
  git_ -C .patterns/pa commit -q --allow-empty -m "a fix" && git_ add .patterns/pa
  fix=$(git_ -C .patterns/pa rev-parse HEAD)
  ran "upgrade NAME: from an untagged gitlink, the newest of its nearest release's major" G upgrade -C . pa
  expect "moved" has "tuteur: pa ${fix:0:12} -> v1.2.0"
  git_ -C .patterns/pa checkout -q --detach "$fix" && git_ add .patterns/pa
  ran "upgrade NAME@TAG: from an untagged gitlink" G upgrade -C . pa@v1.1.0
  expect "moved" has "tuteur: pa ${fix:0:12} -> v1.1.0"
  git_ reset -q && git_ submodule update -q -- .patterns/pa
  ran "upgrade NAME@TAG: across a major, by name" g upgrade pa@v2.0.0
  expect "moved" has "tuteur: pa v1.2.0 -> v2.0.0"
  git_ reset -q --hard && git_ submodule update -q -- .patterns/pa
  refused "upgrade: an unknown name" g upgrade nonesuch
  refused "upgrade: a tag that isn't upstream" g upgrade pa@v1.9.0
  expect "says so" holds "tuteur: pa: no tag v1.9.0 upstream; nothing changed"
  command mv "$work/pa.git" "$work/pa.away"
  refused "upgrade: an upstream it can't read" G upgrade -C .
  expect "says so, changing nothing" holds "tuteur: pa: can't tell whether"
  command mv "$work/pa.away" "$work/pa.git"
  expect "and changed nothing" git_ diff --quiet HEAD
  # a clone with no pattern filled (CI): the gitlink is written into the index
  git_ clone -q "$work/cmd" "$work/cmd-ci" && cd "$work/cmd-ci"
  ran "upgrade: a pattern not filled" G upgrade -C "$work/cmd-ci" docs@v1.0.0 pa@v1.1.0
  expect "moved" has "tuteur: pa v1.2.0 -> v1.1.0"
  refuse "quietly (no fetch progress)" grep -qE "remote:|Receiving objects|Cloning into" <<<"$out"
  expect "its gitlink written" test "$(git_ ls-files -s .patterns/pa | cut -d' ' -f2)" = "$(sha pa v1.1.0)"
  expect "and the folder still empty" test ! -e .patterns/pa/version
  commit "pa back to v1.1.0"
  ran "upgrade: Nix builds the committed gitlink" tools_out pa
  expect "v1.1.0" has "pa v1.1.0"
  git_ submodule update -q --init -- .patterns/pa
  expect "and a later git submodule update lands on the tag" test "$(git_ -C .patterns/pa describe --tags)" = v1.1.0
  cd "$work/cmd"
  sec_zy_upgrade
}

# tuteur's own pin: a tuteur repository with this tree at v9.0.0, and at v9.1.0 a patterns README and a
# tuteur-check.yaml with one more line each; v9.0.1 is a tuteur without refresh.sh (v2.12's shape)
tuteur_repo() {
  gr=$work/tuteur-repo
  mkdir -p "$gr" && cp -R "$tuteur/." "$gr/" && rm -rf "$gr/.patterns"
  git_ -C "$gr" init -q && git_ -C "$gr" add -A && git_ -C "$gr" commit -qm v9.0.0 && git_ -C "$gr" tag v9.0.0
  echo "Written by tuteur v9.1.0." >> "$gr/lib/patterns-readme.md"
  echo "# changed in v9.1.0" >> "$gr/template/.forgejo/workflows/tuteur-check.yaml"
  git_ -C "$gr" commit -qam v9.1.0 && git_ -C "$gr" tag v9.1.0
  git_ -C "$gr" tag v10.0.0
  git_ -C "$gr" checkout -q -b old v9.0.0 && git_ -C "$gr" rm -q lib/refresh.sh && git_ -C "$gr" commit -qm v9.0.1 \
    && git_ -C "$gr" tag v9.0.1 && git_ -C "$gr" checkout -q main
}

sec_tuteur() {
  tuteur_repo
  c=$work/self && consumer "$c" "$(printf '  inputs.self.submodules = true;\n  inputs.tuteur.url = "git+file://%s?ref=v9.0.0";\n  outputs = inputs: inputs.tuteur.lib.mkFlake { inherit inputs; };' "$gr")"
  cd "$c" && commit init
  ran "tuteur: add with a tuteur pinned by tag" g add "$(url docs)"
  mkdir -p .forgejo/workflows && cp "$gr"/template/.forgejo/workflows/*.yaml .forgejo/workflows/
  tail -n +2 "$gr/template/.forgejo/workflows/tuteur-upgrade.yaml" > .forgejo/workflows/tuteur-upgrade.yaml   # the repo's own (no marker)
  cp .forgejo/workflows/tuteur-upgrade.yaml "$work/mine.yaml"
  commit "docs, workflows"
  ran "tuteur: outdated lists tuteur's pin" g outdated
  expect "v9.0.0, v9.1.0 newest, v10 a major" grep -qE "^tuteur +- +v9.0.0 +v9.1.0 +outdated +v10.0.0$" <<<"$out"
  refused "tuteur: upgrade won't move tuteur to a version without refresh.sh" g upgrade tuteur@v9.0.1
  expect "says so" holds "tuteur: tuteur v9.0.1 has no lib/refresh.sh, so tuteur upgrade can't hand it this repository; move it by hand"
  expect "and changes nothing" git_ diff --quiet
  ran "tuteur: under CI (not tuteur ci), tuteur itself isn't moved" env CI=true nix run .#tuteur upgrade
  expect "tuteur's pin as it was" grep -q "ref=v9.0.0" flake.nix
  # the fetch-cache guard: tuteur's new tag is fetched and locked through an empty fetch cache of tuteur's own, never
  # the person's (where a git+file: or . fetch of that commit may have left the tree without export-ignore)
  local xdg=$work/xdg-tuteur r91 && r91=$(git_ -C "$gr" rev-parse v9.1.0) && mkdir -p "$xdg"
  ran "tuteur: upgrade moves tuteur" env XDG_CACHE_HOME="$xdg" nix run .#tuteur -- upgrade
  refuse "tuteur: upgrade fetched and locked the new tag through an empty fetch cache, not the person's" grep -rqF "$r91" "$xdg"
  expect "says so" has "tuteur: tuteur v9.0.0 -> v9.1.0"
  expect "the ref in flake.nix" grep -q "ref=v9.1.0" flake.nix
  # shellcheck disable=SC2016 # jq's $r
  expect "re-locked" quiet jq -e --arg r "$(git_ -C "$gr" rev-parse v9.1.0)" '.nodes.tuteur.locked.rev == $r' flake.lock
  expect "the new version wrote its README" grep -qx "Written by tuteur v9.1.0." .patterns/README.md
  expect "and its workflow" cmp -s .forgejo/workflows/tuteur-check.yaml "$gr/template/.forgejo/workflows/tuteur-check.yaml"
  expect "a workflow without the marker untouched" cmp -s .forgejo/workflows/tuteur-upgrade.yaml "$work/mine.yaml"
  commit "tuteur v9.1.0"
  ran "tuteur: check passes under the new pin (its narHash is its tag's git archive's)" g check
  expect "one pattern, singular" has "tuteur: 1 pattern clean and at release tags"
  # a pin whose narHash is not its tag's git archive: what a polluted fetch cache locks, and CI then fails on with
  # NAR hash mismatch (tuteur's own flake: it reads the lock as data; the repo's own would fail evaluating it)
  local ei full && cp flake.lock "$work/lock-good"
  full=$(jq -r '.nodes.tuteur.locked.narHash' flake.lock)
  ei=$(XDG_CACHE_HOME=$(mktemp -d -p "$work") nix --option flake-registry '' flake prefetch --json "git+file://$gr?ref=v9.1.0&exportIgnore=1" 2>/dev/null | jq -r .hash)
  expect "(tuteur's repository export-ignores files: the two trees differ)" test -n "$ei" -a "$ei" != "$full"
  jq --arg h "$ei" '.nodes.tuteur.locked.narHash = $h' "$work/lock-good" > flake.lock
  refused "tuteur: check, a pin whose narHash is not its tag's git archive" G check -C .
  expect "names the pin and both hashes" holds "tuteur: flake.lock pins tuteur at v9.1.0 (${r91:0:7}) with narHash $ei, but its tag's git archive hashes to $full: "
  expect "the fetch cache as the likely cause" holds "Nix's fetch cache probably gave the lock a tree that another fetch of that commit left there"
  # shellcheck disable=SC2016 # the literal text
  expect "and the fix" holds 're-lock tuteur through an empty fetch cache: XDG_CACHE_HOME=$(mktemp -d) nix flake update tuteur'
  # an exportIgnore input is its tag's archive with the provider's export-ignore rules (as a github: input's is)
  jq --arg h "$ei" '.nodes.tuteur.locked.narHash = $h | .nodes.tuteur.locked.exportIgnore = true' "$work/lock-good" > flake.lock
  out=$(G check -C . 2>&1) || true
  refuse "tuteur: check, an exportIgnore pin at its tag's export: no narHash message" holds "narHash"
  jq '.nodes.tuteur.locked.exportIgnore = true' "$work/lock-good" > flake.lock
  refused "tuteur: check, an exportIgnore pin holding the whole tree" G check -C .
  expect "names it" holds "tuteur: flake.lock pins tuteur at v9.1.0 (${r91:0:7}) with narHash $full, but its tag's git archive hashes to $ei: "
  # an upstream it can't fetch: a note, not a failure of its own
  command mv "$gr" "$gr.away"
  out=$(G check -C . 2>&1) || true
  command mv "$gr.away" "$gr"
  expect "tuteur: check, a pin it can't fetch: says so" holds "tuteur: can't fetch tuteur's v9.1.0 from file://$gr"
  refuse "and fails nothing on it" holds "with narHash"
  cp "$work/lock-good" flake.lock
  # v2.12's upgrade, moving its tuteur to this version, runs this version's lib/assemble.sh: a stub
  refused "tuteur: lib/assemble.sh (what a v2.12 upgrade runs) stops it" bash "$tuteur/lib/assemble.sh" out patterns x=y=z
  expect "naming the Upgrading steps" holds "graft v2.13.0 replaced copied scions with git submodules"
  # tuteur's own pin in a 0.y series, as every pin of tuteur is from 0.1.0: v0.1.1 taken, v0.2.0 held, and
  # NAME@TAG crosses. A consumer's inputs.pot at a version tag moves by the same rule, through flake.nix and
  # flake.lock alone: only tuteur's own input runs the new version's lib/refresh.sh
  local zr=$work/tuteur-0y pr=$work/pot-0y zc=$work/self-0y
  mkdir -p "$zr" && cp -R "$tuteur/." "$zr/" && rm -rf "$zr/.patterns"
  git_ -C "$zr" init -q && git_ -C "$zr" add -A && git_ -C "$zr" commit -qm v0.1.0 && git_ -C "$zr" tag v0.1.0
  echo "Written by tuteur v0.1.1." >> "$zr/lib/patterns-readme.md" && git_ -C "$zr" commit -qam v0.1.1 && git_ -C "$zr" tag v0.1.1
  echo "Written by tuteur v0.2.0." >> "$zr/lib/patterns-readme.md" && git_ -C "$zr" commit -qam v0.2.0 && git_ -C "$zr" tag v0.2.0
  mkdir -p "$pr/lib" && git_ -C "$pr" init -q && printf '{ outputs = _: { }; }\n' > "$pr/flake.nix"
  # shellcheck disable=SC2016 # the script's own $PWD
  printf '#!/usr/bin/env bash\ntouch "$PWD/pot-refresh-ran"\n' > "$pr/lib/refresh.sh"
  local t
  for t in v0.1.0 v0.1.1 v0.2.0; do git_ -C "$pr" add -A && git_ -C "$pr" commit -q --allow-empty -m "$t" && git_ -C "$pr" tag "$t"; done
  consumer "$zc" "$(printf '  inputs.self.submodules = true;\n  inputs.tuteur.url = "git+file://%s?ref=v0.1.0";\n  inputs.pot.url = "git+file://%s?ref=v0.1.0";\n  outputs = inputs: inputs.tuteur.lib.mkFlake { inherit inputs; };' "$zr" "$pr")"
  cd "$zc" && commit init
  ran "tuteur: add, with the own pin and pot in 0.y series" g add "$(url docs)"
  commit docs
  ran "tuteur: outdated, the own pin and pot in 0.y series" g outdated
  expect "tuteur: v0.1.1 the newest of its series, v0.2.0 breaking" grep -qE "^tuteur +- +v0\.1\.0 +v0\.1\.1 +outdated +v0\.2\.0$" <<<"$out"
  expect "pot: a row of its own, by the same rule" grep -qE "^pot +- +v0\.1\.0 +v0\.1\.1 +outdated +v0\.2\.0$" <<<"$out"
  ran "tuteur: upgrade, the own pin and pot in 0.y series" env XDG_CACHE_HOME="$work/xdg-0y" nix run .#tuteur -- upgrade
  expect "the own pin moves within its series" has "tuteur: tuteur v0.1.0 -> v0.1.1"
  expect "and pot" has "tuteur: pot v0.1.0 -> v0.1.1"
  expect "the own pin's next 0.y is held" has "tuteur: tuteur: v0.2.0 is a breaking version (new major, or new 0.y); not taken (tuteur upgrade tuteur@v0.2.0)"
  expect "and pot's" has "tuteur: pot: v0.2.0 is a breaking version (new major, or new 0.y); not taken (tuteur upgrade pot@v0.2.0)"
  expect "flake.nix: both refs moved" test "$(grep -c 'ref=v0.1.1";' flake.nix)" = 2
  # shellcheck disable=SC2016 # jq's $r
  expect "flake.lock: pot re-locked" quiet jq -e --arg r "$(git_ -C "$pr" rev-parse v0.1.1)" '.nodes.pot.locked.rev == $r' flake.lock
  expect "the own pin's new version wrote its README" grep -qx "Written by tuteur v0.1.1." .patterns/README.md
  expect "pot's lib/refresh.sh never ran" test ! -e pot-refresh-ran
  commit "0.1.1"
  ran "tuteur: upgrade, nothing more within the series" env XDG_CACHE_HOME="$work/xdg-0y" nix run .#tuteur -- upgrade
  expect "says so" has "tuteur: nothing to upgrade"
  ran "tuteur: upgrade tuteur@v0.2.0 pot@v0.2.0: crosses by name" env XDG_CACHE_HOME="$work/xdg-0y" nix run .#tuteur -- upgrade tuteur@v0.2.0 pot@v0.2.0
  expect "the own pin" has "tuteur: tuteur v0.1.1 -> v0.2.0"
  expect "and pot" has "tuteur: pot v0.1.1 -> v0.2.0"
  expect "and its README" grep -qx "Written by tuteur v0.2.0." .patterns/README.md
  git_ reset -q --hard
  # an input named pot that is not at a version tag gets no row
  sed -i "s|inputs.pot.url = \"git+file://$pr?ref=v0.1.1\";|inputs.pot.url = \"git+file://$pr\";|" flake.nix && quiet nix flake lock && commit "pot by branch"
  ran "tuteur: outdated, pot at a branch" g outdated
  refuse "no row for pot" grep -qE "^pot " <<<"$out"
  cd "$work"
}

# lib/workflows.sh on its own: the lines tuteur keeps (paths-ignore, branches, # tuteur ssh:)
sec_workflows() {
  local tw=$tuteur/template/.forgejo/workflows wr=$work/wf-repo wx=$work/wf-examples wf
  mkdir -p "$wr/.forgejo/workflows" "$wx"
  wf=$wr/.forgejo/workflows/tuteur-check.yaml
  cp "$tw/tuteur-check.yaml" "$wf"
  pi_on() { grep -A7 '^on:' "$1"; }
  pi_want=$(printf '%s\n' 'on:' '  pull_request:' '    paths-ignore: ["notebook/**", "drafts/**"]' '  push:' \
    '    branches: [main]' '    paths-ignore: ["notebook/**", "drafts/**"]' '' 'concurrency:')
  sed -i "s|^    branches: \[main\]$|&\n    paths-ignore: [ 'notebook/**',\"drafts/**\" ]|" "$wf"
  refused "workflows: paths-ignore under push alone fails the check" bash "$tuteur/lib/workflows.sh" check "$wr" "$tw"
  quiet bash "$tuteur/lib/workflows.sh" refresh "$wr" "$tw" || fail "workflows.sh refresh, paths-ignore"
  expect "workflows: refresh writes it under both triggers, in tuteur's form" test "$(pi_on "$wf")" = "$pi_want"
  expect "workflows: the rest is tuteur's copy" cmp -s <(grep -v '^    paths-ignore: ' "$wf") "$tw/tuteur-check.yaml"
  expect "workflows: then the check passes" quiet bash "$tuteur/lib/workflows.sh" check "$wr" "$tw"
  expect "workflows: YAML that means it" \
    test "$(nix run "$np#yq-go" -- -o=json -I=0 '[.on.push["paths-ignore"], .on.pull_request["paths-ignore"], .on.push.branches]' "$wf")" \
    = '[["notebook/**","drafts/**"],["notebook/**","drafts/**"],["main"]]'
  cp "$wf" "$work/wf-good"
  pi_glob() { sed "s|\"drafts/\*\*\"|\"$1\"|g" "$work/wf-good" > "$wf"; }
  for glob in '.patterns/**' '?patterns/x.md' '?patterns' 'flake.lock' 'flake.*' '?forgejo/**' '.gitmodules' '.gitm*'; do
    pi_glob "$glob"
    refused "workflows: paths-ignore \"$glob\" fails" bash "$tuteur/lib/workflows.sh" check "$wr" "$tw" "nix run .#tuteur" . .patterns
    expect "and says what it could match" holds "paths-ignore glob \"$glob\" could match"
  done
  pi_glob 'patternsx/**'
  expect "workflows: paths-ignore \"patternsx/**\" is fine" quiet bash "$tuteur/lib/workflows.sh" check "$wr" "$tw" "nix run .#tuteur" . .patterns
  pi_glob 'nix/tools/.patterns/**'
  refused "workflows: a subdirectory flake's patterns folder is protected" bash "$tuteur/lib/workflows.sh" check "$wr" "$tw" "nix run .#tuteur" nix/tools nix/tools/.patterns
  cp "$work/wf-good" "$wf"
  sed -i 's|^\(    paths-ignore: .*\)$|\1  # the bot|' "$wf"
  refused "workflows: a comment on the line fails" bash "$tuteur/lib/workflows.sh" check "$wr" "$tw"
  expect "and says so" holds "no comment after it"
  # branches: the repo's own
  cp "$tw/tuteur-check.yaml" "$wf" && sed -i 's|^    branches: \[main\]$|    branches: ["v2", release/1.x]|' "$wf"
  quiet bash "$tuteur/lib/workflows.sh" refresh "$wr" "$tw" || fail "workflows.sh refresh, branches"
  expect "workflows: branches kept, in tuteur's form" grep -qx '    branches: \[v2, release/1.x\]' "$wf"
  expect "workflows: and the check passes" quiet bash "$tuteur/lib/workflows.sh" check "$wr" "$tw"
  # # tuteur ssh: a step before each step that runs tuteur, in both workflows (a made-up host key)
  hk='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITuteurTestHostKeyNotARealOne+/0123456789abcdefgh'
  sshl="# tuteur ssh: host=[git.example]:2222 address=192.0.2.7 hostkey=$hk"
  cp "$tw/tuteur-check.yaml" "$wf" && echo "$sshl" >> "$wf"
  cp "$tw/tuteur-upgrade.yaml" "$wr/.forgejo/workflows/" && echo "$sshl" >> "$wr/.forgejo/workflows/tuteur-upgrade.yaml"
  refused "workflows: ssh: a line whose step isn't written fails the check" bash "$tuteur/lib/workflows.sh" check "$wr" "$tw"
  quiet bash "$tuteur/lib/workflows.sh" refresh "$wr" "$tw" || fail "workflows.sh refresh, ssh"
  expect "workflows: ssh: the line kept above name:" test "$(grep -B1 '^name: tuteur-check$' "$wf" | head -1)" = "$sshl"
  expect "workflows: ssh: then the check passes" quiet bash "$tuteur/lib/workflows.sh" check "$wr" "$tw"
  steps=$(nix run "$np#yq-go" -- -o=json -I=0 '[.jobs.patterns.steps[] | .name]' "$wf")
  expect "workflows: ssh: tuteur-check: the key before the check" test "$steps" = '["Checkout","SSH key for private patterns","Patterns registered and at release tags"]'
  steps=$(nix run "$np#yq-go" -- -o=json -I=0 '[.jobs[].steps[] | .name]' "$wr/.forgejo/workflows/tuteur-upgrade.yaml")
  expect "workflows: ssh: tuteur-upgrade: the key before the upgrade and the PR" \
    test "$steps" = '["Checkout the default branch","SSH key for private patterns","Upgrade, check the result, push it to tuteur/upgrade","Checkout the default branch","SSH key for private patterns","Open (or update) the PR"]'
  srun=$(nix run "$np#yq-go" -- '.jobs.patterns.steps[1].run' "$wf")
  expect "workflows: ssh: known_hosts under the host and its address" grep -qxF "echo '[git.example]:2222,[192.0.2.7]:2222 $hk' >> ~/.ssh/known_hosts" <<<"$srun"
  sk=$work/ssh-home && mkdir -p "$sk"
  expect "workflows: ssh: the step writes the key and config" env HOME="$sk" TUTEUR_SSH_KEY="not a real key" GITHUB_PATH="$sk/path" bash -c "$srun"
  expect "workflows: ssh: (the key)" test "$(cat "$sk/.ssh/tuteur_patterns")" = "not a real key"
  refused "workflows: ssh: an empty secret fails the step" env HOME="$sk" TUTEUR_SSH_KEY= GITHUB_PATH="$sk/path" bash -c "$srun"
  for bad in "host=git.example" "host=git'x hostkey=$hk" "host=git.example hostkey=$hk extra"; do
    cp "$tw/tuteur-check.yaml" "$wf" && echo "# tuteur ssh: $bad" >> "$wf"
    refused "workflows: ssh: \"$bad\" fails" bash "$tuteur/lib/workflows.sh" refresh "$wr" "$tw"
    expect "and says how to write it" holds '# tuteur ssh: host=[HOST]:PORT'
  done
  # the workflows' own search for the flake (bash and git only, as in the nixos/nix image)
  fb=$work/flake-block.sh
  # shellcheck disable=SC2016 # a line of the script, expanded when it runs
  { awk '/# tuteur.s flake: beside the patterns folder/ { buf = ""; on = 1 } on && /nix run "\$flake#tuteur"/ { on = 0; last = buf; next }
         on { sub(/^ +/, ""); buf = buf $0 "\n" } END { printf "%s", last }' "$tw/tuteur-upgrade.yaml"
    echo 'echo "$flake"'; } > "$fb"
  fr=$work/flake-find && mkdir -p "$fr" && git_ -C "$fr" init -q
  fbin=$work/flake-bin && mkdir -p "$fbin" && ln -sf "$(command -v git)" "$fbin/git"
  fbrun() { (cd "$fr" && git_ add -A && env PATH="$fbin" "$(command -v bash)" -e "$fb" 2>&1); }
  expect "workflows: flake step: no patterns yet: the top" test "$(fbrun)" = .
  mkdir -p "$fr/.patterns" && cp "$tuteur/lib/patterns-readme.md" "$fr/.patterns/README.md"
  expect "workflows: flake step: patterns at the top" test "$(fbrun)" = .
  git_ -C "$fr" rm -rqf .patterns && mkdir -p "$fr/nix/tools/.patterns" && cp "$tuteur/lib/patterns-readme.md" "$fr/nix/tools/.patterns/README.md"
  expect "workflows: flake step: a subdirectory flake, as path:" test "$(fbrun)" = "path:$fr/nix/tools"
  mkdir -p "$fr/other" && cp "$tuteur/lib/patterns-readme.md" "$fr/other/README.md"
  refused "workflows: flake step: two patterns folders fail" fbrun
  expect "and say so" holds "::error::two patterns folders:"
}

# tuteur ci pr against a stub API. stub_pr NAME [LISTING [STATUSES]]: run `tuteur ci pr` in the current
# repo against a fresh stub (GET answers LISTING; STATUSES, JSON, the HTTP status to answer each
# method with), with output in $work/NAME.out, its exit code in $work/NAME.rc, the request log in
# $work/NAME.auth and the requests in $work/NAME.req
stub_pr() {
  local port=$work/$1.port rc=0 stub
  rm -f "$port"
  nix run "$np#python3" -- "$src/tests/stub-api.py" "$port" "$work/$1.auth" "$work/$1.req" "${2:-/nonexistent}" ${3:+"$3"} & stub=$!
  for _ in $(seq 100); do [ -s "$port" ] && break; sleep 0.1; done
  ci_ API="http://127.0.0.1:$(cat "$port")" WEB=x BASE=main BRANCH=tuteur/upgrade PR_TOKEN=s3cret \
    pr > "$work/$1.out" 2>&1 || rc=$?
  echo "$rc" > "$work/$1.rc"
  kill "$stub" 2>/dev/null || true
}
post_body() { jq -r 'select(.method=="POST") | .body.body' "$work/$1.req"; }

# gate NAME WANT: a consumer of pa at v1.1.0 whose own check wants pa's version to be WANT, pushed to
# its origin (NAME.git) and cloned fresh (no pattern filled, as in CI) to $work/NAME-ci
gate() {
  local d=$work/$1
  consumer "$d" "$(cat <<EOF
  inputs.self.submodules = true;
  inputs.tuteur.url = "path:$tuteur";
  outputs = inputs: inputs.tuteur.lib.mkFlake {
    inherit inputs;
    perSystem = { pkgs, patterns, ... }: {
      checks.pa-version = pkgs.runCommand "pa-version" { } ''
        grep -qx "\$(cat \${inputs.self}/want)" \${patterns.pa}/version \\
          || { echo "pa-version: expected \$(cat \${inputs.self}/want), got \$(cat \${patterns.pa}/version)" >&2; exit 1; }
        touch \$out
      '';
    };
  };
EOF
)"
  cd "$d"
  printf '%s\n' "$2" > want
  mkdir -p .forgejo/workflows && cp "$tuteur"/template/.forgejo/workflows/*.yaml .forgejo/workflows/
  commit init && quiet g add "$(url pa)@v1.1.0" && commit "pa" && quiet nix flake lock && commit lock
  git_ init -q --bare "$work/$1.git" && git_ remote add origin "$work/$1.git" && git_ push -q origin main
  git_ clone -q "$work/$1.git" "$work/$1-ci" && cd "$work/$1-ci"
}

sec_ci() {
  gate gate-ok v1.2.0
  ran "ci check: passes on a fresh clone (no pattern filled)" ci_ check
  expect "says so" has "tuteur: ci check passed: flake.lock is committed, every pattern is at a release tag, tuteur's workflows are current, and the flake evaluates"
  refused "ci upgrade: refuses without BRANCH" ci_ upgrade
  expect "says so" has "tuteur: BRANCH is not set: name the branch to push the upgrade to (tuteur's workflow sets BRANCH=tuteur/upgrade)"
  refused "ci upgrade: refuses to commit on the default branch" ci_ BRANCH=tuteur/upgrade upgrade
  expect "says so" has "tuteur: ci upgrade commits on the branch checked out, main, and pushes it to tuteur/upgrade: switch to a new branch tuteur/upgrade first (git switch -c tuteur/upgrade)"
  git_ checkout -q -b tuteur/upgrade
  echo "SECRET=x" > .env.local
  refused "ci upgrade: refuses an untracked file" ci_ BRANCH=tuteur/upgrade upgrade
  expect "says why" has "tuteur: ci upgrade commits every change in the working tree, and this one has the changes of its own above: commit, stash or remove them first"
  rm -f .env.local
  # C1: the check after the upgrade sees the NEW pattern (committed first, then checked)
  ran "ci upgrade: moves pa and checks the result" ci_ GITHUB_OUTPUT="$work/ci-out" BRANCH=tuteur/upgrade upgrade
  expect "changed=true" grep -qx changed=true "$work/ci-out"
  expect "the check saw the new version (its own check wants v1.2.0)" has "tuteur: checks.$sys.pa-version"
  refuse "and nothing failed" holds "::error::"
  body=$(git_ -C "$work/gate-ok.git" log -1 --format=%b tuteur/upgrade)
  expect "pushed, its commit naming the move" grep -qx "tuteur: pa v1.1.0 -> v1.2.0" <<<"$body"
  expect "the gitlink pushed" test "$(git_ -C "$work/gate-ok.git" ls-tree tuteur/upgrade .patterns/pa | awk '{ print $3 }')" = "$(sha pa v1.2.0)"
  : > "$work/ci-out"
  ran "ci upgrade: again, nothing to do" ci_ GITHUB_OUTPUT="$work/ci-out" BRANCH=tuteur/upgrade upgrade
  expect "changed=false" grep -qx changed=false "$work/ci-out"
  git_ checkout -q main
  stub_pr pr1
  expect "ci pr: opens the PR for a branch that only moves a gitlink" grep -q "http://stub/pulls/1" "$work/pr1.out"
  expect "with the token in a header" grep -qx "POST token s3cret" "$work/pr1.auth"
  out=$(post_body pr1)
  expect "the body lists the move" has "- pa v1.1.0 -> v1.2.0"
  expect "and the major not taken" holds "- pa: v2.0.0 is a breaking version (new major, or new 0.y)"
  expect "and that the check passed" holds "whole \`nix flake check\` passed"
  expect "and what changed upstream" has "### pa v1.1.0 -> v1.2.0"
  expect "its commits (no CHANGELOG at v1.2.0)" grep -q "^> - [0-9a-f]* v1.2.0$" <<<"$out"
  # what ci pr refuses: a .gitmodules change, a workflow change; the README only when tuteur moved
  push_branch() { git_ push -q --force origin HEAD:refs/heads/tuteur/upgrade && git_ checkout -q main; }
  git_ fetch -q origin
  git_ checkout -q -b x1 origin/tuteur/upgrade && git_ config -f .gitmodules submodule..patterns/pa.url "file://$work/elsewhere.git" && commit swap && push_branch
  stub_pr pr2
  expect "ci pr: a .gitmodules change: refused" grep -qx 1 "$work/pr2.rc"
  expect "says so" grep -q "changes files tuteur upgrade never writes: .gitmodules" "$work/pr2.out"
  git_ checkout -q -b x2 origin/main && echo "# x" >> .forgejo/workflows/tuteur-check.yaml && commit wf && push_branch
  stub_pr pr3
  expect "ci pr: a workflow change: refused" grep -q "changes CI workflows" "$work/pr3.out"
  git_ checkout -q -b x3 origin/main && echo "x" >> .patterns/README.md && commit readme && push_branch
  stub_pr pr4
  expect "ci pr: the README without tuteur moving: refused" grep -q "changes files tuteur upgrade never writes: .patterns/README.md" "$work/pr4.out"
  # shellcheck disable=SC2016 # a jq program
  git_ checkout -q -b x4 origin/main && echo "x" >> .patterns/README.md \
    && jq '.nodes.tuteur.locked.narHash = "sha256-moved"' flake.lock > "$work/lock" && cp "$work/lock" flake.lock && commit "tuteur moved" && push_branch
  stub_pr pr5
  expect "ci pr: the README when tuteur's pin moved: opened" grep -q "http://stub/pulls/1" "$work/pr5.out"

  # a check the upgrade breaks: the branch is still pushed, the step fails, the PR says why
  gate gate-bad v1.1.0
  git_ checkout -q -b tuteur/upgrade
  refused "ci upgrade: fails when the repo's own check fails" ci_ GITHUB_OUTPUT="$work/bad-out" BRANCH=tuteur/upgrade upgrade
  expect "but says it changed" grep -qx changed=true "$work/bad-out"
  body=$(git_ -C "$work/gate-bad.git" log -1 --format=%b tuteur/upgrade)
  expect "its commit names the failing check" grep -qx "nix flake check failed: pa-version" <<<"$body"
  expect "with its log's tail (the new version, seen)" grep -q "pa-version: expected v1.1.0, got v1.2.0" <<<"$body"
  expect "and still the move" grep -qx "tuteur: pa v1.1.0 -> v1.2.0" <<<"$body"
  git_ checkout -q main
  stub_pr bad1
  expect "the PR titled as failing" quiet jq -e 'select(.method=="POST") | .body.title == "[checks failing] tuteur: upgrade"' "$work/bad1.req"
  stub_pr http1 /nonexistent '{"GET": 500}'
  expect "ci pr: listing PRs fails: the step fails" grep -qxF "::error::listing PRs: HTTP 500" "$work/http1.out"

  # a lock never committed
  cd "$work/gate-ok-ci" && git_ rm -q --cached flake.lock && git_ commit -qm "no lock"
  git_ clone -q "$work/gate-ok-ci" "$work/nolock" && cd "$work/nolock"
  refused "ci check: a flake.lock never committed" nix run .#tuteur -- ci check
  expect "says so" holds "tuteur: flake.lock is not committed, so nothing is pinned"

  # ci signers (v2.21.0, R0.5): report-only, against .forgejo/allowed_signers as BEFORE had it
  git_ clone -q "$work/gate-ok.git" "$work/signers" && cd "$work/signers"
  local k
  for k in person routine agent; do ssh-keygen -q -t ed25519 -N '' -C "$k" -f "$work/sk-$k"; done
  { echo "daniel@person $(cut -d' ' -f1,2 "$work/sk-person.pub")"; echo "daniel@routine $(cut -d' ' -f1,2 "$work/sk-routine.pub")"
    echo "agent@h $(cut -d' ' -f1,2 "$work/sk-agent.pub")"; } > .forgejo/allowed_signers
  sg() { local key=$1; shift; git_ -c gpg.format=ssh -c user.signingkey="$work/sk-$key" -c commit.gpgsign=true -c tag.gpgsign=true "$@"; }
  git_ add .forgejo/allowed_signers && sg person commit -qm "signers"
  local before && before=$(git_ rev-parse HEAD)
  sg agent commit -q --allow-empty -m "agent, no trailer"
  sg agent commit -q --allow-empty -m $'agent\n\nPot-Run: ab12'
  git_ -c commit.gpgsign=false commit -q --allow-empty -m "nobody"
  echo x > AGENTS.md && git_ add AGENTS.md && sg routine commit -qm "instructions, routine"
  echo y > AGENTS.md && git_ add AGENTS.md && sg person commit -qm "instructions, person"
  ran "ci signers: a push to main (report-only: exit 0)" ci_ REF=refs/heads/main BEFORE="$before" AFTER=HEAD signers
  expect "counts the push" has "tuteur: signers: 5 commit(s) on refs/heads/main, 3 finding(s) (report-only)"
  expect "an agent's commit needs a trailer" holds "(agent, no trailer): signed by agent@h with no Pot-Run: trailer"
  expect "an unsigned commit" holds "(nobody): unsigned"
  expect "instructions need a person" holds "(instructions, routine): changes AGENTS.md, which needs a @person signature (it has daniel@routine)"
  refuse "a person's change to them passes" holds "(instructions, person)"
  refuse "the agent's commit with a trailer passes" holds "(agent):"
  # a push can't vouch for itself: a key the push adds is unknown to it
  ssh-keygen -q -t ed25519 -N '' -C new -f "$work/sk-new"
  before=$(git_ rev-parse HEAD)
  echo "agent@new $(cut -d' ' -f1,2 "$work/sk-new.pub")" >> .forgejo/allowed_signers
  git_ add .forgejo/allowed_signers && sg new commit -qm $'add my key\n\nPot-Run: cd34'
  ran "ci signers: a push that adds its own key" ci_ REF=refs/heads/main BEFORE="$before" AFTER=HEAD signers
  expect "is checked against the old file" holds "(add my key): signed by a key not in .forgejo/allowed_signers"
  expect "and the file needs a person" holds "changes .forgejo/allowed_signers, which needs a @person signature"
  sg routine tag -s -m v1 v1 && sg agent tag -s -m v2 v2 && git_ -c tag.gpgsign=false tag v3
  ran "ci signers: a routine tag" ci_ REF=refs/tags/v1 AFTER=refs/tags/v1 signers
  expect "passes (for now)" has "tuteur: signers: tag v1, 0 finding(s) (the signers file is the pushed one's: no SIGNERS_REF) (report-only)"
  ran "ci signers: an agent's tag" ci_ REF=refs/tags/v2 AFTER=refs/tags/v2 signers
  expect "is reported" holds "tag v2 is signed by agent@h: a tag needs a @person or @routine key"
  ran "ci signers: a lightweight tag" ci_ REF=refs/tags/v3 AFTER=refs/tags/v3 signers
  expect "is reported" holds "tag v3 is lightweight"
  # a tag on a commit that adds its own key: checked against the default branch's file (SIGNERS_REF)
  sg new tag -s -m v4 v4
  ran "ci signers: a tag signed by the key its commit adds" ci_ REF=refs/tags/v4 AFTER=refs/tags/v4 SIGNERS_REF="$before" signers
  expect "does not vouch for itself" holds "tag v4: no signature that verifies against .forgejo/allowed_signers"
  expect "and says which file" holds "(the signers file is $before's)"
  ran "ci signers: a force-push's old commit, gone" ci_ REF=refs/heads/main BEFORE=1111111111111111111111111111111111111111 AFTER=HEAD SIGNERS_REF="$before" signers
  expect "is reported" holds "the push's old commit 111111111111 is not in this checkout (a force-push?)"
  git_ rm -q .forgejo/allowed_signers && git_ -c commit.gpgsign=false commit -qm "no signers" && before=$(git_ rev-parse HEAD)
  git_ -c commit.gpgsign=false commit -q --allow-empty -m "after"
  ran "ci signers: no signers file" ci_ REF=refs/heads/main BEFORE="$before" AFTER=HEAD signers
  expect "is reported, not an error" holds "::warning::tuteur signers: no .forgejo/allowed_signers at"
}

sec_migrate() {
  cd "$work/cmd"
  printf '%s\n' "the policy: .patterns/pa/docs/policy.md" "old: .patterns/pa/docs/old/x.md and [dir](.patterns/pa/docs/old/)" > notes.md
  commit "notes"
  ran "migrate: nothing moved on the base" g migrate --base main --no-check
  expect "says so" holds "tuteur migrate: nothing moved since"
  git_ checkout -q -b mig
  quiet g upgrade pa@v2.0.0 && commit "pa v2.0.0"
  ran "migrate: a brief for an upgraded branch" g migrate --base main --no-check
  expect "what moved" has "Migrate this repo (cmd) to pa v2.0.0 (from v1.2.0)."
  expect "what upstream says, Upgrading first" has "Upgrading, from its CHANGELOG.md:"
  expect "renames" has "    R  .patterns/pa/docs/policy.md -> .patterns/pa/docs/rules.md"
  expect "deletions" has "    D  .patterns/pa/docs/old/x.md"
  expect "references to a renamed path" has "    notes.md:1  .patterns/pa/docs/policy.md  (renamed to .patterns/pa/docs/rules.md)"
  expect "to a deleted one" has "    notes.md:2  .patterns/pa/docs/old/x.md  (deleted)"
  expect "to a directory gone" has "    notes.md:2  .patterns/pa/docs/old/  (directory gone)"
  expect "checks not run" holds "Not run (--no-check)"
  out=$(g migrate --base main --no-check --json 2>/dev/null) || fail "migrate --json"
  expect "fields" quiet jq -e '.moved[0].name == "pa" and .moved[0].kind == "pattern" and .moved[0].from == "v1.2.0" and .moved[0].to == "v2.0.0" and (.references | length) == 3 and .pattern_dirs == [".patterns"]' <<<"$out"
  ran "migrate -C from tuteur's flake" G migrate -C "$work/cmd" --base main --no-check
  expect "the same brief" has "Migrate this repo (cmd) to pa v2.0.0 (from v1.2.0)."
  ran "migrate: with the checks" g migrate --base main
  expect "they pass" holds "passes as the branch stands"
  git_ checkout -q main && git_ submodule update -q -- .patterns/pa
}

sec_try() {
  # tp: a tool that prints the pattern's version, and its `extra` file when it has one
  prov tp
  cat > "$work/src/tp/tuteur.nix" <<'EOF'
{ pkgs, ... }:
{ tools.tp = pkgs.writeShellScriptBin "tp" "echo tp ${builtins.readFile ./version}${if builtins.pathExists ./extra then " " + builtins.readFile ./extra else ""}"; }
EOF
  printf 'v1.0.0' > "$work/src/tp/version"
  release tp v1.0.0
  # tn: files only, with a submodule of its own
  prov tn
  git_ -C "$work/src/tn" submodule add -q "$(url docs)" sub/docs 2>/dev/null
  release tn v1.0.0
  local c=$work/try && consumer "$c" && cd "$c"
  by_hand tp && by_hand tn && git_ -C .patterns/tn submodule update -q --init --recursive
  commit init && quiet nix flake lock && commit lock
  local v1 && v1=$(sha tp v1.0.0 | cut -c1-7)
  git_ -C .patterns/tp switch -q -c fix
  printf 'edited' > .patterns/tp/version && printf 'extra' > .patterns/tp/extra
  ran "try: off, a build ignores a pattern's edit and new file" tools_out tp
  expect "builds the gitlink" has "tp v1.0.0"
  refused "try: an unknown pattern" G try -C . nope
  expect "says so" has "tuteur: no pattern named nope"
  expect "and changes nothing" test ! -e .tuteur-try
  refused "try: from inside a pattern" G try -C .patterns/tp
  expect "says to run it from the top" has "tuteur: $(pwd -P)/.patterns/tp is a submodule of $(pwd -P): run tuteur from the repository's top (-C $(pwd -P))"
  ran "try: on (from tuteur's flake: the repo's flake need not evaluate)" G try -C .
  expect "says so" has "tuteur: try is on: Nix builds of this repository read its working tree, and its patterns' (.tuteur-try marks it)"
  expect "what Nix builds of each pattern" has "tuteur: .patterns/tp: branch fix at v1.0.0 ($v1), as recorded: 1 modified, 1 new Nix doesn't see"
  expect "how to make Nix see the new file: stage it for real" has "tuteur: .patterns/tp: Nix sees a new file only once git tracks it: git -C .patterns/tp add -- extra"
  expect "the build command for a flake at the top" has "tuteur: build from the repository's top: nix build .#tools, nix shell .#tools -c TOOL, or nix flake check"
  refuse "never path: at the top" holds "path:"
  expect "the marker, marked with intent to add" test "$(git_ status --porcelain --untracked-files=no -- .tuteur-try)" = " A .tuteur-try"
  expect "the pattern's index untouched" test "$(git_ -C .patterns/tp status --porcelain)" = "$(printf ' M version\n?? extra')"
  expect "the pattern's HEAD unmoved" test "$(git_ -C .patterns/tp rev-parse HEAD)" = "$(sha tp v1.0.0)"
  ran "try: on, a build sees the edit, not the untracked file" tools_out tp
  expect "the edit" has "tp edited"
  git_ -C .patterns/tp add -- extra
  ran "try: the new file once staged" tools_out tp
  expect "both" has "tp edited extra"
  ran "try: again (idempotent)" G try -C .
  expect "counts it as new" has "tuteur: .patterns/tp: branch fix at v1.0.0 ($v1), as recorded: 1 modified, 1 new"
  # discarding in the pattern loses nothing tuteur did: tuteur never touched its index
  git_ -C .patterns/tp reset -q -- extra && printf 'precious' > .patterns/tp/extra2
  git_ -C .patterns/tp checkout -q -- .
  expect "try: git checkout -- . in a pattern keeps the new files" test "$(cat .patterns/tp/extra)$(cat .patterns/tp/extra2)" = "extraprecious"
  git_ -C .patterns/tp reset -q --hard
  expect "and so does reset --hard" test "$(cat .patterns/tp/extra)$(cat .patterns/tp/extra2)" = "extraprecious"
  rm .patterns/tp/extra2 && printf 'edited' > .patterns/tp/version
  # a pattern's own submodule: its new files are reported too
  echo new > .patterns/tn/sub/docs/new.md
  ran "try: a new file in a pattern's own submodule" G try -C .
  expect "counted" has "tuteur: .patterns/tn: detached at v1.0.0 ($(sha tn v1.0.0 | cut -c1-7)), as recorded: 1 new Nix doesn't see"
  expect "with its command" has "tuteur: .patterns/tn/sub/docs: Nix sees a new file only once git tracks it: git -C .patterns/tn/sub/docs add -- new.md"
  ran "try NAME: the commands for the named patterns only" G try -C . tp
  refuse "not another's" holds "git -C .patterns/tn/sub/docs add"
  rm .patterns/tn/sub/docs/new.md
  refused "try: tuteur check refuses while it is on" g check
  expect "names tuteur try --stop" has "tuteur: tuteur try is on (.tuteur-try): Nix builds read the working tree, patterns included: tuteur try --stop turns it off"
  expect "and the pattern's edits are used" has "tuteur: uncommitted edits in .patterns/tp: version (tuteur try is on: Nix builds use them)"
  refused "try: check --committed refuses too" G check -C . --committed
  expect "the same" has "tuteur: tuteur try is on (.tuteur-try): Nix builds read the working tree, patterns included: tuteur try --stop turns it off"
  refused "try: ci check refuses too" ci_ check
  expect "the same" holds "tuteur try --stop turns it off"
  refused "try: upgrade refuses" G upgrade -C . tp
  expect "says why" has "tuteur: tuteur try is on; nothing changed: tuteur try --stop first"
  ran "try: sync runs, and says try is on" g sync
  expect "a note" has "tuteur: note: tuteur try is on: tuteur try --stop turns it off before you commit"
  git_ add .patterns/README.md && git_ commit -qm "sync's README" -- .patterns/README.md
  # a parent reset leaves the marker untracked: Nix no longer reads the working tree
  git_ reset -q
  refused "try: check after a parent reset" G check -C .
  expect "doesn't claim try is on" has "tuteur: .tuteur-try is left from tuteur try but untracked, so Nix builds read the recorded patterns: tuteur try --stop removes it, or tuteur try turns try on again"
  ran "try: again after the reset" G try -C .
  expect "is on again" test "$(git_ status --porcelain --untracked-files=no -- .tuteur-try)" = " A .tuteur-try"
  ran "try --stop" G try -C . --stop
  expect "says so" has "tuteur: try is off: Nix builds the recorded patterns while the tree is clean"
  expect "the marker gone" test ! -e .tuteur-try
  expect "and out of the index" test -z "$(git_ ls-files -- .tuteur-try)"
  expect "the pattern untouched" test "$(git_ -C .patterns/tp status --porcelain)" = "$(printf ' M version\n?? extra')"
  expect "says the pattern stays as it is" has "tuteur: .patterns/tp stays as you left it: git submodule update --recursive -- .patterns/tp goes back to its pin (commit or stash its edits first)"
  ran "try: off again, a build ignores them" tools_out tp
  expect "the gitlink's" has "tp v1.0.0"
  ran "try --stop again (idempotent)" G try -C . --stop
  expect "nothing to undo" has "tuteur: try is not on; nothing to undo"
  # the marker committed (git add -A, then commit)
  quiet G try -C .
  git_ -C .patterns/tp add -A && git_ -C .patterns/tp commit -qm "the fix" && git_ add -A && git_ commit -qm "the marker by mistake"
  refused "try: check --committed fails on a committed marker" G check -C . --committed
  expect "says so" has "tuteur: .tuteur-try is committed (tuteur try's marker): tuteur try --stop, then commit its removal"
  refused "try: refuses while the marker is committed (Nix would read the gitlinks)" G try -C .
  expect "says how to remove it" has "tuteur: .tuteur-try is committed, so the tree is clean to Nix; nothing changed: tuteur try --stop, commit its removal, then tuteur try"
  ran "try --stop after commits" G try -C . --stop
  expect "the pattern's commit left as it is" quiet git_ -C .patterns/tp cat-file -e HEAD:extra
  expect "the marker's removal staged" test "$(git_ status --porcelain -- .tuteur-try)" = "D  .tuteur-try"
  expect "says to commit it" has "tuteur: .tuteur-try was committed: its removal is staged; commit it"
  # try again before that commit: refuse with advice that ends the loop, and change nothing (QA R1)
  refused "try: refuses while the marker's removal is staged but not committed" G try -C .
  expect "says to commit the removal" has "tuteur: .tuteur-try is committed and its removal is staged; nothing changed: commit the removal (git commit -m 'Remove tuteur try marker'), then tuteur try"
  expect "the index unchanged" test "$(git_ status --porcelain -- .tuteur-try)" = "D  .tuteur-try"
  git_ commit -qm "no marker"
  git_ -C .patterns/tp checkout -q --detach v1.0.0 && git_ add .patterns/tp && commit "back to v1.0.0"
  # works while the repo's flake can't evaluate
  echo '{' >> flake.nix
  ran "try: on while flake.nix doesn't parse" G try -C .
  expect "reports" has "tuteur: .patterns/tp: detached at v1.0.0 ($v1), as recorded: no edits"
  quiet G try -C . --stop && git_ checkout -q -- flake.nix
  # an empty pattern: Nix fails on it while try is on
  git_ submodule deinit -q -f .patterns/tp
  refused "try: refuses an empty pattern" G try -C .
  expect "says how to fill it" has "tuteur: .patterns/tp is empty, and Nix fails on an empty pattern while try is on; nothing changed: git submodule update --init --recursive -- .patterns/tp (or tuteur sync)"
  expect "nothing changed" test ! -e .tuteur-try
  git_ submodule update -q --init -- .patterns/tp
  # a path: flake in a subdirectory reads its working tree always: nothing to turn on
  local s=$work/try-sub && mkdir -p "$s/nix/tools" && git_ -C "$s" init -q
  printf '{\n  inputs.tuteur.url = "path:%s";\n  outputs = inputs: inputs.tuteur.lib.mkFlake { inherit inputs; dir = ".patterns"; };\n}\n' "$tuteur" > "$s/nix/tools/flake.nix"
  quiet G add -C "$s" --dir nix/tools/.patterns "$(url tp)" && git_ -C "$s" add -A && git_ -C "$s" commit -qm sub
  printf 'edited' > "$s/nix/tools/.patterns/tp/version" && printf 'extra' > "$s/nix/tools/.patterns/tp/extra"
  ran "try: a path: flake" G try -C "$s"
  expect "says there is nothing to turn on" has "tuteur: nix/tools is a path: flake: every build reads its working tree, patterns and new files included; try has nothing to turn on"
  expect "what it builds" has "tuteur: nix/tools/.patterns/tp: detached at v1.0.0 ($v1), as recorded: 1 modified, 1 new"
  expect "its build command" has "tuteur: build from the repository's top: nix build 'path:nix/tools#tools', nix shell 'path:nix/tools#tools' -c TOOL, or nix flake check 'path:nix/tools'"
  expect "no marker" test ! -e "$s/.tuteur-try"
  refused "try: check in a path: flake" G check -C "$s"
  expect "says builds use the edits" has "tuteur: uncommitted edits in nix/tools/.patterns/tp: version (a path: flake's builds use them)"
  ran "try --stop: a path: flake" G try -C "$s" --stop
  expect "nothing to undo" has "tuteur: try is not on; nothing to undo"
}

sec_tarball() {
  # tuteur as github: fetches it: a tarball, no submodules. Its command must not need its patterns.
  local t=$work/tuteur-src
  mkdir -p "$t" && cp -R "$tuteur/." "$t/" && rm -rf "$t/.git" && find "$t/.patterns" -mindepth 2 -maxdepth 2 -exec rm -rf {} +
  tar -C "$work" -czf "$work/tuteur.tar.gz" tuteur-src
  ran "tarball: tuteur's command runs from a tarball of tuteur (no submodules)" nix run "tarball+file://$work/tuteur.tar.gz" -- help
  expect "its usage" holds "usage:"
  # a consumer taking tuteur as a tarball input (as github: fetches it): lock, evaluate, its own app
  local c=$work/tarball-consumer
  consumer "$c" "$(printf '  inputs.self.submodules = true;\n  inputs.tuteur.url = "tarball+file://%s";\n  outputs = inputs: inputs.tuteur.lib.mkFlake { inherit inputs; };' "$work/tuteur.tar.gz")"
  cd "$c" && by_hand kb && commit init
  ran "tarball: a consumer locks tuteur as a tarball input" nix flake lock
  commit lock
  ran "tarball: and builds its tools" tools_out kb-lint
  ran "tarball: and runs its own tuteur" g check
  expect "which passes" has "tuteur: 1 pattern clean and at release tags"
}

# kits: mkFlake's side of the seam with pot (option A): a consumer that takes pot as an input of its own
# (inputs.pot) gets packages.<system>.pot-kits from pot.lib.pot.kitsFor (contract pot-lib/1), wrapped tools and
# kits.just; one without it gets none of them, and a warning when a unit declares a kit. pot here is the test input
# dev/flake.nix pins (pot_src). pot's own half (a kit's messages, the bundle's checks) is tested in pot.
pot_src() { nix flake archive --json "$src/dev" | jq -er '.inputs.pot.path'; }
sec_kits() {
  local pot
  pot=$(pot_src) || fail "kits: dev/flake.nix has no pot input"
  # kk: a pattern kit (protect, requests, a command, a recipe) that reads kitArgs; kkold: v2.14.0's `sandbox`
  prov kk
  cat > "$work/src/kk/tuteur.nix" <<'EOF'
{ pkgs, kitArgs ? { }, ... }:
let tool = pkgs.writeShellScriptBin "kk-tool" "echo kk-tool ${kitArgs.word or "none"}"; in
{
  tools.kk-tool = tool;
  kit = {
    version = "1.2";
    protect = [ "kk.yaml" ];
    requests.network = [ "api.kk.example" ];
    commands.kk-tool.program = "${tool}/bin/kk-tool";
    recipes.kk = { run = "kk-tool"; description = "Run kk"; };
  };
}
EOF
  release kk v1.0.0
  prov kkold
  printf '{ ... }: { sandbox.packages = [ ]; }\n' > "$work/src/kkold/tuteur.nix" && release kkold v1.0.0
  prov kkapp
  printf '{ ... }: { apps.pot = { type = "app"; program = "/bin/sh"; }; }\n' > "$work/src/kkapp/tuteur.nix" && release kkapp v1.0.0

  local c=$work/kc && consumer "$c" "$(printf '  inputs.self.submodules = true;\n  inputs.tuteur.url = "path:%s";\n  inputs.pot.url = "path:%s";\n  outputs = inputs: inputs.tuteur.lib.mkFlake { inherit inputs; perSystem = { pkgs, ... }: { kitArgs.kk.word = "hi"; kit = { protect = [ "AGENTS.md" ]; tools = [ pkgs.hello ]; }; }; };' "$tuteur" "$pot")" && cd "$c"
  echo "# agents" > AGENTS.md && echo "a: 1" > kk.yaml && printf 'import? ".patterns/kits.just"\n' > justfile
  by_hand kk && commit init && quiet nix flake lock && commit lock

  ran "kits: pot-kits builds, through the consumer's inputs.pot" nix build -o "$work/kpk" ".#pot-kits"
  ran "its kit.json" jq -c . "$work/kpk/kit.json"
  expect "is pot-kits/1: version, self, scions (pot's field), protect" test "$(jq -c 'keys' "$work/kpk/kit.json")" = '["protect","scions","self","version"]'
  expect "holds the repo kit, with its file" holds '"self":{"file":"flake.nix (perSystem)","protect":["AGENTS.md"],"tools":["/nix/store/'
  expect "and the pattern kit, handed through unread" holds '"kk":{"commands":{"kk-tool":{"program":"/nix/store/'
  expect "naming its provider file" holds '"file":".patterns/kk/tuteur.nix"'
  expect "pot protects every provider file, by either name, and the patterns folder" holds '"protect":["**/tuteur.nix","**/graft.nix",".patterns"]'
  expect "its tools hold the repository's tuteur" test -x "$work/kpk/bin/tuteur"
  expect "and the repo kit's tools" test -x "$work/kpk/bin/hello"
  ran "kits: kitArgs reaches the provider" "$(jq -r '.scions.kk.commands["kk-tool"].program' "$work/kpk/kit.json")"
  expect "its value" has "kk-tool hi"
  ran "kits: the tools" nix build -o "$work/kt" .#tools
  expect "hold the command's wrapper (pot runs kit code under its own policy)" test "$(readlink -f "$work/kt/bin/kk-tool")" = "$(readlink -f "$work/kpk/wrappers/bin/kk-tool")"
  ran "kits: tools.passthru.unwrapped" nix build -o "$work/ktu" .#tools.passthru.unwrapped
  expect "holds the program itself" test "$(readlink -f "$work/ktu/bin/kk-tool")" = "$(jq -r '.scions.kk.commands["kk-tool"].program' "$work/kpk/kit.json")"
  # kits.just: pot-lib/1's passthru.kitsJust, written by sync and add, compared by check, where the justfile imports it
  ran "kits: sync writes kits.just" g sync
  expect "says so" holds "tuteur: wrote .patterns/kits.just"
  ran "kits: pot-kits' kitsJust" stdout_of nix eval --raw ".#packages.$sys.pot-kits.kitsJust"
  expect "the same bytes" test "$(cat .patterns/kits.just)" = "$out"
  expect "the kit's recipe" grep -qF 'exec "{{tools}}/bin/kk-tool"' .patterns/kits.just
  expect "and tuteur's own" grep -qF 'exec "{{tools}}/bin/tuteur" '"'"'outdated'"'"' "$@"' .patterns/kits.just
  commit kitsjust
  ran "kits: check, kits.just current" g check
  echo "# edited" >> .patterns/kits.just
  refused "kits: check, kits.just edited" g check
  expect "names the fix" holds "tuteur: .patterns/kits.just is stale or edited: tuteur sync"
  git_ checkout -q .patterns/kits.just
  printf 'import? ".patterns/kits.just"\n\nkk:\n    echo mine\n' > justfile && commit own-kk
  refused "kits: check, a kit recipe named like the justfile's own" g check
  expect "names both" holds "tuteur: .patterns/kits.just's recipe kk has the name of the justfile's own kk: rename one (a kit's recipe never replaces yours)"
  printf 'import? ".patterns/kits.just"\n' > justfile && commit no-own-kk
  echo keep > "$work/klinktarget" && cp .patterns/kits.just "$work/kkj" && ln -sfn "$work/klinktarget" .patterns/kits.just
  refused "kits: sync, kits.just a link" g sync
  expect "is refused" holds "tuteur: .patterns/kits.just is a symbolic link; tuteur writes only a file there"
  expect "its target untouched" test "$(cat "$work/klinktarget")" = keep
  rm -f .patterns/kits.just && cp "$work/kkj" .patterns/kits.just
  prov kkq && release kkq v1.0.0
  git_ rm -q --cached .patterns/kits.just && rm -f .patterns/kits.just
  ran "kits: add writes kits.just too" g add "$(url kkq)"
  expect "says so" holds "tuteur: wrote .patterns/kits.just"
  commit kkq
  # the errors and reserved names, as a consumer's build shows them
  refused "kits: mkFlake writes no graft-kits" nix eval --raw ".#packages.$sys.graft-kits.drvPath"
  by_hand kkold && commit kkold
  refused "kits: a provider's sandbox" nix build --no-link .#pot-kits
  expect "names kit" holds "tuteur: .patterns/kkold/tuteur.nix gives \`sandbox\`: graft v2.15.0 replaced it with \`kit\`"
  git_ rm -q .patterns/kkold && by_hand kkapp && commit kkapp
  refused "kits: a provider's apps.pot" nix build --no-link .#tools
  expect "is reserved" holds "tuteur: apps pot (from kkapp): that name is tuteur's; the provider must rename it"
  git_ rm -q .patterns/kkapp && commit "no kkapp"
  local n
  for n in pot-kits graft-kits; do
    sed -i "s|perSystem = { pkgs, ... }: {|perSystem = { pkgs, ... }: { packages.$n = pkgs.hello;|" flake.nix && commit "own $n"
    refused "kits: perSystem's packages.$n" nix build --no-link .#tools
    expect "is tuteur's" holds "tuteur: packages $n (from self): that name is tuteur's; rename the repo's own"
    sed -i "s|{ packages.$n = pkgs.hello;|{|" flake.nix && commit "no own $n"
  done
  refuse "kits: mkFlake reads no kit field" bash -c "cat '$tuteur/lib/mk-flake.nix' | grep -qE 'kit\.(packages|requests|commands|protect|files|env|recipes)|selfKit'"

  # no inputs.pot: no pot-kits, the tools unwrapped, no kits.just, and one warning naming the kits
  local c0=$work/kc0 && consumer "$c0" && cd "$c0"
  by_hand kk && commit init && quiet nix flake lock && commit lock
  refused "kits: without inputs.pot, no pot-kits" nix eval --raw ".#packages.$sys.pot-kits.drvPath"
  ran "kits: the tools build" nix build -o "$work/kt0" .#tools
  local warned=$out
  ran "kits: unwrapped: the program itself runs" "$work/kt0/bin/kk-tool"
  expect "with no kitArgs (no perSystem here)" has "kk-tool none"
  out=$warned
  expect "with a warning naming the kit and inputs.pot" holds "tuteur: .patterns/kk/tuteur.nix declares a kit for pot, but this flake has no inputs.pot: no packages.<system>.pot-kits, so no run applies it; add inputs.pot.url"
  local c1=$work/kc1 && consumer "$c1" && cd "$c1" && by_hand docs && commit init && quiet nix flake lock && commit lock
  ran "kits: no kit, no pot: no warning" nix build --no-link .#tools
  refuse "says nothing of pot" holds "inputs.pot"
  cd "$c0"
  printf 'import? ".patterns/kits.just"\n' > justfile && commit justfile
  ran "kits: sync without pot, a justfile importing kits.just" g sync
  expect "says why there is none" holds "tuteur: .patterns/kits.just: this flake has no pot-kits (no inputs.pot); not written"
  expect "writes none" test ! -e .patterns/kits.just
  cp "$work/kkj" .patterns/kits.just && commit "a kits.just"
  refused "kits: check, a kits.just with no pot-kits" g check
  expect "names inputs.pot" holds "tuteur: .patterns/kits.just is here but this flake has no pot-kits (no inputs.pot): add inputs.pot, or remove the file"
  local c3=$work/kc3 && consumer "$c3" "$(printf '  inputs.tuteur.url = "path:%s";\n  outputs = inputs: inputs.tuteur.lib.mkFlake { inherit inputs; outputs.packages.%s.pot-kits = inputs.self; };' "$tuteur" "$sys")"
  (cd "$c3" && commit init && refused "kits: outputs' packages.pot-kits, without pot" nix eval --raw ".#packages.$sys.pot-kits.outPath" \
    && expect "is still reserved" holds "tuteur: mkFlake's outputs has packages.$sys.pot-kits: that name is tuteur's; rename the repo's own")
  local c2=$work/kc2 && consumer "$c2" "$(printf '  inputs.tuteur.url = "path:%s";\n  outputs = inputs: inputs.tuteur.lib.mkFlake { inherit inputs; outputs.packages.%s.sandbox = inputs.self; };' "$tuteur" "$sys")"
  (cd "$c2" && commit init && refused "kits: outputs' packages.sandbox" nix eval --raw ".#packages.$sys.sandbox.outPath" \
    && expect "is reserved" holds "tuteur: mkFlake's outputs has packages.$sys.sandbox: that name is reserved (pot)")

  # check in a pot run asks pot whether a provider is reached (pot why URL --json, contract run-env/1), never pot's files
  local stub=$work/kstub && mkdir -p "$stub"
  cat > "$stub/pot" <<'EOF'
#!/bin/sh
case "$2 $3" in
  "https://reached.example/x --json") echo '{"reached": true}'; exit 0 ;;
  *" --json") echo '{"reached": false}'; exit 1 ;;
esac
exit 2
EOF
  chmod +x "$stub/pot"
  # shellcheck disable=SC2016 # the inner bash expands them
  local reach='TUTEUR_TMP=$(mktemp -d) && . "$1/lib/common.sh" && pot_reaches "$2"'
  expect "kits: check in a run: pot says reached" env PATH="$stub:$PATH" POT=work bash -c "$reach" _ "$tuteur" https://reached.example/x
  refuse "pot says not reached" env PATH="$stub:$PATH" POT=work bash -c "$reach" _ "$tuteur" https://other.example/x
  printf '#!/bin/sh\necho "usage: pot why PATH" >&2\nexit 2\n' > "$stub/pot"
  expect "an older pot (no usable answer): the fetch is tried" env PATH="$stub:$PATH" POT=work bash -c "$reach" _ "$tuteur" https://other.example/x
  refuse "kits: tuteur reads no POT_POLICY" grep -q POT_POLICY "$tuteur/lib/common.sh"
  cd "$work"
}

# aliases: graft's names, which tuteur 0.1.x reads (and 0.2.0 drops): the input name graft (read through 0.x), the
# app graft, scions/ as the folder when mkFlake has no dir, graft's marker README, graft.nix and its arguments scion
# and scions, marked graft-*.yaml workflows and the "# graft ssh:" line (sync renames and rewrites them),
# .graft-try and --scions. tuteur check names each one in use, in one line that never fails it.
sec_aliases() {
  # ol: a provider with graft.nix only, whose function names scion and scions and has no `...`
  prov ol
  cat > "$work/src/ol/graft.nix" <<'EOF'
{ pkgs, lib, system, scion, scions, consumer }:
{ tools.ol = pkgs.writeShellScriptBin "ol" "cat ${scion}/README.md ${scions.docs}/policy.md"; }
EOF
  release ol v1.0.0
  local c=$work/al && consumer "$c" "$(printf '  inputs.self.submodules = true;\n  inputs.graft.url = "path:%s";\n  outputs = inputs: inputs.graft.lib.mkFlake { inherit inputs; };' "$tuteur")"
  cd "$c"
  by_hand docs v1.0.0 scions && by_hand ol v1.0.0 scions
  sed -i 's|<!-- managed by tuteur: https://github.com/danielnaab/tuteur -->|<!-- managed by graft: https://github.com/danielnaab/graft -->|' scions/README.md
  mkdir -p .forgejo/workflows
  local key='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl'
  sed 's/tuteur/graft/g; s/Patterns/Scions/g; s/patterns/scions/g' "$tuteur/template/.forgejo/workflows/tuteur-check.yaml" \
    | awk -v l="# graft ssh: host=[git.example.com]:2222 hostkey=$key" 'NR == 2 { print l } { print }' > .forgejo/workflows/graft-check.yaml
  commit init && quiet nix flake lock && commit lock

  ran "aliases: the tools build: scions/ found by graft's default, graft.nix, its scion and scions" tools_out ol
  expect "the provider read its pattern, by scion" has "# ol"
  expect "and a sibling, by scions" has "policy v1"
  ran "aliases: check, through the app graft" nix run .#graft -- check
  expect "passes" has "tuteur: 2 patterns clean and at release tags"
  expect "names the app" holds "tuteur: the app graft (nix run .#graft) is graft's name; 0.2.0 drops it: run nix run .#tuteur"
  expect "names the marker" holds "tuteur: the marker in scions/README.md is graft's name; 0.2.0 drops it: tuteur sync rewrites it"
  expect "names the workflow" holds "tuteur: .forgejo/workflows/graft-check.yaml is graft's name; 0.2.0 drops it: tuteur sync renames it to .forgejo/workflows/tuteur-check.yaml"
  expect "names the folder" holds "tuteur: the folder scions/, which mkFlake finds without dir, is graft's name; 0.2.0 drops it: keep it with dir = \"scions\"; in mkFlake, or move it to .patterns/ (0.2.0's Upgrading steps)"
  expect "names the provider file" holds "tuteur: scions/ol/graft.nix is graft's name; 0.2.0 drops it: the provider ships tuteur.nix"
  expect "names the arguments" holds "tuteur: each of scion and scions, in scions/ol/graft.nix's arguments, is graft's name; 0.2.0 drops it: name them pattern and patterns"
  refuse "and not the input name graft (read through 0.x)" holds "input"
  ran "aliases: outdated reads tuteur's own input by graft's name" nix run .#tuteur -- outdated
  expect "a row named graft" grep -qE "^graft +- +path +- +untagged" <<<"$out"

  ran "aliases: sync" nix run .#tuteur sync
  expect "rewrites the marker" grep -qxF "<!-- managed by tuteur: https://github.com/danielnaab/tuteur -->" scions/README.md
  expect "renames the workflow" has "tuteur: renamed .forgejo/workflows/graft-check.yaml to .forgejo/workflows/tuteur-check.yaml"
  expect "the old name is gone" test ! -e .forgejo/workflows/graft-check.yaml
  expect "the new marker" grep -q "^# managed by tuteur: " .forgejo/workflows/tuteur-check.yaml
  expect "the ssh line in tuteur's form" grep -qxF "# tuteur ssh: host=[git.example.com]:2222 hostkey=$key" .forgejo/workflows/tuteur-check.yaml
  expect "its secret: TUTEUR_SSH_KEY, else GRAFT_SSH_KEY" grep -qF 'TUTEUR_SSH_KEY: ${{ secrets.TUTEUR_SSH_KEY || secrets.GRAFT_SSH_KEY }}' .forgejo/workflows/tuteur-check.yaml
  commit sync
  ran "aliases: check after sync" nix run .#tuteur -- check
  refuse "no line for the marker" holds "the marker in"
  refuse "or the workflow" holds "graft-check.yaml"
  refuse "or the app (run as tuteur)" holds "the app graft"
  expect "the folder still" holds "tuteur: the folder scions/"
  # an explicit dir keeps scions/: no line for the folder
  sed -i 's|mkFlake { inherit inputs; }|mkFlake { inherit inputs; dir = "scions"; }|' flake.nix && commit "dir = scions"
  ran "aliases: check, dir = \"scions\"" nix run .#tuteur -- check
  refuse "no line for the folder" holds "the folder scions/"

  # .graft-try: check fails on it, and try --stop removes it
  echo x > .graft-try && git_ add -N .graft-try
  refused "aliases: check, graft try's marker" nix run .#tuteur -- check
  expect "names it" holds "tuteur: .graft-try is graft try's marker: tuteur try --stop removes it"
  ran "aliases: try --stop" nix run .#tuteur -- try --stop
  expect "removes it" test ! -e .graft-try
  expect "says so" has "tuteur: removed .graft-try, graft try's marker"
  # add --scions
  prov alq && release alq v1.0.0
  ran "aliases: add --scions" nix run .#tuteur -- add --scions scions "$(url alq)"
  expect "names it" holds "tuteur: --scions is graft's name; 0.2.0 drops it: use --dir"
  expect "and adds" test -f scions/alq/README.md
  cd "$work"
}

# fromgraft: a consumer of graft v2.22.0 moved to tuteur 0.1.0 by the consumer's pull request in
# docs/guides/move-from-graft.md, checked, then rolled back with git revert. graft v2.22.0 is this repository's own
# history (GRAFT_V2_22), as a local repository tagged v2.22.0; tuteur 0.1.0 is this tree, tagged v0.1.0; pot is
# dev/flake.nix's.
GRAFT_V2_22=98552bd17459071d2df4c192984114fce270d9c7
sec_fromgraft() {
  git_ -C "$src" cat-file -e "$GRAFT_V2_22^{commit}" 2>/dev/null || fail "fromgraft: graft v2.22.0 ($GRAFT_V2_22) is not in this clone's history"
  local pot gv tv c=$work/fg before
  pot=$(pot_src) || fail "fromgraft: dev/flake.nix has no pot input"
  gv=$work/graft-v2 && mkdir -p "$gv" && git_ -C "$src" archive "$GRAFT_V2_22" | tar -x -C "$gv"
  git_ -C "$gv" init -q && git_ -C "$gv" add -A && git_ -C "$gv" commit -qm v2.22.0 && git_ -C "$gv" tag v2.22.0
  tv=$work/tuteur-v0 && mkdir -p "$tv" && cp -R "$tuteur/." "$tv/" && rm -rf "$tv/.patterns"
  git_ -C "$tv" init -q && git_ -C "$tv" add -A && git_ -C "$tv" commit -qm v0.1.0 && git_ -C "$tv" tag v0.1.0
  # fk: a provider whose graft.nix gives a tool, and a kit with a command and a recipe
  prov fk
  cat > "$work/src/fk/graft.nix" <<'EOF'
{ pkgs, ... }:
let tool = pkgs.writeShellScriptBin "fk-tool" "echo fk-tool"; in
{ tools.fk-tool = tool; kit = { version = "1.2"; commands.fk-tool.program = "${tool}/bin/fk-tool"; recipes.fk = "fk-tool"; }; }
EOF
  release fk v1.0.0
  # the consumer, as graft v2.22.0 makes one: graft add, graft's workflows, graft sync, a justfile that imports kits.just
  consumer "$c" "$(printf '  inputs.self.submodules = true;\n  inputs.graft.url = "git+file://%s?ref=v2.22.0";\n  outputs = inputs: inputs.graft.lib.mkFlake { inherit inputs; };' "$gv")"
  cd "$c" && printf 'import? "scions/kits.just"\n' > justfile && commit init
  ran "fromgraft: graft v2.22.0 adds a pattern" nix run .#graft -- add "$(url fk)"
  mkdir -p .forgejo/workflows && cp "$gv"/template/.forgejo/workflows/*.yaml .forgejo/workflows/
  ran "fromgraft: graft sync" nix run .#graft sync
  expect "graft wrote kits.just, with graft's header" grep -q '^# Generated by graft' scions/kits.just
  commit "graft v2.22.0"
  ran "fromgraft: graft check passes" nix run .#graft check
  cp flake.nix "$work/fg-flake.nix" && cp flake.lock "$work/fg-flake.lock" && before=$(git_ rev-parse HEAD)

  # step 1: flake.nix's URLs (the input keeps the name graft), and pot, which this consumer's kits need; then lock
  sed -i "s|  inputs.graft.url = \"git+file://$gv?ref=v2.22.0\";|  inputs.graft.url = \"git+file://$tv?ref=v0.1.0\";\n  inputs.pot.url = \"path:$pot\";|" flake.nix
  ran "fromgraft: step 1, lock" env XDG_CACHE_HOME="$work/xdg-fg" nix flake update graft
  expect "graft's input is tuteur 0.1.0" quiet jq -e --arg r "$(git_ -C "$tv" rev-parse v0.1.0)" '.nodes.graft.locked.rev == $r' flake.lock
  # step 2: sync, by graft's name for the app: tuteur 0.1.0, through the alias
  ran "fromgraft: step 2, nix run .#graft sync" nix run .#graft sync
  expect "rewrites the marker README" grep -qxF "<!-- managed by tuteur: https://github.com/danielnaab/tuteur -->" scions/README.md
  expect "renames graft's workflows" has "tuteur: renamed .forgejo/workflows/graft-check.yaml to .forgejo/workflows/tuteur-check.yaml"
  expect "all three" test "$(cd .forgejo/workflows && echo *)" = "tuteur-check.yaml tuteur-signers.yaml tuteur-upgrade.yaml"
  expect "rewrites kits.just" holds "tuteur: wrote scions/kits.just"
  expect "with tuteur's recipes" grep -qF 'exec "{{tools}}/bin/tuteur" '"'"'outdated'"'"' "$@"' scions/kits.just
  # step 3: tuteur check, and nix flake check
  ran "fromgraft: step 3, nix run .#tuteur check" nix run .#tuteur check
  expect "passes" has "tuteur: 1 pattern clean and at release tags"
  expect "names the folder" holds "tuteur: the folder scions/, which mkFlake finds without dir, is graft's name"
  expect "and the provider file" holds "tuteur: scions/fk/graft.nix is graft's name"
  ran "fromgraft: nix flake check" nix flake check
  commit "Move from graft v2"
  ran "fromgraft: ci check, as the renamed workflow runs it" ci_ check
  expect "passes" holds "tuteur: ci check passed"

  # rollback: git revert, and graft v2.22.0 checks the repository as before
  ran "fromgraft: rollback, git revert" git_ revert --no-edit HEAD
  expect "flake.nix is graft's again" cmp -s flake.nix "$work/fg-flake.nix"
  expect "and flake.lock" cmp -s flake.lock "$work/fg-flake.lock"
  expect "and graft's workflows" test -f .forgejo/workflows/graft-check.yaml
  expect "the tree is the one before" test -z "$(git_ diff "$before" HEAD --stat)"
  ran "fromgraft: graft check passes again" nix run .#graft check
  expect "graft's own message" has "graft: 1 scion clean and at release tags"
  ran "fromgraft: and nix flake check" nix flake check
  cd "$work"
}

sec_own() {
  # tuteur's docs check (dev/flake.nix) reads knowledge-base-kit from a flake input: the same commit as its pattern
  local link rev b0 b1 c=$work/own-boundary
  link=$(git_ -C "$src" ls-files -s .patterns/knowledge-base-kit | awk '$1 == "160000" { print $2 }')
  rev=$(jq -r '.nodes["knowledge-base-kit"].locked.rev' "$src/dev/flake.lock")
  expect "own: dev/flake.nix's knowledge-base-kit input is at its pattern's gitlink ($link)" test "$link" = "$rev"
  expect "own: tuteur's own lock holds no knowledge-base-kit (consumers never lock it)" \
    test "$(jq -r '.nodes | has("knowledge-base-kit")' "$src/flake.lock")" = false
  expect "own: tuteur's flake.nix doesn't declare self.submodules (it is others' input)" \
    test -z "$(grep -E '^[^#]*submodules *= *true' "$src/flake.nix")"
  ran "own: the docs check (nix flake check ./dev)" nix build --no-link "$src/dev#checks.$sys.docs"
  # the boundary: tuteur's command is built from tuteur's own sources (lib/*.sh, lib/*.jq, template/), so
  # an edit in mkFlake leaves packages.<system>.default as it was
  cp -r "$tuteur" "$c"
  b0=$(nix eval --raw "path:$c#packages.$sys.default.drvPath")
  local f
  for f in lib/mk-flake.nix flake.nix; do
    echo "# a comment" >> "$c/$f"
    b1=$(nix eval --raw "path:$c#packages.$sys.default.drvPath")
    expect "own: a comment in $f leaves tuteur's command as it was" test "$b0" = "$b1"
  done
  echo "# a comment" >> "$c/lib/common.sh"
  b1=$(nix eval --raw "path:$c#packages.$sys.default.drvPath")
  expect "own: and a comment in lib/common.sh changes it (the experiment sees tuteur's sources)" test "$b0" != "$b1"
}

sections=(own contracts mkflake tarball nix try kits add sync check outdated status changelog upgrade tuteur workflows ci migrate aliases fromgraft)
[ $# -eq 0 ] || sections=("$@")
for s in "${sections[@]}"; do
  echo "== $s"
  "sec_$s"
done
echo "all passed"
