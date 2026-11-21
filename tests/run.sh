#!/usr/bin/env bash
# End-to-end test of graft: providers are local bare repositories with release tags, grafted into
# consumers as git submodules with file:// URLs. Sections: mkflake (discovery, wiring, the errors),
# nix (the Nix behaviours graft relies on: regression tests against Nix changes), kits (mkFlake's seam with pot), add, sync, check, outdated, status, changelog, upgrade, graft
# (graft's own pin), workflows, ci, migrate. Needs nix, git and jq; fetches nixpkgs on the first run.
# Usage: tests/run.sh [SECTION...] (from anywhere; default: every section, in order). KEEP=1 leaves the
# work directory, to debug a failure.
set -euo pipefail

src=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap '[ -n "${KEEP:-}" ] || rm -rf "$work"' EXIT
[ -z "${KEEP:-}" ] || echo "work: $work"
# graft as the consumers use it: a copy of this checkout's working tree, unchanged, used as a path:
# input (a scheme without submodules, like github: and tarballs: Nix refuses an input whose flake.nix
# declares inputs.self.submodules there)
graft=$work/graft
mkdir -p "$graft" && (cd "$src" && tar --exclude=./.git --exclude=./result -cf - .) | tar -C "$graft" -xf -
# git as a reader's would run, with what tests need: file:// submodules (git >= 2.38 refuses them by
# default), no signing, a name. Through the environment, so graft's own git calls get it too.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_COUNT=6 \
  GIT_CONFIG_KEY_0=protocol.file.allow GIT_CONFIG_VALUE_0=always \
  GIT_CONFIG_KEY_1=user.name GIT_CONFIG_VALUE_1=test \
  GIT_CONFIG_KEY_2=user.email GIT_CONFIG_VALUE_2=test@example.com \
  GIT_CONFIG_KEY_3=commit.gpgsign GIT_CONFIG_VALUE_3=false \
  GIT_CONFIG_KEY_4=tag.gpgsign GIT_CONFIG_VALUE_4=false \
  GIT_CONFIG_KEY_5=init.defaultBranch GIT_CONFIG_VALUE_5=main
git_() { git "$@"; }
# tools the test runs from nixpkgs, at the commit graft's flake.lock pins (already fetched for graft)
# shellcheck disable=SC2034 # used by later sections
np="github:NixOS/nixpkgs/$(jq -r '.nodes.nixpkgs.locked.rev' "$graft/flake.lock")"
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
# jsv ARGS: check-jsonschema (the contracts' validator), from the nixpkgs graft's flake.lock pins, built once
jsv_bin=""
jsv() {
  [ -n "$jsv_bin" ] || jsv_bin=$(nix build --no-link --print-out-paths --impure \
    --expr "(builtins.getFlake \"path:$graft\").inputs.nixpkgs.legacyPackages.$sys.check-jsonschema")/bin/check-jsonschema
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
# graft ci as CI runs it: the nixos/nix image has little beyond nix, so every tool graft ci needs
# must come from its own runtimeInputs. ci_ runs it with nothing but nix and git on PATH (the image has git,
# which the workflows' checkout step uses, and Nix runs it to read a git flake's submodules).
bare=$work/bare-bin
mkdir -p "$bare" && ln -s "$(command -v nix)" "$bare/nix" && ln -s "$(command -v git)" "$bare/git"
# ci_ [VAR=VALUE...] STEP
ci_() { local vars=(); while [[ ${1:-} == *=* ]]; do vars+=("$1"); shift; done; env "${vars[@]}" PATH="$bare" nix run .#graft -- ci "$@"; }
# graft from graft's own flake, as `nix run github:danielnaab/graft -- ...` runs it
G() { nix run "path:$graft" -- "$@"; }
# graft as the repo in the current directory runs it
g() { nix run .#graft -- "$@"; }

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

# kb: a tool that prints its version (a file in the scion), and a check on the consumer's
# knowledge-base.yaml, skipped when it has none
prov kb
cat > "$work/src/kb/graft.nix" <<'EOF'
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
cat > "$work/src/nk/graft.nix" <<EOF
{ pkgs, scions, ... }:
{
  requires.kb = "$(url kb)";
  tools.nb-index = pkgs.writeShellScriptBin "nb-index" ''
    \${scions.kb.tools.kb-lint}/bin/kb-lint
    echo "nb-index reads \$(cat \${scions.kb}/version)"
  '';
  apps.nb = { type = "app"; program = "\${scions.nk.tools.nb-index}/bin/nb-index"; };
}
EOF
release nk v1.0.0

# mk: a tool named like nk's
prov mk
cat > "$work/src/mk/graft.nix" <<'EOF'
{ pkgs, ... }: { tools.nb-index = pkgs.writeShellScriptBin "nb-index" "echo mk"; }
EOF
release mk v1.0.0

# same: passes nk's tool on under the same name (one store path: one tool)
prov same
cat > "$work/src/same/graft.nix" <<'EOF'
{ scions, ... }: { tools.nb-index = scions.nk.tools.nb-index; }
EOF
release same v1.0.0

# docs: no graft.nix, only files
prov docs
echo "policy v1" > "$work/src/docs/policy.md"
release docs v1.0.0

# rs: takes graft's own names
prov rs
cat > "$work/src/rs/graft.nix" <<'EOF'
{ ... }: { apps.graft = { type = "app"; program = "/bin/sh"; }; }
EOF
release rs v1.0.0

# lk: a tool from its own pinned source (an eval-time fetch with a hash), not the consumer's nixpkgs
prov lk
mkdir -p "$work/dep" && echo "pinned-dep-ok" > "$work/dep/msg"
tar -C "$work" -czf "$work/dep.tar.gz" dep
dep_hash=$(nix-prefetch-url --unpack "file://$work/dep.tar.gz" 2>/dev/null)
cat > "$work/src/lk/graft.nix" <<EOF
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
  body=$(printf '  inputs.self.submodules = true;\n  inputs.graft.url = "path:%s";\n  outputs = inputs: inputs.graft.lib.mkFlake { inherit inputs; };' "$graft")
  printf '{\n%s\n}\n' "${2:-$body}" > "$c/flake.nix"
}
# by_hand NAME [TAG [DIR]]: graft NAME at TAG (default v1.0.0) into DIR (default scions) of the repo in
# the current directory, with plain git, as graft add does; staged
by_hand() {
  local d=${3:-scions}
  git_ submodule add -q --force -- "$(url "$1")" "$d/$1" 2>/dev/null
  git_ -C "$d/$1" checkout -q --detach "${2:-v1.0.0}"
  [ -f "$d/README.md" ] || cp "$graft/lib/scions-readme.md" "$d/README.md"
  git_ add -- "$d/$1" "$d/README.md" .gitmodules
}
commit() { git_ add -A && git_ commit -q --allow-empty -m "${1:-commit}"; }
# tools_out TOOL: run TOOL from the current directory's tools
tools_out() { nix build -o "$work/result" .#tools && "$work/result/bin/$1"; }

sec_mkflake() {
  c=$work/c1 && consumer "$c" && cd "$c"
  commit init
  ran "mkflake: no scions: tools is an empty env" nix build --no-link .#tools
  by_hand kb && by_hand nk && commit "kb, nk"
  ran "mkflake: discovery: nk's tool, from the scions alone" tools_out nb-index
  expect "and it runs kb's tool, a sibling's" has "kb-lint v1.0.0"
  expect "and reads kb's files" has "nb-index reads v1.0.0"
  ran "mkflake: a provider's app" nix run .#nb
  expect "runs" has "nb-index reads v1.0.0"
  ran "mkflake: checks, prefixed by the scion" nix eval --json ".#checks.$sys" --apply builtins.attrNames
  expect "kb-lint" holds '"kb-lint"'
  expect "mkflake: a check that skips without its settings file" quiet nix build --no-link ".#checks.$sys.kb-lint"
  echo bad > knowledge-base.yaml && commit "settings"
  refused "mkflake: a check reading the repo's settings file" nix build --no-link ".#checks.$sys.kb-lint"
  expect "fails on them" holds "kb: knowledge-base.yaml is not ok"
  echo ok > knowledge-base.yaml && commit "settings ok"
  expect "and passes on good ones" quiet nix build --no-link ".#checks.$sys.kb-lint"
  ran "mkflake: devShells.default holds the tools" nix eval --raw ".#devShells.$sys.default.name"
  # isolation: each scion is copied alone, so a commit of the repo's own doesn't change a tool
  before=$(nix eval --raw .#tools.outPath)
  echo "more" > notes.md && commit "an unrelated commit"
  expect "mkflake: isolation: the tools are the same store path after a repo commit" test "$(nix eval --raw .#tools.outPath)" = "$before"

  # a missing sibling
  git_ rm -q scions/kb && commit "no kb"
  refused "mkflake: requires: a missing sibling" nix build --no-link .#tools
  expect "says how to graft it" holds "graft: nk needs kb, which this repository does not graft: graft add $(url kb)"
  ran "mkflake: and graft's own app still evaluates" nix eval --raw ".#apps.$sys.graft.type"
  by_hand kb && commit "kb again"

  # a collision, and one store path given twice
  by_hand mk && commit "mk"
  refused "mkflake: two providers' tools with one name" nix build --no-link .#tools
  expect "names both" holds "graft: tools nb-index (from mk and nk): two scions provide the same name"
  ran "mkflake: graft's app evaluates beside it" nix eval --raw ".#apps.$sys.graft.type"
  git_ rm -q scions/mk && by_hand same && commit "same, not mk"
  ran "mkflake: the same store path from two providers is one tool" tools_out nb-index
  expect "nk's" has "nb-index reads v1.0.0"
  git_ rm -q scions/same && commit "no same"

  # graft's names
  by_hand rs && commit "rs"
  refused "mkflake: a provider's apps.graft" nix build --no-link .#tools
  expect "is an error" holds "graft: apps graft (from rs): that name is graft's; the provider must rename it"
  ran "mkflake: and graft's app is graft's" nix eval --raw ".#apps.$sys.graft.meta.description"
  expect "graft's" holds "graft: add, sync"
  git_ rm -q scions/rs && commit "no rs"

  # a provider whose graft.nix throws fails the tools and the checks, naming it (never dropped)
  prov bad
  printf '{ pkgs, ... }: throw "bad: unsupported configuration"\n' > "$work/src/bad/graft.nix" && release bad v1.0.0
  by_hand bad && commit "bad"
  refused "mkflake: a provider that throws fails the tools" nix build --no-link .#tools
  expect "with its message" holds "bad: unsupported configuration"
  expect "naming its graft.nix" holds "while evaluating scions/bad/graft.nix"
  refused "mkflake: and nix flake check" nix flake check --no-build
  ran "mkflake: graft's app still evaluates" nix eval --raw ".#apps.$sys.graft.type"
  refused "check: fails on it, from the repo's own app" g check
  expect "says why" holds "graft: the flake's tools or checks don't evaluate (above): a provider's graft.nix fails"
  # one that doesn't parse breaks every output (Nix can't catch it): check from outside names it
  printf '{ pkgs, ... }: { tools.x = pkgs.hello;\n' > "$work/src/bad/graft.nix" && release bad v1.0.1
  git_ -C scions/bad fetch -q --tags && git_ -C scions/bad checkout -q --detach v1.0.1 && commit "bad v1.0.1"
  refused "check: a graft.nix that doesn't parse, from graft's own flake" G check -C .
  expect "names it" holds "graft: scions/bad/graft.nix doesn't evaluate (above): every output of this flake fails until it does, graft's own app too; move the scion back (git submodule update --recursive -- scions/bad), or from outside: nix run github:danielnaab/graft/v2.22.0 -- upgrade -C . bad@TAG"
  git_ rm -q scions/bad && commit "no bad"

  # a scion with no graft.nix, and one with its own pinned source
  by_hand docs && by_hand lk && commit "docs, lk"
  ran "mkflake: a docs-only scion beside providers; a provider's own pinned fetch" tools_out lk
  expect "the pinned source" has "pinned-dep-ok"

  # the repo's own tools, apps and checks (perSystem): merged like a provider's, named self
  # shellcheck disable=SC2016 # Nix's own expressions
  sed -i 's|mkFlake { inherit inputs; }|mkFlake { inherit inputs; perSystem = { pkgs, scions, ... }: { tools.mine = pkgs.writeShellScriptBin "mine" "cat ${scions.docs}/policy.md"; checks.own = pkgs.runCommand "own" { } "touch $out"; devShells.default = pkgs.mkShell { name = "own-shell"; }; }; }|' flake.nix
  commit "perSystem"
  ran "mkflake: perSystem: the repo's own tool, beside the providers'" tools_out mine
  expect "reads a scion" has "policy v1"
  expect "and the providers' tools are still there" test -x "$work/result/bin/lk"
  ran "mkflake: perSystem's checks, unprefixed" nix eval --json ".#checks.$sys" --apply builtins.attrNames
  expect "own" holds '"own"'
  ran "mkflake: perSystem's devShells.default replaces graft's" nix eval --raw ".#devShells.$sys.default.name"
  expect "own-shell" has "own-shell"
  sed -i 's|tools.mine = |tools.lk = |' flake.nix && commit "perSystem lk"
  refused "mkflake: perSystem: a tool named like a provider's" nix build --no-link .#tools
  expect "is a collision, naming self" holds "graft: tools lk (from scion lk and the consumer's perSystem): both provide the same name; rename the consumer's own"
  git_ checkout -q HEAD~2 -- flake.nix && commit "no perSystem"

  # the repo's own outputs: merged last, per name; graft's app stays graft's
  sed -i 's|inputs.graft.lib.mkFlake { inherit inputs; }|inputs.graft.lib.mkFlake { inherit inputs; outputs = { apps.'"$sys"'.nb = { type = "app"; program = "/bin/echo"; }; packages.'"$sys"'.extra = inputs.self; }; }|' flake.nix
  commit "own outputs"
  ran "mkflake: the repo's own app replaces a provider's" nix eval --raw ".#apps.$sys.nb.program"
  expect "the repo's" has "/bin/echo"
  expect "mkflake: the repo's own package beside the tools" quiet nix eval --raw ".#packages.$sys.extra.outPath"
  expect "and the tools" quiet nix eval --raw ".#packages.$sys.tools.outPath"
  sed -i 's|apps.'"$sys"'.nb = |apps.'"$sys"'.graft = |' flake.nix && commit "own graft app"
  refused "mkflake: the repo's own apps.graft" nix eval --raw ".#apps.$sys.graft.type"
  expect "is an error" holds "graft: mkFlake's outputs has apps.$sys.graft: that name is graft's; rename the repo's own"
  git_ checkout -q HEAD~2 -- flake.nix && commit "outputs back"

  # Without inputs.self.submodules a git flake's source has no scions at all (absent, not empty):
  # .gitmodules says what should be there
  sed -i '/inputs.self.submodules/d' flake.nix && commit "no self.submodules"
  refused "mkflake: registered but absent (no inputs.self.submodules)" nix build --no-link .#tools
  expect "says what to add" holds "graft: .gitmodules registers scions/docs, scions/kb, scions/lk, scions/nk but the flake's source lacks them: add inputs.self.submodules = true; to flake.nix (Nix >= 2.27). Fetched with github:? use git+https://…, which keeps submodules."
  git_ checkout -q HEAD~1 -- flake.nix && commit "self.submodules back"
  # a tarball of the repo (what github: fetches) has no submodules either
  git_ archive --format=tar.gz -o "$work/c1.tar.gz" --prefix=c1/ HEAD
  ran "mkflake: a tarball of the repo (github:): the tools build without the scions" nix build --no-link "tarball+file://$work/c1.tar.gz#tools"
  expect "warning, and saying use git+https" holds "graft: scions/docs, scions/kb, scions/lk, scions/nk are empty in the flake's source, so the tools leave out what they give: run git submodule update --init --recursive (or graft sync). Fetched with github:? use git+https://…, which keeps submodules."

  # a folder that isn't a submodule
  mkdir -p scions/stray && echo x > scions/stray/x.md && commit "stray"
  refused "mkflake: a folder in the scions directory that isn't a submodule" nix build --no-link .#tools
  expect "is named" holds "graft: scions/stray is not a submodule: graft add URL, or remove it"
  git_ rm -rq scions/stray && commit "no stray"

  # the wrong dir: graft's marker README is how it knows
  sed -i 's|mkFlake { inherit inputs; }|mkFlake { inherit inputs; dir = ".scions"; }|' flake.nix && commit "dir = .scions"
  refused "mkflake: dir names no folder, and graft's README is elsewhere" nix build --no-link .#tools
  expect "says where it is" holds "graft: graft's README is in scions/ but mkFlake's dir is \".scions\": set dir = \"scions\"; (or move the scions)"
  ran "mkflake: and graft's app still evaluates" nix eval --raw ".#apps.$sys.graft.type"
  refused "check: from the repo's own app, too" g check
  expect "says so" holds "graft: graft's README is in scions/ but mkFlake's dir is \".scions\""
  sed -i 's|dir = ".scions";|dir = "docs";|' flake.nix
  mkdir -p docs && echo "# docs" > docs/README.md && commit "dir = docs"
  refused "mkflake: dir names a folder without graft's README" nix build --no-link .#tools
  expect "says where it is" holds "graft: graft's README is in scions/ but mkFlake's dir is \"docs\": set dir = \"scions\"; (or move the scions)"
  sed -i 's|dir = "docs";|dir = "a/b";|' flake.nix && commit "dir = a/b"
  refused "mkflake: dir must be one folder name" nix build --no-link .#tools
  expect "says so" holds "graft: mkFlake's dir must be one folder name (letters, digits, . _ -; not ., .. or .git), got \"a/b\""
  sed -i 's|mkFlake { inherit inputs; dir = "a/b"; }|mkFlake { inherit inputs; }|' flake.nix && git_ rm -rq docs && commit "dir back"

  # a copy-mode scions README (graft v2.12): the upgrade steps, not a confusing error
  cp scions/README.md "$work/readme" && printf '\n| Scion | Commit |\n|---|---|\n' >> scions/README.md && commit "copy mode"
  refused "mkflake: a copy-mode scions README" nix build --no-link .#tools
  expect "points to the Upgrading steps" holds "graft: scions/README.md is graft's copy-mode README (v2.12 or earlier): graft v2.13.0 pins scions with git submodules; follow the Upgrading steps of v2.13.0 in graft's CHANGELOG.md"
  cp "$work/readme" scions/README.md && commit "readme back"

  # A flake in a subdirectory, run as path: (keeps the rest of the repo out of the store): the
  # scions live under it; a fresh clone has them empty until git initialises them
  s=$work/sub && mkdir -p "$s/nix/tools" "$s/notebook" && git_ -C "$s" init -q && cd "$s"
  echo "private" > notebook/secret.md
  cat > nix/tools/flake.nix <<EOF
{
  inputs.graft.url = "path:$graft";
  outputs = inputs: inputs.graft.lib.mkFlake { inherit inputs; dir = ".scions"; outputs.own = "mine"; };
}
EOF
  by_hand kb v1.0.0 nix/tools/.scions && by_hand nk v1.0.0 nix/tools/.scions && commit init
  ran "mkflake: a path: flake in a subdirectory" nix build -o "$work/result" "path:$s/nix/tools#tools"
  expect "with its scions" quiet "$work/result/bin/nb-index"
  git_ clone -q "$s" "$work/sub-clone" && cd "$work/sub-clone"
  ran "mkflake: path: flake, fresh clone: the tools build without the empty scions" nix build -o "$work/result" "path:$PWD/nix/tools#tools"
  expect "warning which" holds "graft: .scions/kb, .scions/nk are empty in the flake's source, so the tools leave out what they give: run git submodule update --init --recursive (or graft sync)"
  expect "and leave their tools out" test ! -e "$work/result/bin/nb-index"
  ran "mkflake: and graft's app evaluates, to fill them" nix eval --raw "path:$PWD/nix/tools#apps.$sys.graft.type"
  ran "mkflake: and the repo's own outputs" nix eval --raw "path:$PWD/nix/tools#own"
  expect "evaluate" has "mine"
  git_ submodule update -q --init
  expect "mkflake: path: flake after git submodule update --init" quiet nix build --no-link "path:$PWD/nix/tools#tools"
  mkdir -p nix/tools/.scions/copy && echo x > nix/tools/.scions/copy/a.md
  refused "mkflake: path: flake, a folder without .git is not a submodule" nix build --no-link "path:$PWD/nix/tools#tools"
  expect "is named" holds "graft: .scions/copy is not a submodule: graft add URL, or remove it"
  rm -rf nix/tools/.scions/copy
}

# The Nix behaviours the model depends on (design finding 1): a regression test, so a Nix release
# that changes them fails here rather than in a consumer.
sec_nix() {
  c=$work/n1 && consumer "$c" && cd "$c"
  by_hand kb && commit init && quiet nix flake lock && commit lock
  ran "nix: a clean tree builds the scion at its gitlink" tools_out kb-lint
  expect "v1.0.0" has "kb-lint v1.0.0"
  printf 'edited' > scions/kb/version
  ran "nix: clean parent, uncommitted edit in a scion" tools_out kb-lint
  expect "ignored (Nix fetches the gitlink)" has "kb-lint v1.0.0"
  echo "# dirty" >> flake.nix
  ran "nix: dirty parent (a tracked file modified), uncommitted edit in a scion" tools_out kb-lint
  expect "used (Nix reads the working tree)" has "kb-lint edited"
  git_ checkout -q -- flake.nix
  ran "nix: path: reads the working tree" sh -c "nix build -o '$work/result' 'path:$c#tools' && '$work/result/bin/kb-lint'"
  expect "the edit" has "kb-lint edited"
  git_ -C scions/kb commit -qam "local only" && git_ add scions/kb && commit "an unpushed gitlink"
  refused "nix: a committed gitlink the provider's remote lacks" nix build --no-link .#tools
  expect "fails to fetch it" holds "Cannot find Git revision"
  # a commit reachable only from a tag
  git_ -C "$work/src/kb" checkout -q --detach v1.0.0
  printf 'v1.0.1' > "$work/src/kb/version" && git_ -C "$work/src/kb" commit -qam v1.0.1
  git_ -C "$work/src/kb" tag v1.0.1 && git_ -C "$work/src/kb" push -q origin refs/tags/v1.0.1
  git_ -C "$work/src/kb" checkout -q main
  git_ -C scions/kb fetch -q --tags && git_ -C scions/kb checkout -q --detach v1.0.1 && git_ add scions/kb && commit "tag-only"
  ran "nix: a commit only a tag reaches" tools_out kb-lint
  expect "is fetched" has "kb-lint v1.0.1"
  # nested: a provider's own submodules are fetched by Nix (git doesn't initialise them)
  prov pv
  git_ -C "$work/src/pv" submodule add -q "$(url docs)" scions/docs 2>/dev/null
  cat > "$work/src/pv/graft.nix" <<'EOF'
{ pkgs, scion, ... }: { tools.pv = pkgs.writeShellScriptBin "pv" "cat ${scion}/scions/docs/policy.md"; }
EOF
  release pv v1.0.0
  by_hand pv && commit "pv"
  expect "nix: git leaves a scion's own submodules empty" test ! -e scions/pv/scions/docs/policy.md
  ran "nix: Nix fetches them" tools_out pv
  expect "nested" has "policy v1"
  git_ -C "$work/src/pv" config -f .gitmodules submodule.scions/docs.url "file://$work/nonexistent.git"
  release pv v1.1.0
  git_ -C scions/pv fetch -q --tags && git_ -C scions/pv checkout -q --detach v1.1.0 && git_ add scions/pv && commit "pv v1.1.0"
  refused "nix: a nested submodule Nix can't fetch fails the consumer" nix build --no-link .#tools
  expect "names it" holds "nonexistent.git"
  git_ rm -q scions/pv && commit "no pv"
}

# The command sections share one consumer, $work/cmd, and the providers below: run them in order
# (add first). pa: a tool printing its version; releases v1.0.0, v1.0.1, v1.1.0 (annotated).
cmd_setup() {
  prov pa
  mkdir -p "$work/src/pa/docs/old"
  cat > "$work/src/pa/graft.nix" <<'EOF'
{ pkgs, ... }: { tools.pa = pkgs.writeShellScriptBin "pa" "echo pa ${builtins.readFile ./version}"; }
EOF
  echo "policy" > "$work/src/pa/docs/policy.md" && echo "old" > "$work/src/pa/docs/old/x.md"
  printf v1.0.0 > "$work/src/pa/version" && release pa v1.0.0
  printf v1.0.1 > "$work/src/pa/version" && release pa v1.0.1
  printf v1.1.0 > "$work/src/pa/version" && release pa v1.1.0 -a
  git_ -C "$work/src/pa" tag not-a-version && git_ -C "$work/src/pa" push -q origin not-a-version
  # nest: a provider with a submodule of its own
  prov nest
  git_ -C "$work/src/nest" submodule add -q "$(url docs)" scions/docs 2>/dev/null
  release nest v1.0.0
  # notag: no release
  prov notag && git_ -C "$work/src/notag" add -A && git_ -C "$work/src/notag" commit -qm init \
    && git_ -C "$work/src/notag" push -q origin HEAD:main
  c=$work/cmd && consumer "$c" && cd "$c"
  commit init && quiet nix flake lock && commit lock
}

sec_add() {
  cmd_setup
  ran "add: graft URL at its newest release" g add "$(url pa)"
  expect "says where and at what" has "graft: scions/pa <- v1.1.0 ($(sha pa v1.1.0 | cut -c1-7))"
  expect "and what's next" has "graft: next: commit"
  expect "add: the gitlink is the annotated tag's commit" test "$(git_ ls-files -s scions/pa | cut -d' ' -f2)" = "$(sha pa v1.1.0)"
  expect "add: staged: .gitmodules, the gitlink and the README" \
    test "$(git_ diff --cached --name-only | paste -sd ' ')" = ".gitmodules scions/README.md scions/pa"
  expect "add: the README carries graft's marker" test "$(head -1 scions/README.md)" = "<!-- managed by graft: https://github.com/danielnaab/graft -->"
  # shellcheck disable=SC2016 # markdown backticks
  expect "and names the repo's command" grep -qF '`nix run .#graft check`' scions/README.md
  expect "add: the URL in .gitmodules as given" test "$(git_ config -f .gitmodules submodule.scions/pa.url)" = "$(url pa)"
  ran "add: URL@TAG" g add "$(url docs)@v1.0.0"
  expect "at that tag" has "graft: scions/docs <- v1.0.0 ($(sha docs v1.0.0 | cut -c1-7))"
  ran "add: a provider with submodules of its own" g add "$(url nest)"
  expect "says Nix fetches them" has "graft: note: scions/nest has its own submodules (scions/docs); graft fills them, and Nix fetches them too, so each must be reachable"
  expect "and fills them" test -f scions/nest/scions/docs/policy.md
  refused "add: an existing scion" g add "$(url pa)"
  expect "says so" has "graft: scions/pa exists"
  refused "add: a relative URL" g add ../pa.git
  expect "says why" has "graft: a relative URL (../pa.git) won't resolve for Nix; give an absolute URL"
  refused "add: a provider with no release" g add "$(url notag)"
  expect "says so" has "graft: $(url notag) has no semver tags"
  refused "add: a tag that isn't upstream" g add "$(url pa)@v9.9.9" other
  expect "says so" has "graft: other: no tag v9.9.9 upstream"
  refused "add: git@host:path keeps its @ (only @TAG is split off)" G add 'git@nonexistent.invalid:x/y.git@v1.0.0'
  expect "lists that URL" holds "can't list tags at git@nonexistent.invalid:x/y.git"
  mkdir -p "$work/nongit"
  refused "add: outside a git work tree" G add -C "$work/nongit" "$(url pa)"
  expect "says so" holds "graft: not inside a git work tree"
  commit "pa, docs, nest"
  ran "add: the tools build from the new scion" tools_out pa
  expect "at v1.1.0" has "pa v1.1.0"
  # a flake without inputs.self.submodules: add says to add it
  n=$work/noself && consumer "$n" "$(printf '  inputs.graft.url = "path:%s";\n  outputs = inputs: inputs.graft.lib.mkFlake { inherit inputs; };' "$graft")"
  ran "add: a top flake without inputs.self.submodules" G add -C "$n" "$(url docs)"
  expect "says it needs it" has "graft: next: commit; a git flake also needs inputs.self.submodules = true;"
  # a flake in a subdirectory: --scions from the top, or the repo's own app run from there
  s=$work/subcmd && mkdir -p "$s/nix/tools" && git_ -C "$s" init -q
  printf '{\n  inputs.graft.url = "path:%s";\n  outputs = inputs: inputs.graft.lib.mkFlake { inherit inputs; dir = ".scions"; };\n}\n' "$graft" > "$s/nix/tools/flake.nix"
  refused "add: --scions beside no flake" G add -C "$s" --scions nix/.scions "$(url docs)"
  expect "says so" has "graft: --scions nix/.scions: no flake.nix in nix; the scions directory goes beside the flake that grafts them"
  ran "add: --scions PATH" G add -C "$s" --scions nix/tools/.scions "$(url docs)"
  expect "there" has "graft: nix/tools/.scions/docs <- v1.0.0 ($(sha docs v1.0.0 | cut -c1-7))"
  expect "and its README names the path: command" grep -qF "\`nix run 'path:nix/tools#graft' check\`" "$s/nix/tools/.scions/README.md"
  ran "add: the next scion goes to the same directory" G add -C "$s" "$(url kb)@v1.0.0"
  expect "found by graft's README" has "graft: nix/tools/.scions/kb <- v1.0.0 ($(sha kb v1.0.0 | cut -c1-7))"
  s2=$work/subcmd2 && mkdir -p "$s2/nix/tools" && git_ -C "$s2" init -q && cp "$s/nix/tools/flake.nix" "$s2/nix/tools/" && git_ -C "$s2" add -A
  ran "add: the repo's own app, run from its subdirectory, puts the first scion beside it" \
    sh -c "cd '$s2/nix/tools' && nix run 'path:$s2/nix/tools#graft' -- add '$(url docs)'"
  expect "in its dir" has "graft: nix/tools/.scions/docs <- v1.0.0 ($(sha docs v1.0.0 | cut -c1-7))"
  cd "$c"
}

sec_sync() {
  cd "$work/cmd"
  git_ clone -q "$work/cmd" "$work/cmd-clone" && cd "$work/cmd-clone"
  expect "sync: a fresh clone's scions are empty" test ! -e scions/pa/version
  ran "sync: fills them" g sync
  expect "says where each is" has "graft: scions/pa at v1.1.0 ($(sha pa v1.1.0 | cut -c1-7))"
  expect "filled" test -f scions/pa/version
  expect "sync: and a scion's own submodules (Nix reads them while the tree is dirty)" test -f scions/nest/scions/docs/policy.md
  git_ -C scions/pa checkout -q v1.0.0
  ran "sync: a scion checked out elsewhere (an agent's fix branch)" g
  expect "is left there, and said" has "graft: scions/pa at v1.0.0 ($(sha pa v1.0.0 | cut -c1-7)), not the recorded $(sha pa v1.1.0 | cut -c1-7): left as it is (git add scions/pa records it; git submodule update --recursive -- scions/pa goes back)"
  expect "not moved" test "$(git_ -C scions/pa rev-parse HEAD)" = "$(sha pa v1.0.0)"
  git_ -C scions/pa checkout -q --detach "$(sha pa v1.1.0)"
  echo "mine" >> scions/README.md
  ran "sync: rewrites graft's README" g sync
  expect "says so" has "graft: wrote scions/README.md"
  refuse "and the edit is gone" grep -q mine scions/README.md
  mkdir -p .forgejo/workflows && cp "$graft"/template/.forgejo/workflows/*.yaml .forgejo/workflows/
  echo "# old" >> .forgejo/workflows/graft-check.yaml && git_ add -A
  ran "sync: refreshes graft's workflows" g sync
  expect "says so" has "graft: refreshed .forgejo/workflows/graft-check.yaml"
  refused "sync: from graft's own flake" G sync -C .
  expect "says why" holds "graft: sync runs from the repo's own flake"
  cd "$work/cmd" && mkdir -p .forgejo/workflows && cp "$graft"/template/.forgejo/workflows/*.yaml .forgejo/workflows/ && commit "workflows"
}

sec_check() {
  cd "$work/cmd"
  ran "check: every scion clean and at a release tag" g check
  expect "says so" has "graft: 3 scions clean and at release tags"
  # a submodule the index holds as files (what `git add` does over a copied scion still in the index)
  git_ rm -q --cached scions/docs && git_ update-index --add --cacheinfo "100644,$(git_ hash-object -w scions/docs/policy.md),scions/docs/policy.md"
  refused "check: a submodule tracked as files" G check -C .
  expect "says how to fix it" has "graft: scions/docs is tracked as files, not as a submodule: git rm -r -q --cached scions/docs, then git add scions/docs if scions/docs/.git exists; otherwise delete the folder and graft add its URL@TAG again"
  refused "check --committed: too" G check -C . --committed
  refused "sync: refuses it" g sync
  git_ reset -q -- scions/docs
  git_ update-index --add --cacheinfo "100644,$(git_ hash-object -w scions/docs/policy.md),scions/x/a.md"
  refused "add: over a path still tracked as files" G add -C . "$(url docs)" x
  expect "says so" has "graft: scions/x is still tracked as files (a copied scion?): git rm -r -q --cached scions/x, delete the folder, then graft add again"
  git_ rm -q --cached scions/x/a.md
  # shellcheck disable=SC2016 # sh's own expressions
  refuse "check: graft's README outside mkFlake's dir" sh -c 'env GRAFT_IN_REPO=1 GRAFT_DIR=.scions nix run "path:$1" -- check -C . >"$2" 2>&1' _ "$graft" "$work/out"
  expect "says set dir" grep -qF "graft: graft's README is in scions/ but mkFlake's dir is \".scions\": set dir = \"scions\"; in flake.nix (or move the scions)" "$work/out"
  ran "check: from graft's flake, -C" G check -C "$work/cmd"
  echo "x" > scions/pa/untracked.txt
  ran "check: an untracked file in a scion (Nix doesn't read it)" g check
  rm scions/pa/untracked.txt
  printf edited > scions/pa/version
  refused "check: an uncommitted edit in a scion" g check
  expect "names it" has "graft: uncommitted edits in scions/pa: version (Nix builds ignore them while the rest of the tree is clean)"
  git_ -C scions/pa checkout -q -- version
  git_ -C scions/pa checkout -q --detach v1.0.1
  refused "check: a scion checked out at another commit than the gitlink" g check
  expect "says both, and the fixes" has "graft: scions/pa is checked out at $(sha pa v1.0.1 | cut -c1-7) but the repository records $(sha pa v1.1.0 | cut -c1-7): git add scions/pa to record it, or git submodule update --recursive -- scions/pa to go back"
  git_ -C scions/pa commit -q --allow-empty -m "a fix" && git_ add scions/pa
  refused "check: a gitlink at no release" g check
  expect "names the nearest" holds "graft: scions/pa at $(git_ -C scions/pa rev-parse --short=7 HEAD) is not a release tag of $(url pa) (nearest: v1.0.1-1-g"
  expect "and the way on" holds "release it, then graft upgrade pa@TAG (or graft upgrade pa, the newest release of its major)"
  git_ -C scions/pa tag v1.0.9
  refused "check: a tag only the scion's clone has" g check
  expect "says push it" has "graft: scions/pa: tag v1.0.9 exists locally but not at $(url pa): push it (git -C scions/pa push origin v1.0.9)"
  git_ -C scions/pa tag -d v1.0.9 >/dev/null
  git_ -C scions/pa checkout -q --detach "$(sha pa v1.1.0)" && git_ add scions/pa
  command mv "$work/pa.git" "$work/pa.away"
  ran "check: an upstream it can't list: the scion's own tags" G check -C .
  expect "says so" holds "(upstream unreadable: checked local tags)"
  command mv "$work/pa.away" "$work/pa.git"
  mkdir -p scions/stray && echo x > scions/stray/a.md
  refused "check: a folder that isn't a submodule" g check
  expect "names it" has "graft: scions/stray is not a submodule: graft add URL, or remove it"
  rm -rf scions/stray
  cp .gitmodules "$work/gm" && git_ config -f .gitmodules submodule.scions/docs.url ../docs.git
  refused "check: a relative URL" g check
  expect "says so" has "graft: scions/docs: .gitmodules gives a relative URL (../docs.git), which Nix can't resolve: give an absolute one (git config -f .gitmodules submodule.scions/docs.url URL)"
  cp "$work/gm" .gitmodules
  sed -i '/inputs.self.submodules/d' flake.nix
  refused "check: a top flake without inputs.self.submodules" g check
  expect "says to add it" has "graft: flake.nix doesn't declare inputs.self.submodules = true;, so Nix sees no scions: add it (Nix 2.27 or later)"
  git_ checkout -q -- flake.nix
  echo "# mine" >> .forgejo/workflows/graft-check.yaml
  refused "check: an edited workflow of graft's" g check
  expect "says so" holds "graft: .forgejo/workflows/graft-check.yaml differs from the copy this graft version ships"
  git_ checkout -q -- .forgejo
  git_ clone -q "$work/cmd" "$work/cmd-fresh" && cd "$work/cmd-fresh"
  refused "check: a fresh clone's empty scions" g check
  expect "says how to fill it" has "graft: scions/pa is empty: git submodule update --init --recursive -- scions/pa (or graft sync)"
  ran "check --committed: what a commit holds, with no scion filled" g check --committed
  expect "says so" has "graft: 3 scions registered and at release tags"
  cd "$work/cmd"
  # two scions directories, a copy-mode README
  mkdir -p other && cp scions/README.md other/ && git_ add other
  refused "check: two scions directories" g check
  expect "names both" has "graft: two scions directories: other, scions; graft supports one per repository"
  git_ rm -rqf other
  cp scions/README.md "$work/readme" && printf '| Scion | Commit |\n' >> scions/README.md && git_ add scions/README.md
  refused "check: a copy-mode README" G check -C .
  expect "points to the Upgrading steps" holds "graft: scions/README.md is graft's copy-mode README (v2.12 or earlier)"
  cp "$work/readme" scions/README.md && git_ add scions/README.md
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

sec_outdated() {
  cd "$work/cmd"
  pa_next
  ran "outdated: lists graft and every scion" g outdated
  expect "pa: newest within its major, and the new major" grep -qE "^pa +scions +v1.1.0 +v1.2.0 +outdated +v2.0.0$" <<<"$out"
  expect "docs: current" grep -qE "^docs +scions +v1.0.0 +v1.0.0 +current +-$" <<<"$out"
  expect "graft by path: untagged" grep -qE "^graft +- +path +- +untagged" <<<"$out"
  expect "says what MAJOR means" grep -q "^MAJOR: " <<<"$out"
  ran "outdated --json" g outdated --json
  expect "fields" quiet jq -e '.[] | select(.name=="pa") | .pinned=="v1.1.0" and .latest=="v1.2.0" and .status=="outdated" and .major=="v2.0.0" and .dir=="scions"' <<<"$out"
  ran "outdated -C, from graft's flake" G outdated -C "$work/cmd"
  expect "the same" grep -qE "^pa +scions +v1.1.0 +v1.2.0 +outdated" <<<"$out"
  git_ -C scions/docs commit -q --allow-empty -m wip && git_ add scions/docs
  ran "outdated: a scion at no release" g outdated
  expect "untagged, with its commit, and the newest release of its nearest release's major" grep -qE "^docs +scions +$(git_ -C scions/docs rev-parse --short=12 HEAD) +v1.0.0 +untagged" <<<"$out"
  git_ -C scions/docs checkout -q --detach HEAD~1 && git_ add scions/docs
  command mv "$work/docs.git" "$work/docs.away"
  ran "outdated: an upstream it can't list" G outdated -C .
  expect "unknown" grep -qE "^docs +scions +v1.0.0 +- +unknown" <<<"$out"
  command mv "$work/docs.away" "$work/docs.git"
}

# The contracts' schemas are JSON Schema 2020-12, and their golden fixtures (what readers test against) validate.
# What graft really prints is validated where it prints it: status.
sec_contracts() {
  local st=contracts/status-1.schema.json
  expect "contracts: status/1's schema is a 2020-12 schema" quiet jsv --check-metaschema "$src/$st"
  expect "contracts: status/1's fixtures validate" valid "$st" "$src"/contracts/fixtures/status-1/*.json
  out=$(jq '.scions[0].latest.status = "unknown"' "$src/contracts/fixtures/status-1/clean.json")
  refuse "contracts: status/1 refuses an unknown latest with no reason" quiet valid "$st"
  out=$(jq '.scions[0].owner = "ada"' "$src/contracts/fixtures/status-1/clean.json")
  refuse "contracts: status/1 refuses a field it does not define (a new field is a new version)" quiet valid "$st"
  out=$(jq 'del(.graft)' "$src/contracts/fixtures/status-1/clean.json")
  refuse "contracts: status/1 refuses a report without graft (a value is null, never left out)" quiet valid "$st"
}

# graft status (status/1): every --json report validates against contracts/status-1.schema.json. Runs after
# outdated (pa at v1.1.0, with v1.2.0 and v2.0.0 upstream), and leaves $work/cmd as it found it.
sj() { stdout_of g status --json; }
# shellcheck disable=SC2016 # jq's own $variables
sec_status() {
  cd "$work/cmd"
  local pa11 rc st=contracts/status-1.schema.json
  pa11=$(sha pa v1.1.0)
  ran "status --json: a report" sj
  expect "validates against status/1's schema" valid "$st"
  expect "version 1, the top, the scions directory" quiet jq -e --arg r "$(pwd -P)" '.version == 1 and .repo == $r and .scions_dir == "scions" and .problems == []' <<<"$out"
  expect "one entry per scion, by name" test "$(jq -c '[.scions[].name]' <<<"$out")" = '["docs","nest","pa"]'
  expect "pa: its pin, its tag upstream, clean at its gitlink, no problems" quiet jq -e --arg c "$pa11" --arg u "$(url pa)" \
    '.scions[] | select(.name == "pa") | .path == "scions/pa" and .url == $u and .registered and .commit == $c and .tag == "v1.1.0"
       and .tag_from == "upstream" and .filled and .head == $c and .clean == true and .problems == []' <<<"$out"
  expect "pa: outdated, as graft outdated says, with the later major" quiet jq -e \
    '.scions[] | select(.name == "pa") | .latest == {status: "outdated", tag: "v1.2.0", major: "v2.0.0", reason: null}' <<<"$out"
  expect "docs: current" quiet jq -e '.scions[] | select(.name == "docs") | .latest == {status: "current", tag: "v1.0.0", major: null, reason: null}' <<<"$out"
  expect "graft by path: untagged, no commit" quiet jq -e '.graft == {url: null, commit: null, tag: null, latest: {status: "untagged", tag: null, major: null, reason: null}}' <<<"$out"
  ran "status: a table" g status
  expect "a header" grep -qE "^NAME +PATH +TAG +COMMIT +CHECKOUT +LATEST" <<<"$out"
  expect "pa's row" grep -qE "^pa +scions/pa +v1.1.0 +${pa11:0:7} +clean +v1.2.0 \(outdated; v2.0.0 is a new major\)$" <<<"$out"
  expect "graft's row" grep -qE "^graft +- +- +- +- +untagged$" <<<"$out"
  ran "status -C, from graft's flake" stdout_of G status -C "$work/cmd" --json
  expect "the same report" quiet jq -e '[.scions[].name] == ["docs","nest","pa"]' <<<"$out"
  # a dirty scion, away from its gitlink: reported, exit 0 (graft check is the gate)
  printf edited > scions/pa/version
  ran "status: an uncommitted edit, still exit 0" sj
  expect "validates" valid "$st"
  expect "clean false, and check's message" quiet jq -e '.scions[] | select(.name == "pa") | .clean == false
    and (.problems | index("uncommitted edits in scions/pa: version (Nix builds ignore them while the rest of the tree is clean)"))' <<<"$out"
  git_ -C scions/pa checkout -q -- version
  git_ -C scions/pa checkout -q --detach v1.0.1
  ran "status: a scion checked out away from its gitlink" sj
  expect "head is the checkout, commit the gitlink, check's message" quiet jq -e --arg c "$pa11" --arg h "$(sha pa v1.0.1)" \
    '.scions[] | select(.name == "pa") | .commit == $c and .head == $h and .clean == true
       and (.problems | any(startswith("scions/pa is checked out at ")))' <<<"$out"
  git_ -C scions/pa checkout -q --detach "$pa11"
  # a gitlink at no release
  git_ -C scions/docs commit -q --allow-empty -m wip && git_ add scions/docs
  ran "status: a gitlink at no release" sj
  expect "validates" valid "$st"
  expect "no tag (read upstream), untagged, check's message" quiet jq -e \
    '.scions[] | select(.name == "docs") | .tag == null and .tag_from == "upstream" and .latest.status == "untagged" and .latest.tag == "v1.0.0"
       and (.problems | any(contains("is not a release tag of")))' <<<"$out"
  git_ -C scions/docs checkout -q --detach HEAD~1 && git_ add scions/docs
  # an upstream it can't list: null and a reason, never left out; the tag from the scion's own clone
  command mv "$work/pa.git" "$work/pa.away"
  ran "status: an upstream it can't list (from graft's flake: the repo's own would fetch pa)" stdout_of G status --json -C .
  command mv "$work/pa.away" "$work/pa.git"
  expect "validates" valid "$st"
  expect "latest unknown, with git's reason" quiet jq -e --arg u "$(url pa)" \
    '.scions[] | select(.name == "pa") | .latest.status == "unknown" and .latest.tag == null and .latest.major == null
       and (.latest.reason | startswith("can'"'"'t list tags at \($u): "))' <<<"$out"
  expect "the tag from the scion's clone" quiet jq -e '.scions[] | select(.name == "pa") | .tag == "v1.1.0" and .tag_from == "local" and .problems == []' <<<"$out"
  # a folder .gitmodules doesn't register, and graft try left on
  mkdir -p scions/stray && echo x > scions/stray/a.md
  quiet g try
  ran "status: a stray folder, try on" sj
  quiet g try --stop
  rm -rf scions/stray
  expect "validates" valid "$st"
  expect "the folder: not registered, check's message, unknown with a reason" quiet jq -e \
    '.scions[] | select(.name == "stray") | .registered == false and .url == null and .commit == null and .filled == false
       and .problems == ["scions/stray is not a submodule: graft add URL, or remove it"] and .latest.status == "unknown" and (.latest.reason | length > 0)' <<<"$out"
  expect "try: a repository problem" quiet jq -e '.problems | any(startswith("graft try is on (.graft-try)"))' <<<"$out"
  # a fresh clone: empty scions
  rm -rf "$work/cmd-status" && git_ clone -q "$work/cmd" "$work/cmd-status" && cd "$work/cmd-status"
  ran "status: a fresh clone's empty scions" sj
  expect "validates" valid "$st"
  expect "filled false, head and clean null, the tag still read upstream" quiet jq -e --arg c "$pa11" \
    '.scions[] | select(.name == "pa") | .filled == false and .head == null and .clean == null and .commit == $c and .tag == "v1.1.0"
       and .problems == ["scions/pa is empty: git submodule update --init --recursive -- scions/pa (or graft sync)"]' <<<"$out"
  # a repository with no scions
  local c=$work/status-none && consumer "$c" && cd "$c" && commit init
  ran "status: no scions" stdout_of G status --json -C "$c"
  expect "validates" valid "$st"
  expect "scions_dir null, no scions, no graft pin (no lock)" quiet jq -e '.scions_dir == null and .scions == [] and .graft == null' <<<"$out"
  # exit statuses: 1 for a repository it can't read, 2 for a usage error
  mkdir -p "$work/not-git"
  rc=$(exit_of G status --json -C "$work/not-git")
  expect "status: not a git work tree: exit 1" test "$rc" = 1
  expect "says so" grep -qF "graft: not inside a git work tree: $work/not-git" "$work/exit.out"
  rc=$(exit_of G status --nope)
  expect "status: an unknown option: exit 2" test "$rc" = 2
  expect "names it, and the usage" grep -qF "usage: graft status [-C REPO] [--json]" "$work/exit.out"
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
  expect "graft by path: one line" has "graft path: not pinned to a tag; nothing to compare"
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
  printf edited > scions/pa/version
  refused "upgrade: refuses a scion with uncommitted edits" g upgrade
  expect "says so" holds "graft: pa: uncommitted edits in scions/pa (version); nothing changed"
  git_ -C scions/pa checkout -q -- version
  # a scion on a fix branch, away from its gitlink: it moves, and the branch stays
  git_ -C scions/pa switch -q -c fix v1.0.1
  cp .gitmodules "$work/gm-before"
  ran "upgrade: within the pinned major" g upgrade
  expect "says what moved" has "graft: pa v1.1.0 -> v1.2.0"
  expect "and the major not taken" has "graft: pa: v2.0.0 is a new major version; not taken (graft upgrade pa@v2.0.0)"
  expect "the scion checked out at the tag" test "$(git_ -C scions/pa rev-parse HEAD)" = "$(sha pa v1.2.0)"
  expect "and its gitlink staged" test "$(git_ diff --cached --name-only)" = "scions/pa"
  expect ".gitmodules untouched" cmp -s .gitmodules "$work/gm-before"
  expect "the fix branch kept" quiet git_ -C scions/pa rev-parse -q --verify refs/heads/fix
  ran "upgrade: again, nothing to do" g upgrade
  expect "says so" holds "graft: nothing to upgrade"
  commit "pa v1.2.0"
  ran "upgrade: the tools build the new version" tools_out pa
  expect "v1.2.0" has "pa v1.2.0"
  # from an untagged gitlink (a fix, recorded before its release): NAME@TAG, or NAME (its major's newest)
  git_ -C scions/pa commit -q --allow-empty -m "a fix" && git_ add scions/pa
  fix=$(git_ -C scions/pa rev-parse HEAD)
  ran "upgrade NAME: from an untagged gitlink, the newest of its nearest release's major" G upgrade -C . pa
  expect "moved" has "graft: pa ${fix:0:12} -> v1.2.0"
  git_ -C scions/pa checkout -q --detach "$fix" && git_ add scions/pa
  ran "upgrade NAME@TAG: from an untagged gitlink" G upgrade -C . pa@v1.1.0
  expect "moved" has "graft: pa ${fix:0:12} -> v1.1.0"
  git_ reset -q && git_ submodule update -q -- scions/pa
  ran "upgrade NAME@TAG: across a major, by name" g upgrade pa@v2.0.0
  expect "moved" has "graft: pa v1.2.0 -> v2.0.0"
  git_ reset -q --hard && git_ submodule update -q -- scions/pa
  refused "upgrade: an unknown name" g upgrade nonesuch
  refused "upgrade: a tag that isn't upstream" g upgrade pa@v1.9.0
  expect "says so" holds "graft: pa: no tag v1.9.0 upstream; nothing changed"
  command mv "$work/pa.git" "$work/pa.away"
  refused "upgrade: an upstream it can't read" G upgrade -C .
  expect "says so, changing nothing" holds "graft: pa: can't tell whether"
  command mv "$work/pa.away" "$work/pa.git"
  expect "and changed nothing" git_ diff --quiet HEAD
  # a clone with no scion filled (CI): the gitlink is written into the index
  git_ clone -q "$work/cmd" "$work/cmd-ci" && cd "$work/cmd-ci"
  ran "upgrade: a scion not filled" G upgrade -C "$work/cmd-ci" docs@v1.0.0 pa@v1.1.0
  expect "moved" has "graft: pa v1.2.0 -> v1.1.0"
  refuse "quietly (no fetch progress)" grep -qE "remote:|Receiving objects|Cloning into" <<<"$out"
  expect "its gitlink written" test "$(git_ ls-files -s scions/pa | cut -d' ' -f2)" = "$(sha pa v1.1.0)"
  expect "and the folder still empty" test ! -e scions/pa/version
  commit "pa back to v1.1.0"
  ran "upgrade: Nix builds the committed gitlink" tools_out pa
  expect "v1.1.0" has "pa v1.1.0"
  git_ submodule update -q --init -- scions/pa
  expect "and a later git submodule update lands on the tag" test "$(git_ -C scions/pa describe --tags)" = v1.1.0
  cd "$work/cmd"
}

# graft's own pin: a graft repository with this tree at v9.0.0, and at v9.1.0 a scions README and a
# graft-check.yaml with one more line each; v9.0.1 is a graft without refresh.sh (v2.12's shape)
graft_repo() {
  gr=$work/graft-repo
  mkdir -p "$gr" && cp -R "$graft/." "$gr/" && rm -rf "$gr/scions"
  git_ -C "$gr" init -q && git_ -C "$gr" add -A && git_ -C "$gr" commit -qm v9.0.0 && git_ -C "$gr" tag v9.0.0
  echo "Written by graft v9.1.0." >> "$gr/lib/scions-readme.md"
  echo "# changed in v9.1.0" >> "$gr/template/.forgejo/workflows/graft-check.yaml"
  git_ -C "$gr" commit -qam v9.1.0 && git_ -C "$gr" tag v9.1.0
  git_ -C "$gr" tag v10.0.0
  git_ -C "$gr" checkout -q -b old v9.0.0 && git_ -C "$gr" rm -q lib/refresh.sh && git_ -C "$gr" commit -qm v9.0.1 \
    && git_ -C "$gr" tag v9.0.1 && git_ -C "$gr" checkout -q main
}

sec_graft() {
  graft_repo
  c=$work/self && consumer "$c" "$(printf '  inputs.self.submodules = true;\n  inputs.graft.url = "git+file://%s?ref=v9.0.0";\n  outputs = inputs: inputs.graft.lib.mkFlake { inherit inputs; };' "$gr")"
  cd "$c" && commit init
  ran "graft: add with a graft pinned by tag" g add "$(url docs)"
  mkdir -p .forgejo/workflows && cp "$gr"/template/.forgejo/workflows/*.yaml .forgejo/workflows/
  tail -n +2 "$gr/template/.forgejo/workflows/graft-upgrade.yaml" > .forgejo/workflows/graft-upgrade.yaml   # the repo's own (no marker)
  cp .forgejo/workflows/graft-upgrade.yaml "$work/mine.yaml"
  commit "docs, workflows"
  ran "graft: outdated lists graft's pin" g outdated
  expect "v9.0.0, v9.1.0 newest, v10 a major" grep -qE "^graft +- +v9.0.0 +v9.1.0 +outdated +v10.0.0$" <<<"$out"
  refused "graft: upgrade won't move graft to a version without refresh.sh" g upgrade graft@v9.0.1
  expect "says so" holds "graft: graft upgrade moves graft only to v2.13.0 or later (submodule scions); move it by hand"
  expect "and changes nothing" git_ diff --quiet
  ran "graft: under CI (not graft ci), graft itself isn't moved" env CI=true nix run .#graft upgrade
  expect "graft's pin as it was" grep -q "ref=v9.0.0" flake.nix
  # the fetch-cache guard: graft's new tag is fetched and locked through an empty fetch cache of graft's own, never
  # the person's (where a git+file: or . fetch of that commit may have left the tree without export-ignore)
  local xdg=$work/xdg-graft r91 && r91=$(git_ -C "$gr" rev-parse v9.1.0) && mkdir -p "$xdg"
  ran "graft: upgrade moves graft" env XDG_CACHE_HOME="$xdg" nix run .#graft -- upgrade
  refuse "graft: upgrade fetched and locked the new tag through an empty fetch cache, not the person's" grep -rqF "$r91" "$xdg"
  expect "says so" has "graft: graft v9.0.0 -> v9.1.0"
  expect "the ref in flake.nix" grep -q "ref=v9.1.0" flake.nix
  # shellcheck disable=SC2016 # jq's $r
  expect "re-locked" quiet jq -e --arg r "$(git_ -C "$gr" rev-parse v9.1.0)" '.nodes.graft.locked.rev == $r' flake.lock
  expect "the new version wrote its README" grep -qx "Written by graft v9.1.0." scions/README.md
  expect "and its workflow" cmp -s .forgejo/workflows/graft-check.yaml "$gr/template/.forgejo/workflows/graft-check.yaml"
  expect "a workflow without the marker untouched" cmp -s .forgejo/workflows/graft-upgrade.yaml "$work/mine.yaml"
  commit "graft v9.1.0"
  ran "graft: check passes under the new pin (its narHash is its tag's git archive's)" g check
  expect "one scion, singular" has "graft: 1 scion clean and at release tags"
  # a pin whose narHash is not its tag's git archive: what a polluted fetch cache locks, and CI then fails on with
  # NAR hash mismatch (graft's own flake: it reads the lock as data; the repo's own would fail evaluating it)
  local ei full && cp flake.lock "$work/lock-good"
  full=$(jq -r '.nodes.graft.locked.narHash' flake.lock)
  ei=$(XDG_CACHE_HOME=$(mktemp -d -p "$work") nix --option flake-registry '' flake prefetch --json "git+file://$gr?ref=v9.1.0&exportIgnore=1" 2>/dev/null | jq -r .hash)
  expect "(graft's repository export-ignores files: the two trees differ)" test -n "$ei" -a "$ei" != "$full"
  jq --arg h "$ei" '.nodes.graft.locked.narHash = $h' "$work/lock-good" > flake.lock
  refused "graft: check, a pin whose narHash is not its tag's git archive" G check -C .
  expect "names the pin and both hashes" holds "graft: flake.lock pins graft at v9.1.0 (${r91:0:7}) with narHash $ei, but its tag's git archive hashes to $full: "
  expect "the fetch cache as the likely cause" holds "Nix's fetch cache probably gave the lock a tree that another fetch of that commit left there"
  # shellcheck disable=SC2016 # the literal text
  expect "and the fix" holds 're-lock graft through an empty fetch cache: XDG_CACHE_HOME=$(mktemp -d) nix flake update graft'
  # an exportIgnore input is its tag's archive with the provider's export-ignore rules (as a github: input's is)
  jq --arg h "$ei" '.nodes.graft.locked.narHash = $h | .nodes.graft.locked.exportIgnore = true' "$work/lock-good" > flake.lock
  out=$(G check -C . 2>&1) || true
  refuse "graft: check, an exportIgnore pin at its tag's export: no narHash message" holds "narHash"
  jq '.nodes.graft.locked.exportIgnore = true' "$work/lock-good" > flake.lock
  refused "graft: check, an exportIgnore pin holding the whole tree" G check -C .
  expect "names it" holds "graft: flake.lock pins graft at v9.1.0 (${r91:0:7}) with narHash $full, but its tag's git archive hashes to $ei: "
  # an upstream it can't fetch: a note, not a failure of its own
  command mv "$gr" "$gr.away"
  out=$(G check -C . 2>&1) || true
  command mv "$gr.away" "$gr"
  expect "graft: check, a pin it can't fetch: says so" holds "graft: can't fetch graft's v9.1.0 from file://$gr"
  refuse "and fails nothing on it" holds "with narHash"
  cp "$work/lock-good" flake.lock
  # v2.12's upgrade, moving its graft to this version, runs this version's lib/assemble.sh: a stub
  refused "graft: lib/assemble.sh (what a v2.12 upgrade runs) stops it" bash "$graft/lib/assemble.sh" out scions x=y=z
  expect "naming the Upgrading steps" holds "graft v2.13.0 replaced copied scions with git submodules"
}

# lib/workflows.sh on its own: the lines graft keeps (paths-ignore, branches, # graft ssh:)
sec_workflows() {
  local tw=$graft/template/.forgejo/workflows wr=$work/wf-repo wx=$work/wf-examples wf
  mkdir -p "$wr/.forgejo/workflows" "$wx"
  wf=$wr/.forgejo/workflows/graft-check.yaml
  cp "$tw/graft-check.yaml" "$wf"
  pi_on() { grep -A7 '^on:' "$1"; }
  pi_want=$(printf '%s\n' 'on:' '  pull_request:' '    paths-ignore: ["notebook/**", "drafts/**"]' '  push:' \
    '    branches: [main]' '    paths-ignore: ["notebook/**", "drafts/**"]' '' 'concurrency:')
  sed -i "s|^    branches: \[main\]$|&\n    paths-ignore: [ 'notebook/**',\"drafts/**\" ]|" "$wf"
  refused "workflows: paths-ignore under push alone fails the check" bash "$graft/lib/workflows.sh" check "$wr" "$tw"
  quiet bash "$graft/lib/workflows.sh" refresh "$wr" "$tw" || fail "workflows.sh refresh, paths-ignore"
  expect "workflows: refresh writes it under both triggers, in graft's form" test "$(pi_on "$wf")" = "$pi_want"
  expect "workflows: the rest is graft's copy" cmp -s <(grep -v '^    paths-ignore: ' "$wf") "$tw/graft-check.yaml"
  expect "workflows: then the check passes" quiet bash "$graft/lib/workflows.sh" check "$wr" "$tw"
  expect "workflows: YAML that means it" \
    test "$(nix run "$np#yq-go" -- -o=json -I=0 '[.on.push["paths-ignore"], .on.pull_request["paths-ignore"], .on.push.branches]' "$wf")" \
    = '[["notebook/**","drafts/**"],["notebook/**","drafts/**"],["main"]]'
  cp "$wf" "$work/wf-good"
  pi_glob() { sed "s|\"drafts/\*\*\"|\"$1\"|g" "$work/wf-good" > "$wf"; }
  for glob in 'scions/**' 'sc?ons/x.md' 'scions' 'flake.lock' 'flake.*' '?forgejo/**' '.gitmodules' '.gitm*'; do
    pi_glob "$glob"
    refused "workflows: paths-ignore \"$glob\" fails" bash "$graft/lib/workflows.sh" check "$wr" "$tw" "nix run .#graft" . scions
    expect "and says what it could match" holds "paths-ignore glob \"$glob\" could match"
  done
  pi_glob 'scionsx/**'
  expect "workflows: paths-ignore \"scionsx/**\" is fine" quiet bash "$graft/lib/workflows.sh" check "$wr" "$tw" "nix run .#graft" . scions
  pi_glob 'nix/tools/.scions/**'
  refused "workflows: a subdirectory flake's scions directory is protected" bash "$graft/lib/workflows.sh" check "$wr" "$tw" "nix run .#graft" nix/tools nix/tools/.scions
  cp "$work/wf-good" "$wf"
  sed -i 's|^\(    paths-ignore: .*\)$|\1  # the bot|' "$wf"
  refused "workflows: a comment on the line fails" bash "$graft/lib/workflows.sh" check "$wr" "$tw"
  expect "and says so" holds "no comment after it"
  # branches: the repo's own
  cp "$tw/graft-check.yaml" "$wf" && sed -i 's|^    branches: \[main\]$|    branches: ["v2", release/1.x]|' "$wf"
  quiet bash "$graft/lib/workflows.sh" refresh "$wr" "$tw" || fail "workflows.sh refresh, branches"
  expect "workflows: branches kept, in graft's form" grep -qx '    branches: \[v2, release/1.x\]' "$wf"
  expect "workflows: and the check passes" quiet bash "$graft/lib/workflows.sh" check "$wr" "$tw"
  # # graft ssh: a step before each step that runs graft, in both workflows (a made-up host key)
  hk='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGraftTestHostKeyNotARealOne+/0123456789abcdefgh'
  sshl="# graft ssh: host=[git.example]:2222 address=192.0.2.7 hostkey=$hk"
  cp "$tw/graft-check.yaml" "$wf" && echo "$sshl" >> "$wf"
  cp "$tw/graft-upgrade.yaml" "$wr/.forgejo/workflows/" && echo "$sshl" >> "$wr/.forgejo/workflows/graft-upgrade.yaml"
  refused "workflows: ssh: a line whose step isn't written fails the check" bash "$graft/lib/workflows.sh" check "$wr" "$tw"
  quiet bash "$graft/lib/workflows.sh" refresh "$wr" "$tw" || fail "workflows.sh refresh, ssh"
  expect "workflows: ssh: the line kept above name:" test "$(grep -B1 '^name: graft-check$' "$wf" | head -1)" = "$sshl"
  expect "workflows: ssh: then the check passes" quiet bash "$graft/lib/workflows.sh" check "$wr" "$tw"
  steps=$(nix run "$np#yq-go" -- -o=json -I=0 '[.jobs.scions.steps[] | .name]' "$wf")
  expect "workflows: ssh: graft-check: the key before the check" test "$steps" = '["Checkout","SSH key for private scions","Scions registered and at release tags"]'
  steps=$(nix run "$np#yq-go" -- -o=json -I=0 '[.jobs[].steps[] | .name]' "$wr/.forgejo/workflows/graft-upgrade.yaml")
  expect "workflows: ssh: graft-upgrade: the key before the upgrade and the PR" \
    test "$steps" = '["Checkout the default branch","SSH key for private scions","Upgrade, check the result, push it to graft/upgrade","Checkout the default branch","SSH key for private scions","Open (or update) the PR"]'
  srun=$(nix run "$np#yq-go" -- '.jobs.scions.steps[1].run' "$wf")
  expect "workflows: ssh: known_hosts under the host and its address" grep -qxF "echo '[git.example]:2222,[192.0.2.7]:2222 $hk' >> ~/.ssh/known_hosts" <<<"$srun"
  sk=$work/ssh-home && mkdir -p "$sk"
  expect "workflows: ssh: the step writes the key and config" env HOME="$sk" GRAFT_SSH_KEY="not a real key" GITHUB_PATH="$sk/path" bash -c "$srun"
  expect "workflows: ssh: (the key)" test "$(cat "$sk/.ssh/graft_scions")" = "not a real key"
  refused "workflows: ssh: an empty secret fails the step" env HOME="$sk" GRAFT_SSH_KEY= GITHUB_PATH="$sk/path" bash -c "$srun"
  for bad in "host=git.example" "host=git'x hostkey=$hk" "host=git.example hostkey=$hk extra"; do
    cp "$tw/graft-check.yaml" "$wf" && echo "# graft ssh: $bad" >> "$wf"
    refused "workflows: ssh: \"$bad\" fails" bash "$graft/lib/workflows.sh" refresh "$wr" "$tw"
    expect "and says how to write it" holds '# graft ssh: host=[HOST]:PORT'
  done
  # the workflows' own search for the flake (bash and git only, as in the nixos/nix image)
  fb=$work/flake-block.sh
  # shellcheck disable=SC2016 # a line of the script, expanded when it runs
  { awk '/# graft.s flake: beside the scions directory/ { buf = ""; on = 1 } on && /nix run "\$flake#graft"/ { on = 0; last = buf; next }
         on { sub(/^ +/, ""); buf = buf $0 "\n" } END { printf "%s", last }' "$tw/graft-upgrade.yaml"
    echo 'echo "$flake"'; } > "$fb"
  fr=$work/flake-find && mkdir -p "$fr" && git_ -C "$fr" init -q
  fbin=$work/flake-bin && mkdir -p "$fbin" && ln -sf "$(command -v git)" "$fbin/git"
  fbrun() { (cd "$fr" && git_ add -A && env PATH="$fbin" "$(command -v bash)" -e "$fb" 2>&1); }
  expect "workflows: flake step: no scions yet: the top" test "$(fbrun)" = .
  mkdir -p "$fr/scions" && cp "$graft/lib/scions-readme.md" "$fr/scions/README.md"
  expect "workflows: flake step: scions at the top" test "$(fbrun)" = .
  git_ -C "$fr" rm -rqf scions && mkdir -p "$fr/nix/tools/.scions" && cp "$graft/lib/scions-readme.md" "$fr/nix/tools/.scions/README.md"
  expect "workflows: flake step: a subdirectory flake, as path:" test "$(fbrun)" = "path:$fr/nix/tools"
  mkdir -p "$fr/other" && cp "$graft/lib/scions-readme.md" "$fr/other/README.md"
  refused "workflows: flake step: two scions directories fail" fbrun
  expect "and say so" holds "::error::two scions directories:"
}

# graft ci pr against a stub API. stub_pr NAME [LISTING [STATUSES]]: run `graft ci pr` in the current
# repo against a fresh stub (GET answers LISTING; STATUSES, JSON, the HTTP status to answer each
# method with), with output in $work/NAME.out, its exit code in $work/NAME.rc, the request log in
# $work/NAME.auth and the requests in $work/NAME.req
stub_pr() {
  local port=$work/$1.port rc=0 stub
  rm -f "$port"
  nix run "$np#python3" -- "$src/tests/stub-api.py" "$port" "$work/$1.auth" "$work/$1.req" "${2:-/nonexistent}" ${3:+"$3"} & stub=$!
  for _ in $(seq 100); do [ -s "$port" ] && break; sleep 0.1; done
  ci_ API="http://127.0.0.1:$(cat "$port")" WEB=x BASE=main BRANCH=graft/upgrade PR_TOKEN=s3cret \
    pr > "$work/$1.out" 2>&1 || rc=$?
  echo "$rc" > "$work/$1.rc"
  kill "$stub" 2>/dev/null || true
}
post_body() { jq -r 'select(.method=="POST") | .body.body' "$work/$1.req"; }

# gate NAME WANT: a consumer of pa at v1.1.0 whose own check wants pa's version to be WANT, pushed to
# its origin (NAME.git) and cloned fresh (no scion filled, as in CI) to $work/NAME-ci
gate() {
  local d=$work/$1
  consumer "$d" "$(cat <<EOF
  inputs.self.submodules = true;
  inputs.graft.url = "path:$graft";
  outputs = inputs: inputs.graft.lib.mkFlake {
    inherit inputs;
    perSystem = { pkgs, scions, ... }: {
      checks.pa-version = pkgs.runCommand "pa-version" { } ''
        grep -qx "\$(cat \${inputs.self}/want)" \${scions.pa}/version \\
          || { echo "pa-version: expected \$(cat \${inputs.self}/want), got \$(cat \${scions.pa}/version)" >&2; exit 1; }
        touch \$out
      '';
    };
  };
EOF
)"
  cd "$d"
  printf '%s\n' "$2" > want
  mkdir -p .forgejo/workflows && cp "$graft"/template/.forgejo/workflows/*.yaml .forgejo/workflows/
  commit init && quiet g add "$(url pa)@v1.1.0" && commit "pa" && quiet nix flake lock && commit lock
  git_ init -q --bare "$work/$1.git" && git_ remote add origin "$work/$1.git" && git_ push -q origin main
  git_ clone -q "$work/$1.git" "$work/$1-ci" && cd "$work/$1-ci"
}

sec_ci() {
  gate gate-ok v1.2.0
  ran "ci check: passes on a fresh clone (no scion filled)" ci_ check
  expect "says so" has "graft: ci check passed: flake.lock is committed, every scion is at a release tag, graft's workflows are current, and the flake evaluates"
  refused "ci upgrade: refuses without BRANCH" ci_ upgrade
  expect "says so" has "graft: BRANCH is not set: name the branch to push the upgrade to (graft's workflow sets BRANCH=graft/upgrade)"
  refused "ci upgrade: refuses to commit on the default branch" ci_ BRANCH=graft/upgrade upgrade
  expect "says so" has "graft: ci upgrade commits on the branch checked out, main, and pushes it to graft/upgrade: switch to a new branch graft/upgrade first (git switch -c graft/upgrade)"
  git_ checkout -q -b graft/upgrade
  echo "SECRET=x" > .env.local
  refused "ci upgrade: refuses an untracked file" ci_ BRANCH=graft/upgrade upgrade
  expect "says why" has "graft: ci upgrade commits every change in the working tree, and this one has the changes of its own above: commit, stash or remove them first"
  rm -f .env.local
  # C1: the check after the upgrade sees the NEW scion (committed first, then checked)
  ran "ci upgrade: moves pa and checks the result" ci_ GITHUB_OUTPUT="$work/ci-out" BRANCH=graft/upgrade upgrade
  expect "changed=true" grep -qx changed=true "$work/ci-out"
  expect "the check saw the new version (its own check wants v1.2.0)" has "graft: checks.$sys.pa-version"
  refuse "and nothing failed" holds "::error::"
  body=$(git_ -C "$work/gate-ok.git" log -1 --format=%b graft/upgrade)
  expect "pushed, its commit naming the move" grep -qx "graft: pa v1.1.0 -> v1.2.0" <<<"$body"
  expect "the gitlink pushed" test "$(git_ -C "$work/gate-ok.git" ls-tree graft/upgrade scions/pa | awk '{ print $3 }')" = "$(sha pa v1.2.0)"
  : > "$work/ci-out"
  ran "ci upgrade: again, nothing to do" ci_ GITHUB_OUTPUT="$work/ci-out" BRANCH=graft/upgrade upgrade
  expect "changed=false" grep -qx changed=false "$work/ci-out"
  git_ checkout -q main
  stub_pr pr1
  expect "ci pr: opens the PR for a branch that only moves a gitlink" grep -q "http://stub/pulls/1" "$work/pr1.out"
  expect "with the token in a header" grep -qx "POST token s3cret" "$work/pr1.auth"
  out=$(post_body pr1)
  expect "the body lists the move" has "- pa v1.1.0 -> v1.2.0"
  expect "and the major not taken" holds "- pa: v2.0.0 is a new major version"
  expect "and that the check passed" holds "whole \`nix flake check\` passed"
  expect "and what changed upstream" has "### pa v1.1.0 -> v1.2.0"
  expect "its commits (no CHANGELOG at v1.2.0)" grep -q "^> - [0-9a-f]* v1.2.0$" <<<"$out"
  # what ci pr refuses: a .gitmodules change, a workflow change; the README only when graft moved
  push_branch() { git_ push -q --force origin HEAD:refs/heads/graft/upgrade && git_ checkout -q main; }
  git_ fetch -q origin
  git_ checkout -q -b x1 origin/graft/upgrade && git_ config -f .gitmodules submodule.scions/pa.url "file://$work/elsewhere.git" && commit swap && push_branch
  stub_pr pr2
  expect "ci pr: a .gitmodules change: refused" grep -qx 1 "$work/pr2.rc"
  expect "says so" grep -q "changes files graft upgrade never writes: .gitmodules" "$work/pr2.out"
  git_ checkout -q -b x2 origin/main && echo "# x" >> .forgejo/workflows/graft-check.yaml && commit wf && push_branch
  stub_pr pr3
  expect "ci pr: a workflow change: refused" grep -q "changes CI workflows" "$work/pr3.out"
  git_ checkout -q -b x3 origin/main && echo "x" >> scions/README.md && commit readme && push_branch
  stub_pr pr4
  expect "ci pr: the README without graft moving: refused" grep -q "changes files graft upgrade never writes: scions/README.md" "$work/pr4.out"
  # shellcheck disable=SC2016 # a jq program
  git_ checkout -q -b x4 origin/main && echo "x" >> scions/README.md \
    && jq '.nodes.graft.locked.narHash = "sha256-moved"' flake.lock > "$work/lock" && cp "$work/lock" flake.lock && commit "graft moved" && push_branch
  stub_pr pr5
  expect "ci pr: the README when graft's pin moved: opened" grep -q "http://stub/pulls/1" "$work/pr5.out"

  # a check the upgrade breaks: the branch is still pushed, the step fails, the PR says why
  gate gate-bad v1.1.0
  git_ checkout -q -b graft/upgrade
  refused "ci upgrade: fails when the repo's own check fails" ci_ GITHUB_OUTPUT="$work/bad-out" BRANCH=graft/upgrade upgrade
  expect "but says it changed" grep -qx changed=true "$work/bad-out"
  body=$(git_ -C "$work/gate-bad.git" log -1 --format=%b graft/upgrade)
  expect "its commit names the failing check" grep -qx "nix flake check failed: pa-version" <<<"$body"
  expect "with its log's tail (the new version, seen)" grep -q "pa-version: expected v1.1.0, got v1.2.0" <<<"$body"
  expect "and still the move" grep -qx "graft: pa v1.1.0 -> v1.2.0" <<<"$body"
  git_ checkout -q main
  stub_pr bad1
  expect "the PR titled as failing" quiet jq -e 'select(.method=="POST") | .body.title == "[checks failing] graft: upgrade"' "$work/bad1.req"
  stub_pr http1 /nonexistent '{"GET": 500}'
  expect "ci pr: listing PRs fails: the step fails" grep -qxF "::error::listing PRs: HTTP 500" "$work/http1.out"

  # a lock never committed
  cd "$work/gate-ok-ci" && git_ rm -q --cached flake.lock && git_ commit -qm "no lock"
  git_ clone -q "$work/gate-ok-ci" "$work/nolock" && cd "$work/nolock"
  refused "ci check: a flake.lock never committed" nix run .#graft -- ci check
  expect "says so" holds "graft: flake.lock is not committed, so nothing is pinned"

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
  expect "counts the push" has "graft: signers: 5 commit(s) on refs/heads/main, 3 finding(s) (report-only)"
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
  expect "passes (for now)" has "graft: signers: tag v1, 0 finding(s) (the signers file is the pushed one's: no SIGNERS_REF) (report-only)"
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
  expect "is reported, not an error" holds "::warning::graft signers: no .forgejo/allowed_signers at"
}

sec_migrate() {
  cd "$work/cmd"
  printf '%s\n' "the policy: scions/pa/docs/policy.md" "old: scions/pa/docs/old/x.md and [dir](scions/pa/docs/old/)" > notes.md
  commit "notes"
  ran "migrate: nothing moved on the base" g migrate --base main --no-check
  expect "says so" holds "graft migrate: nothing moved since"
  git_ checkout -q -b mig
  quiet g upgrade pa@v2.0.0 && commit "pa v2.0.0"
  ran "migrate: a brief for an upgraded branch" g migrate --base main --no-check
  expect "what moved" has "Migrate this repo (cmd) to pa v2.0.0 (from v1.2.0)."
  expect "what upstream says, Upgrading first" has "Upgrading, from its CHANGELOG.md:"
  expect "renames" has "    R  scions/pa/docs/policy.md -> scions/pa/docs/rules.md"
  expect "deletions" has "    D  scions/pa/docs/old/x.md"
  expect "references to a renamed path" has "    notes.md:1  scions/pa/docs/policy.md  (renamed to scions/pa/docs/rules.md)"
  expect "to a deleted one" has "    notes.md:2  scions/pa/docs/old/x.md  (deleted)"
  expect "to a directory gone" has "    notes.md:2  scions/pa/docs/old/  (directory gone)"
  expect "checks not run" holds "Not run (--no-check)"
  out=$(g migrate --base main --no-check --json 2>/dev/null) || fail "migrate --json"
  expect "fields" quiet jq -e '.moved[0].name == "pa" and .moved[0].kind == "scion" and .moved[0].from == "v1.2.0" and .moved[0].to == "v2.0.0" and (.references | length) == 3 and .scion_dirs == ["scions"]' <<<"$out"
  ran "migrate -C from graft's flake" G migrate -C "$work/cmd" --base main --no-check
  expect "the same brief" has "Migrate this repo (cmd) to pa v2.0.0 (from v1.2.0)."
  ran "migrate: with the checks" g migrate --base main
  expect "they pass" holds "passes as the branch stands"
  git_ checkout -q main && git_ submodule update -q -- scions/pa
}

sec_try() {
  # tp: a tool that prints the scion's version, and its `extra` file when it has one
  prov tp
  cat > "$work/src/tp/graft.nix" <<'EOF'
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
  by_hand tp && by_hand tn && git_ -C scions/tn submodule update -q --init --recursive
  commit init && quiet nix flake lock && commit lock
  local v1 && v1=$(sha tp v1.0.0 | cut -c1-7)
  git_ -C scions/tp switch -q -c fix
  printf 'edited' > scions/tp/version && printf 'extra' > scions/tp/extra
  ran "try: off, a build ignores a scion's edit and new file" tools_out tp
  expect "builds the gitlink" has "tp v1.0.0"
  refused "try: an unknown scion" G try -C . nope
  expect "says so" has "graft: no scion named nope"
  expect "and changes nothing" test ! -e .graft-try
  refused "try: from inside a scion" G try -C scions/tp
  expect "says to run it from the top" has "graft: $(pwd -P)/scions/tp is a submodule of $(pwd -P): run graft from the repository's top (-C $(pwd -P))"
  ran "try: on (from graft's flake: the repo's flake need not evaluate)" G try -C .
  expect "says so" has "graft: try is on: Nix builds of this repository read its working tree, and its scions' (.graft-try marks it)"
  expect "what Nix builds of each scion" has "graft: scions/tp: branch fix at v1.0.0 ($v1), as recorded: 1 modified, 1 new Nix doesn't see"
  expect "how to make Nix see the new file: stage it for real" has "graft: scions/tp: Nix sees a new file only once git tracks it: git -C scions/tp add -- extra"
  expect "the build command for a flake at the top" has "graft: build from the repository's top: nix build .#tools, nix shell .#tools -c TOOL, or nix flake check"
  refuse "never path: at the top" holds "path:"
  expect "the marker, marked with intent to add" test "$(git_ status --porcelain --untracked-files=no -- .graft-try)" = " A .graft-try"
  expect "the scion's index untouched" test "$(git_ -C scions/tp status --porcelain)" = "$(printf ' M version\n?? extra')"
  expect "the scion's HEAD unmoved" test "$(git_ -C scions/tp rev-parse HEAD)" = "$(sha tp v1.0.0)"
  ran "try: on, a build sees the edit, not the untracked file" tools_out tp
  expect "the edit" has "tp edited"
  git_ -C scions/tp add -- extra
  ran "try: the new file once staged" tools_out tp
  expect "both" has "tp edited extra"
  ran "try: again (idempotent)" G try -C .
  expect "counts it as new" has "graft: scions/tp: branch fix at v1.0.0 ($v1), as recorded: 1 modified, 1 new"
  # discarding in the scion loses nothing graft did: graft never touched its index
  git_ -C scions/tp reset -q -- extra && printf 'precious' > scions/tp/extra2
  git_ -C scions/tp checkout -q -- .
  expect "try: git checkout -- . in a scion keeps the new files" test "$(cat scions/tp/extra)$(cat scions/tp/extra2)" = "extraprecious"
  git_ -C scions/tp reset -q --hard
  expect "and so does reset --hard" test "$(cat scions/tp/extra)$(cat scions/tp/extra2)" = "extraprecious"
  rm scions/tp/extra2 && printf 'edited' > scions/tp/version
  # a scion's own submodule: its new files are reported too
  echo new > scions/tn/sub/docs/new.md
  ran "try: a new file in a scion's own submodule" G try -C .
  expect "counted" has "graft: scions/tn: detached at v1.0.0 ($(sha tn v1.0.0 | cut -c1-7)), as recorded: 1 new Nix doesn't see"
  expect "with its command" has "graft: scions/tn/sub/docs: Nix sees a new file only once git tracks it: git -C scions/tn/sub/docs add -- new.md"
  ran "try NAME: the commands for the named scions only" G try -C . tp
  refuse "not another's" holds "git -C scions/tn/sub/docs add"
  rm scions/tn/sub/docs/new.md
  refused "try: graft check refuses while it is on" g check
  expect "names graft try --stop" has "graft: graft try is on (.graft-try): Nix builds read the working tree, scions included: graft try --stop turns it off"
  expect "and the scion's edits are used" has "graft: uncommitted edits in scions/tp: version (graft try is on: Nix builds use them)"
  refused "try: check --committed refuses too" G check -C . --committed
  expect "the same" has "graft: graft try is on (.graft-try): Nix builds read the working tree, scions included: graft try --stop turns it off"
  refused "try: ci check refuses too" ci_ check
  expect "the same" holds "graft try --stop turns it off"
  refused "try: upgrade refuses" G upgrade -C . tp
  expect "says why" has "graft: graft try is on; nothing changed: graft try --stop first"
  ran "try: sync runs, and says try is on" g sync
  expect "a note" has "graft: note: graft try is on: graft try --stop turns it off before you commit"
  git_ add scions/README.md && git_ commit -qm "sync's README" -- scions/README.md
  # a parent reset leaves the marker untracked: Nix no longer reads the working tree
  git_ reset -q
  refused "try: check after a parent reset" G check -C .
  expect "doesn't claim try is on" has "graft: .graft-try is left from graft try but untracked, so Nix builds read the recorded scions: graft try --stop removes it, or graft try turns try on again"
  ran "try: again after the reset" G try -C .
  expect "is on again" test "$(git_ status --porcelain --untracked-files=no -- .graft-try)" = " A .graft-try"
  ran "try --stop" G try -C . --stop
  expect "says so" has "graft: try is off: Nix builds the recorded scions while the tree is clean"
  expect "the marker gone" test ! -e .graft-try
  expect "and out of the index" test -z "$(git_ ls-files -- .graft-try)"
  expect "the scion untouched" test "$(git_ -C scions/tp status --porcelain)" = "$(printf ' M version\n?? extra')"
  expect "says the scion stays as it is" has "graft: scions/tp stays as you left it: git submodule update --recursive -- scions/tp goes back to its pin (commit or stash its edits first)"
  ran "try: off again, a build ignores them" tools_out tp
  expect "the gitlink's" has "tp v1.0.0"
  ran "try --stop again (idempotent)" G try -C . --stop
  expect "nothing to undo" has "graft: try is not on; nothing to undo"
  # the marker committed (git add -A, then commit)
  quiet G try -C .
  git_ -C scions/tp add -A && git_ -C scions/tp commit -qm "the fix" && git_ add -A && git_ commit -qm "the marker by mistake"
  refused "try: check --committed fails on a committed marker" G check -C . --committed
  expect "says so" has "graft: .graft-try is committed (graft try's marker): graft try --stop, then commit its removal"
  refused "try: refuses while the marker is committed (Nix would read the gitlinks)" G try -C .
  expect "says how to remove it" has "graft: .graft-try is committed, so the tree is clean to Nix; nothing changed: graft try --stop, commit its removal, then graft try"
  ran "try --stop after commits" G try -C . --stop
  expect "the scion's commit left as it is" quiet git_ -C scions/tp cat-file -e HEAD:extra
  expect "the marker's removal staged" test "$(git_ status --porcelain -- .graft-try)" = "D  .graft-try"
  expect "says to commit it" has "graft: .graft-try was committed: its removal is staged; commit it"
  # try again before that commit: refuse with advice that ends the loop, and change nothing (QA R1)
  refused "try: refuses while the marker's removal is staged but not committed" G try -C .
  expect "says to commit the removal" has "graft: .graft-try is committed and its removal is staged; nothing changed: commit the removal (git commit -m 'Remove graft try marker'), then graft try"
  expect "the index unchanged" test "$(git_ status --porcelain -- .graft-try)" = "D  .graft-try"
  git_ commit -qm "no marker"
  git_ -C scions/tp checkout -q --detach v1.0.0 && git_ add scions/tp && commit "back to v1.0.0"
  # works while the repo's flake can't evaluate
  echo '{' >> flake.nix
  ran "try: on while flake.nix doesn't parse" G try -C .
  expect "reports" has "graft: scions/tp: detached at v1.0.0 ($v1), as recorded: no edits"
  quiet G try -C . --stop && git_ checkout -q -- flake.nix
  # an empty scion: Nix fails on it while try is on
  git_ submodule deinit -q -f scions/tp
  refused "try: refuses an empty scion" G try -C .
  expect "says how to fill it" has "graft: scions/tp is empty, and Nix fails on an empty scion while try is on; nothing changed: git submodule update --init --recursive -- scions/tp (or graft sync)"
  expect "nothing changed" test ! -e .graft-try
  git_ submodule update -q --init -- scions/tp
  # a path: flake in a subdirectory reads its working tree always: nothing to turn on
  local s=$work/try-sub && mkdir -p "$s/nix/tools" && git_ -C "$s" init -q
  printf '{\n  inputs.graft.url = "path:%s";\n  outputs = inputs: inputs.graft.lib.mkFlake { inherit inputs; dir = ".scions"; };\n}\n' "$graft" > "$s/nix/tools/flake.nix"
  quiet G add -C "$s" --scions nix/tools/.scions "$(url tp)" && git_ -C "$s" add -A && git_ -C "$s" commit -qm sub
  printf 'edited' > "$s/nix/tools/.scions/tp/version" && printf 'extra' > "$s/nix/tools/.scions/tp/extra"
  ran "try: a path: flake" G try -C "$s"
  expect "says there is nothing to turn on" has "graft: nix/tools is a path: flake: every build reads its working tree, scions and new files included; try has nothing to turn on"
  expect "what it builds" has "graft: nix/tools/.scions/tp: detached at v1.0.0 ($v1), as recorded: 1 modified, 1 new"
  expect "its build command" has "graft: build from the repository's top: nix build 'path:nix/tools#tools', nix shell 'path:nix/tools#tools' -c TOOL, or nix flake check 'path:nix/tools'"
  expect "no marker" test ! -e "$s/.graft-try"
  refused "try: check in a path: flake" G check -C "$s"
  expect "says builds use the edits" has "graft: uncommitted edits in nix/tools/.scions/tp: version (a path: flake's builds use them)"
  ran "try --stop: a path: flake" G try -C "$s" --stop
  expect "nothing to undo" has "graft: try is not on; nothing to undo"
}

sec_tarball() {
  # graft as github: fetches it: a tarball, no submodules. Its command must not need its scions.
  local t=$work/graft-src
  mkdir -p "$t" && cp -R "$graft/." "$t/" && rm -rf "$t/.git" && find "$t/scions" -mindepth 2 -maxdepth 2 -exec rm -rf {} +
  tar -C "$work" -czf "$work/graft.tar.gz" graft-src
  ran "tarball: graft's command runs from a tarball of graft (no submodules)" nix run "tarball+file://$work/graft.tar.gz" -- help
  expect "its usage" holds "usage:"
  # a consumer taking graft as a tarball input (as github: fetches it): lock, evaluate, its own app
  local c=$work/tarball-consumer
  consumer "$c" "$(printf '  inputs.self.submodules = true;\n  inputs.graft.url = "tarball+file://%s";\n  outputs = inputs: inputs.graft.lib.mkFlake { inherit inputs; };' "$work/graft.tar.gz")"
  cd "$c" && by_hand kb && commit init
  ran "tarball: a consumer locks graft as a tarball input" nix flake lock
  commit lock
  ran "tarball: and builds its tools" tools_out kb-lint
  ran "tarball: and runs its own graft" g check
  expect "which passes" has "graft: 1 scion clean and at release tags"
}

# kits: mkFlake's side of the seam with pot (option A): a consumer that takes pot as an input of its own
# (inputs.pot) gets packages.<system>.pot-kits from pot.lib.pot.kitsFor (contract pot-lib/1), wrapped tools and
# kits.just; one without it gets none of them, and a warning when a unit declares a kit. pot here is the test input
# dev/flake.nix pins (pot_src). pot's own half (a kit's messages, the bundle's checks) is tested in pot.
pot_src() { nix flake archive --json "$src/dev" | jq -er '.inputs.pot.path'; }
sec_kits() {
  local pot && pot=$(pot_src) || fail "kits: dev/flake.nix has no pot input"
  # kk: a scion kit (protect, requests, a command, a recipe) that reads kitArgs; kkold: v2.14.0's `sandbox`
  prov kk
  cat > "$work/src/kk/graft.nix" <<'EOF'
{ pkgs, kitArgs ? { }, ... }:
let tool = pkgs.writeShellScriptBin "kk-tool" "echo kk-tool ${kitArgs.word or "none"}"; in
{
  tools.kk-tool = tool;
  kit = {
    protect = [ "kk.yaml" ];
    requests.network = [ "api.kk.example" ];
    commands.kk-tool.program = "${tool}/bin/kk-tool";
    recipes.kk = { run = "kk-tool"; description = "Run kk"; };
  };
}
EOF
  release kk v1.0.0
  prov kkold
  printf '{ ... }: { sandbox.packages = [ ]; }\n' > "$work/src/kkold/graft.nix" && release kkold v1.0.0
  prov kkapp
  printf '{ ... }: { apps.pot = { type = "app"; program = "/bin/sh"; }; }\n' > "$work/src/kkapp/graft.nix" && release kkapp v1.0.0

  local c=$work/kc && consumer "$c" "$(printf '  inputs.self.submodules = true;\n  inputs.graft.url = "path:%s";\n  inputs.pot.url = "path:%s";\n  outputs = inputs: inputs.graft.lib.mkFlake { inherit inputs; perSystem = { pkgs, ... }: { kitArgs.kk.word = "hi"; kit = { protect = [ "AGENTS.md" ]; tools = [ pkgs.hello ]; }; }; };' "$graft" "$pot")" && cd "$c"
  echo "# agents" > AGENTS.md && echo "a: 1" > kk.yaml && printf 'import? "scions/kits.just"\n' > justfile
  by_hand kk && commit init && quiet nix flake lock && commit lock

  ran "kits: pot-kits builds, through the consumer's inputs.pot" nix build -o "$work/kpk" ".#pot-kits"
  ran "its kit.json" jq -c . "$work/kpk/kit.json"
  expect "is pot-kits/1: version, self, scions, protect" test "$(jq -c 'keys' "$work/kpk/kit.json")" = '["protect","scions","self","version"]'
  expect "holds the repo kit, with its file" holds '"self":{"file":"flake.nix (perSystem)","protect":["AGENTS.md"],"tools":["/nix/store/'
  expect "and the scion kit, handed through unread" holds '"kk":{"commands":{"kk-tool":{"program":"/nix/store/'
  expect "naming its provider file" holds '"file":"scions/kk/graft.nix"'
  expect "pot protects every provider file, by either name, and the scions folder" holds '"protect":["**/tuteur.nix","**/gr@ft.nix","scions"]'
  expect "its tools hold the repository's graft" test -x "$work/kpk/bin/graft"
  expect "and the repo kit's tools" test -x "$work/kpk/bin/hello"
  ran "kits: kitArgs reaches the provider" "$(jq -r '.scions.kk.commands["kk-tool"].program' "$work/kpk/kit.json")"
  expect "its value" has "kk-tool hi"
  ran "kits: the tools" nix build -o "$work/kt" .#tools
  expect "hold the command's wrapper (pot runs kit code under its own policy)" test "$(readlink -f "$work/kt/bin/kk-tool")" = "$(readlink -f "$work/kpk/wrappers/bin/kk-tool")"
  ran "kits: tools.passthru.unwrapped" nix build -o "$work/ktu" .#tools.passthru.unwrapped
  expect "holds the program itself" test "$(readlink -f "$work/ktu/bin/kk-tool")" = "$(jq -r '.scions.kk.commands["kk-tool"].program' "$work/kpk/kit.json")"
  # kits.just: pot-lib/1's passthru.kitsJust, written by sync and add, compared by check, where the justfile imports it
  ran "kits: sync writes kits.just" g sync
  expect "says so" holds "graft: wrote scions/kits.just"
  ran "kits: pot-kits' kitsJust" nix eval --raw ".#packages.$sys.pot-kits.kitsJust"
  expect "the same bytes" test "$(cat scions/kits.just)" = "$out"
  expect "the kit's recipe" grep -qF 'exec "{{tools}}/bin/kk-tool"' scions/kits.just
  expect "and graft's own" grep -qF 'exec "{{tools}}/bin/graft" '"'"'outdated'"'"' "$@"' scions/kits.just
  commit kitsjust
  ran "kits: check, kits.just current" g check
  echo "# edited" >> scions/kits.just
  refused "kits: check, kits.just edited" g check
  expect "names the fix" holds "graft: scions/kits.just is stale or edited: graft sync"
  git_ checkout -q scions/kits.just
  printf 'import? "scions/kits.just"\n\nkk:\n    echo mine\n' > justfile && commit own-kk
  refused "kits: check, a kit recipe named like the justfile's own" g check
  expect "names both" holds "graft: scions/kits.just's recipe kk has the name of the justfile's own kk: rename one (a kit's recipe never replaces yours)"
  printf 'import? "scions/kits.just"\n' > justfile && commit no-own-kk
  echo keep > "$work/klinktarget" && cp scions/kits.just "$work/kkj" && ln -sfn "$work/klinktarget" scions/kits.just
  refused "kits: sync, kits.just a link" g sync
  expect "is refused" holds "graft: scions/kits.just is a symbolic link; graft writes only a file there"
  expect "its target untouched" test "$(cat "$work/klinktarget")" = keep
  rm -f scions/kits.just && cp "$work/kkj" scions/kits.just
  prov kkq && release kkq v1.0.0
  git_ rm -q --cached scions/kits.just && rm -f scions/kits.just
  ran "kits: add writes kits.just too" g add "$(url kkq)"
  expect "says so" holds "graft: wrote scions/kits.just"
  commit kkq
  # the errors and reserved names, as a consumer's build shows them
  refused "kits: mkFlake writes no graft-kits" nix eval --raw ".#packages.$sys.graft-kits.drvPath"
  by_hand kkold && commit kkold
  refused "kits: a provider's sandbox" nix build --no-link .#pot-kits
  expect "names kit" holds "graft: scions/kkold/graft.nix gives \`sandbox\`: graft v2.15.0 replaced it with \`kit\`"
  git_ rm -q scions/kkold && by_hand kkapp && commit kkapp
  refused "kits: a provider's apps.pot" nix build --no-link .#tools
  expect "is reserved" holds "graft: apps pot (from kkapp): that name is graft's; the provider must rename it"
  git_ rm -q scions/kkapp && commit "no kkapp"
  local n
  for n in pot-kits graft-kits; do
    sed -i "s|perSystem = { pkgs, ... }: {|perSystem = { pkgs, ... }: { packages.$n = pkgs.hello;|" flake.nix && commit "own $n"
    refused "kits: perSystem's packages.$n" nix build --no-link .#tools
    expect "is graft's" holds "graft: packages $n (from self): that name is graft's; rename the repo's own"
    sed -i "s|{ packages.$n = pkgs.hello;|{|" flake.nix && commit "no own $n"
  done
  refuse "kits: mkFlake reads no kit field" bash -c "cat '$graft/lib/mk-flake.nix' | grep -qE 'kit\.(packages|requests|commands|protect|files|env|recipes)|selfKit'"

  # no inputs.pot: no pot-kits, the tools unwrapped, no kits.just, and one warning naming the kits
  local c0=$work/kc0 && consumer "$c0" && cd "$c0"
  by_hand kk && commit init && quiet nix flake lock && commit lock
  refused "kits: without inputs.pot, no pot-kits" nix eval --raw ".#packages.$sys.pot-kits.drvPath"
  ran "kits: the tools build" nix build -o "$work/kt0" .#tools
  expect "unwrapped: the program itself" test "$(readlink -f "$work/kt0/bin/kk-tool")" = "$(readlink -f "$work/ktu/bin/kk-tool")"
  expect "with a warning naming the kit and inputs.pot" holds "graft: scions/kk/graft.nix declares a kit for pot, but this flake has no inputs.pot: no packages.<system>.pot-kits, so no run applies it; add inputs.pot.url"
  local c1=$work/kc1 && consumer "$c1" && cd "$c1" && by_hand docs && commit init && quiet nix flake lock && commit lock
  ran "kits: no kit, no pot: no warning" nix build --no-link .#tools
  refuse "says nothing of pot" holds "inputs.pot"
  cd "$c0"
  printf 'import? "scions/kits.just"\n' > justfile && commit justfile
  ran "kits: sync without pot, a justfile importing kits.just" g sync
  expect "says why there is none" holds "graft: scions/kits.just: this flake has no pot-kits (no inputs.pot); not written"
  expect "writes none" test ! -e scions/kits.just
  cp "$work/kkj" scions/kits.just && commit "a kits.just"
  refused "kits: check, a kits.just with no pot-kits" g check
  expect "names inputs.pot" holds "graft: scions/kits.just is here but this flake has no pot-kits (no inputs.pot): add inputs.pot, or remove the file"
  local c3=$work/kc3 && consumer "$c3" "$(printf '  inputs.graft.url = "path:%s";\n  outputs = inputs: inputs.graft.lib.mkFlake { inherit inputs; outputs.packages.%s.pot-kits = inputs.self; };' "$graft" "$sys")"
  (cd "$c3" && commit init && refused "kits: outputs' packages.pot-kits, without pot" nix eval --raw ".#packages.$sys.pot-kits.outPath" \
    && expect "is still reserved" holds "graft: mkFlake's outputs has packages.$sys.pot-kits: that name is graft's; rename the repo's own")
  local c2=$work/kc2 && consumer "$c2" "$(printf '  inputs.graft.url = "path:%s";\n  outputs = inputs: inputs.graft.lib.mkFlake { inherit inputs; outputs.packages.%s.sandbox = inputs.self; };' "$graft" "$sys")"
  (cd "$c2" && commit init && refused "kits: outputs' packages.sandbox" nix eval --raw ".#packages.$sys.sandbox.outPath" \
    && expect "is reserved" holds "graft: mkFlake's outputs has packages.$sys.sandbox: that name is reserved (pot)")

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
  local reach='GRAFT_TMP=$(mktemp -d) && . "$1/lib/common.sh" && pot_reaches "$2"'
  expect "kits: check in a run: pot says reached" env PATH="$stub:$PATH" POT=work bash -c "$reach" _ "$graft" https://reached.example/x
  refuse "pot says not reached" env PATH="$stub:$PATH" POT=work bash -c "$reach" _ "$graft" https://other.example/x
  printf '#!/bin/sh\necho "usage: pot why PATH" >&2\nexit 2\n' > "$stub/pot"
  expect "an older pot (no usable answer): the fetch is tried" env PATH="$stub:$PATH" POT=work bash -c "$reach" _ "$graft" https://other.example/x
  refuse "kits: graft reads no POT_POLICY" grep -q POT_POLICY "$graft/lib/common.sh"
  cd "$work"
}

sec_own() {
  # graft's docs check (dev/flake.nix) reads knowledge-base-kit from a flake input: the same commit as its scion
  local link rev b0 b1 c=$work/own-boundary
  link=$(git_ -C "$src" ls-files -s scions/knowledge-base-kit | awk '$1 == "160000" { print $2 }')
  rev=$(jq -r '.nodes["knowledge-base-kit"].locked.rev' "$src/dev/flake.lock")
  expect "own: dev/flake.nix's knowledge-base-kit input is at its scion's gitlink ($link)" test "$link" = "$rev"
  expect "own: graft's own lock holds no knowledge-base-kit (consumers never lock it)" \
    test "$(jq -r '.nodes | has("knowledge-base-kit")' "$src/flake.lock")" = false
  expect "own: graft's flake.nix doesn't declare self.submodules (it is others' input)" \
    test -z "$(grep -E '^[^#]*submodules *= *true' "$src/flake.nix")"
  ran "own: the docs check (nix flake check ./dev)" nix build --no-link "$src/dev#checks.$sys.docs"
  # the boundary: graft's command is built from graft's own sources (lib/*.sh, lib/*.jq, template/), so
  # an edit in mkFlake leaves packages.<system>.default as it was
  cp -r "$graft" "$c"
  b0=$(nix eval --raw "path:$c#packages.$sys.default.drvPath")
  local f
  for f in lib/mk-flake.nix flake.nix; do
    echo "# a comment" >> "$c/$f"
    b1=$(nix eval --raw "path:$c#packages.$sys.default.drvPath")
    expect "own: a comment in $f leaves graft's command as it was" test "$b0" = "$b1"
  done
  echo "# a comment" >> "$c/lib/common.sh"
  b1=$(nix eval --raw "path:$c#packages.$sys.default.drvPath")
  expect "own: and a comment in lib/common.sh changes it (the experiment sees graft's sources)" test "$b0" != "$b1"
}

sections=(own contracts mkflake tarball nix try kits add sync check outdated status changelog upgrade graft workflows ci migrate)
[ $# -eq 0 ] || sections=("$@")
for s in "${sections[@]}"; do
  echo "== $s"
  "sec_$s"
done
echo "all passed"
