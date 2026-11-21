---
status: working
---
# Commands

Every `mkFlake` argument, flake output, command and flag.

## mkFlake

`tuteur.lib.mkFlake { inputs; dir ? ".patterns"; perSystem ? null; outputs ? { }; }` returns the repository's
flake outputs. It calls each provider's `tuteur.nix` (else `graft.nix`) under the contract [provider/3](provider.md).
When the flake has `inputs.pot`, it hands the kits to pot's library under
[pot-lib/1](https://github.com/danielnaab/pot/blob/v0.1.0/contracts/pot-lib-1.md), which writes them as
[pot-kits/1](https://github.com/danielnaab/pot/blob/v0.1.0/contracts/pot-kits-1.md).

| Argument | Default | Meaning |
|---|---|---|
| `inputs` | (required) | The flake's inputs. `inputs.self` is the repository. If there is an `inputs.nixpkgs`, it is the `pkgs` that every `tuteur.nix` gets; otherwise tuteur's own pinned nixpkgs. If there is an `inputs.pot`, mkFlake calls its `lib.pot.kitsFor` for `pot-kits`; otherwise there is no `pot-kits`. |
| `dir` | `".patterns"` | The patterns folder: one folder name (`[A-Za-z0-9._-]+`, not `.`, `..` or `.git`), in the flake's directory. Through 0.1.x, with no `dir` and no `.patterns/`, graft's default is read: `scions/`, else `.scions/`, when it holds the marker README (`tuteur check` names it). |
| `perSystem` | none | The repository's own tools, apps, packages, checks, dev shells and repo kit: a function `{ pkgs, lib, system, patterns, ... }: { tools ? { }; apps; packages; checks; devShells; kit; kitArgs; }`, called once per system and merged like a provider's `tuteur.nix`, under the name `self` (a collision says `from pattern A and the consumer's perSystem`). Its checks are not prefixed: `checks.<system>.NAME`. Its `devShells` are output as they are. Use it to put a tool of your own, such as `bun`, into `tools`. Its `kit` is the repository's [repo kit](https://github.com/danielnaab/pot/blob/v0.1.0/docs/reference/pot.md#schema), and its `kitArgs.<kit>` are the arguments that a provider's kit reads. |
| `outputs` | `{ }` | Plain extra outputs, merged last with `recursiveUpdate`, so they add to and override tuteur's, except `apps.<system>.tuteur`, `apps.<system>.graft` and the reserved names `sandbox`, `pot`, `pot-kits` and `graft-kits`. |

Removed in graft v2.13.0: `scions` (there is no input list) and `flakeDir` (tuteur finds the flake as the parent of
the patterns folder).

A top-level git flake must declare `inputs.self.submodules = true;` (Nix 2.27 or later); `tuteur check` fails
without it, unless `flake.nix` carries the comment `# tuteur: no self.submodules` (or graft's `# graft: no
self.submodules`). A `path:` flake does not
need it.

### Discovery

Every directory in `${inputs.self}/<dir>` is a pattern. Where the flake's source has a `.gitmodules` (a flake
at the repository's top), its submodule paths under `<dir>` must match those directories. Each pattern is copied
alone into the store, without its `.git` file, as `pattern-<name>`. A pattern with a `tuteur.nix` at its top is
called once per system ([Files](files.md#tuteurnix)).

### Outputs

For `x86_64-linux`, `aarch64-linux`, `x86_64-darwin` and `aarch64-darwin`:

| Output | What |
|---|---|
| `packages.<system>.tools` | One environment (`buildEnv`) of every pattern's `tools`, with each declared kit command's [wrapper](https://github.com/danielnaab/pot/blob/v0.1.0/docs/reference/pot.md#wrapped-commands) in place of the program of that name. Empty when no pattern has any. `tools.passthru.unwrapped` (also `tools.unwrapped`) is the same environment without wrappers: for CI, Nix checks, containers and workers that must not run pot. |
| `packages.<system>.<name>` | Each pattern's `packages`. |
| `apps.<system>.<name>` | Each pattern's `apps`. |
| `apps.<system>.tuteur` | The `tuteur` command for this repository. |
| `packages.<system>.pot-kits` | The workspace's kits for [`pot`](https://github.com/danielnaab/pot/blob/v0.1.0/docs/reference/pot.md), built by pot's library (`inputs.pot.lib.pot.kitsFor`, which mkFlake calls with each kit unread): `kit.json` (`{ version = 1; self; patterns.<name>; protect; }`: the repo kit and each provider's, each with its `file`, and what tuteur has pot protect: `**/tuteur.nix` and the patterns folder), `bin/` (the tools, `tuteur` for this repository, and the repo kit's `tools`; a run gets it as `POT_TOOLS`), and `closure` (their store paths). `pot` builds it with `path:`. |
| (reserved) | A provider, `perSystem` or `outputs` cannot define `pot-kits`, `graft-kits`, `sandbox` or `pot`. v2.15.0's `graft-kits` bundle is no longer written (since v2.17.0), and since v2.15.0 there is no `packages.<system>.sandbox`; both names stay reserved. |
| `checks.<system>.<pattern>-<name>` | Each pattern's `checks`, prefixed with the pattern's folder name. |
| `devShells.<system>.<name>` | `perSystem`'s `devShells`. If none defines `default`, `devShells.<system>.default` is a shell with `tools` (wrapped) on `PATH`. Providers ship no dev shells. |

Everything that reads patterns is evaluated lazily. `apps.<system>.tuteur` and the repository's own `outputs`
evaluate when a pattern is empty or broken, so `nix run .#tuteur …` can still repair it. A provider whose
`tuteur.nix` throws is never dropped: `packages.<system>.tools` and `checks.<system>` fail with its error,
under `… while evaluating .patterns/NAME/tuteur.nix (tuteur calls it for the pattern NAME)`, and so do
`nix flake check` and `tuteur check`. Only the names of `apps` and `packages` skip a failing provider, so that
`nix run .#tuteur` and your own outputs still evaluate.

One failure Nix cannot contain: a `tuteur.nix` that does not **parse** breaks every output of the flake,
`apps.<system>.tuteur` too. Run tuteur from outside to see it and move the pattern back:
`nix run github:danielnaab/tuteur/v0.1.0 -- check -C .` names it
([`tuteur check` fails](../guides/check-fails.md)).

### Evaluation errors

mkFlake fails evaluation of the outputs that use a broken pattern with one of these. Each is thrown inside a
value, so other outputs still evaluate. The fix for each is in
[`tuteur check` fails](../guides/check-fails.md#nix-evaluation-errors).

- `tuteur: tools nb-index (from mk and nk): two patterns provide the same name`. Also for `apps` and `packages`.
  Providers are named in alphabetical order. Two tools with the same name and the same store path are one
  tool, not a collision. When one side is your `perSystem`:
  `tuteur: tools lk (from pattern lk and the consumer's perSystem): both provide the same name; rename the consumer's own`.
- `tuteur: nk needs kb, which this repository does not have: tuteur add URL`
- `tuteur: .gitmodules registers .patterns/a, .patterns/b but the flake's source lacks them: add inputs.self.submodules = true; to flake.nix (Nix >= 2.27). Fetched with github:? use git+https://…, which keeps submodules.`
  (`lacks it` for one pattern.)
- `tuteur: tuteur's README is in .patterns/ but mkFlake's dir is "DIR": set dir = ".patterns"; (or move the patterns)`,
  when a folder at the top of the flake's source holds tuteur's README and `dir` names another (missing or not).
- `tuteur: DIR/README.md lacks tuteur's marker: is dir right? (mkFlake's dir = "DIR")`
- `tuteur: DIR/README.md is graft's copy-mode README (v2.12 or earlier): graft v2.13.0 pins scions with git submodules; follow the Upgrading steps of v2.13.0 in graft's CHANGELOG.md`
- `tuteur: DIR/NAME is not a submodule: tuteur add URL, or remove it`
- `tuteur: DIR/NAME: a pattern's folder name must be letters, digits, . _ and - (starting with a letter or digit), and not self`
- `tuteur: mkFlake's dir must be one folder name (letters, digits, . _ -; not ., .. or .git), got "DIR"`
- `tuteur: .patterns/NAME is empty in the flake's source: run git submodule update --init --recursive (or tuteur sync)`, when a
  provider uses an empty sibling (`patterns.NAME`).
- `tuteur: apps tuteur (from NAME): that name is tuteur's; the provider must rename it`, and the same for
  `packages tools` and the reserved names `sandbox`, `pot`, `pot-kits` and `graft-kits`; for `perSystem`, `…; rename the repo's
  own`.
- `tuteur: .patterns/NAME/tuteur.nix gives \`sandbox\`: graft v2.15.0 replaced it with \`kit\` (pot; see tuteur's CHANGELOG)`,
  and the same with `the consumer's perSystem`.
- `tuteur: mkFlake's outputs has apps.<system>.tuteur: that name is tuteur's; rename the repo's own`. For the
  reserved names: `tuteur: mkFlake's outputs has packages.<system>.sandbox: that name is reserved (pot); rename the repo's own`.
- A kit with a field it should not have fails when `pot-kits` builds (pot's own check): `pot: FILE: FIELD is not a kit
  field (commands, env, files, packages, protect, recipes, requests)`.

An empty pattern is not an error by itself. `packages.<system>.tools` builds without it, and Nix prints a
warning:

```
warning: tuteur: .patterns/a, .patterns/b are empty in the flake's source, so the tools leave out what they give: run git submodule update --init --recursive (or tuteur sync)
```

followed by `. Fetched with github:? use git+https://…, which keeps submodules.` for a flake at the top. A
`github:` tarball has the pattern folders empty, so it gets this warning.

A repository with no patterns yet is allowed: `tools` is then an empty environment, and `tuteur check` warns.

## The tuteur command

Run it as `nix run .#tuteur COMMAND`. Through 0.1.x, `nix run .#graft COMMAND` runs it too (graft's name, which
graft's workflows use; `check` names it). A flag needs `--` before it, because Nix otherwise reads it:
`nix run .#tuteur -- outdated --json`. For a flake in a subdirectory, run `nix run 'path:DIR#tuteur'` from
the repository's top.

Every command except `sync` also runs from tuteur's own flake, against any checkout:
`nix run github:danielnaab/tuteur/v0.1.0 -- COMMAND -C REPO`. tuteur then reads the repository as data, and
never evaluates its flake outputs.

`nix run .#tuteur` evaluates the repository's flake first, and for a git flake with
`inputs.self.submodules = true` Nix fetches **every** submodule of the repository (not only the patterns) at
its gitlink, from its URL, while the tree is clean. A gitlink at a commit the provider's remote lacks (an
unpushed fix) then stops `nix run .#tuteur` before tuteur runs (`Cannot find Git revision …`). Use
`nix run github:danielnaab/tuteur/v0.1.0 -- COMMAND -C .` in that state.

In zsh with `extendedglob` set, `#` is a glob character, so a flake reference that holds one fails with
`zsh: no matches found`. Quote it: `'.#tuteur'`, `'path:DIR#tuteur'`. The docs quote every `path:` form, and
write `.#tuteur` unquoted.

tuteur finds the patterns folder by its marker README, with
`git grep -l -F '<!-- managed by tuteur: https://github.com/danielnaab/tuteur -->' -- '*/README.md'` (or graft's
marker, `<!-- managed by graft: https://github.com/danielnaab/graft -->`, through 0.1.x), in the
files that git tracks. `git grep` does not look inside submodules, so a provider's own patterns README never
counts, and a top-level `README.md` with the marker is ignored. A repository has at most one:
`tuteur: two patterns folders: A, B; tuteur supports one per repository`. The flake's directory is the patterns
folder's parent; with none, the flake is at the top.

Every command first refuses a copy-mode patterns README (one with a `| Scion | Commit |` table or a
`<!-- graft flake:` line):
`tuteur: .patterns/README.md is graft's copy-mode README (v2.12 or earlier): graft v2.13.0 pins scions with git submodules; follow the Upgrading steps of v2.13.0 in graft's CHANGELOG.md (https://github.com/danielnaab/graft/blob/v2/CHANGELOG.md)`.

| Command | What it does |
|---|---|
| `add [-C REPO] [--dir PATH] URL[@TAG] [NAME]` | Adds a pattern at `TAG`, default the newest version upstream. `NAME` defaults to the URL's last segment without `.git`. Runs `git submodule add`, checks out the tag's commit, writes the marker README if it is missing, and stages `.gitmodules`, the gitlink and the README. |
| `sync` (the default) | Fills every empty pattern and its own submodules, writes the marker README, and refreshes tuteur's workflows (renaming graft's marked `graft-*.yaml`). Never moves a gitlink, and never moves a filled pattern. In the repository's own flake only. |
| `check [-C REPO] [--committed]` | Fails unless every rule in [Check](#check) holds. |
| `status [-C REPO] [--json]` | For tuteur and each pattern: the pin, the tag it is at, whether it is registered, filled and clean, the newest release, and `check`'s messages. Changes nothing; exit 0 whatever their state. `--json` prints [status/1](../../contracts/status-1.md). See [status](#status). |
| `try [-C REPO] [NAME...]`, `try [-C REPO] --stop` | Makes Nix builds read the patterns' working trees, reports what each build will see, and prints the `git add` that makes the named patterns' (default: all) new files visible; `--stop` undoes it. See [try](#try). |
| `outdated [-C REPO] [--json]` | For tuteur, an input named `pot` at a version tag, and each pattern: the pinned version, the newest version in its series, the status, and the newest breaking version. |
| `changelog [-C REPO] [--json] [NAME[@TAG]...]` | Each provider's CHANGELOG sections between the pin and the target, **Upgrading** first, or its commits. Changes nothing. |
| `upgrade [-C REPO] [NAME[@TAG]...]` | Moves pins. With no names: tuteur, `pot` and every outdated pattern, each in its series (its major; below 1.0, its `0.y`). `NAME@TAG` is the only way to cross into a breaking version. |
| `migrate [-C REPO] [--base REF] [--no-check] [--json]` | Prints a migration brief for an upgraded branch. |
| `ci check\|upgrade\|pr\|signers` | The steps of tuteur's workflows. See [CI](#ci). |
| `help` | Prints the usage, one line per command. |

There is no `remove`: `git rm .patterns/NAME` removes a pattern, and git edits `.gitmodules`. There is no
sandbox in tuteur: [pot](https://github.com/danielnaab/pot) is its own repository.

### add

- `@TAG` is split off only when the part after the last `@` is a version tag, so `git@host:team/x.git` is one
  URL.
- `NAME` defaults to the URL's last path segment, without `.git`. It must match `[A-Za-z0-9][A-Za-z0-9._-]*`,
  and not be `self`.
- `TAG` defaults to the highest version tag upstream; an annotated tag is taken at its commit.
- The patterns folder: the existing one; else `--dir PATH`, from the repository's top, whose parent holds
  a `flake.nix` (`nix/agent-tools/.patterns`); else the repository's own app's `dir`, beside its flake; else
  `.patterns` at the top. `--scions PATH` is graft's name for `--dir`, read through 0.1.x, with one line saying so.
- It runs `git submodule add`, checks out the tag's commit detached, fills the pattern's own submodules
  recursively, writes the marker README if it is missing, and stages `.gitmodules`, the gitlink and the
  README. A pattern removed with `git rm` can be added again.
- Prints `tuteur: .patterns/NAME <- v1.1.0 (abc1234)`, then
  `tuteur: note: .patterns/NAME has its own submodules (.patterns/docs) …` when it has
  some (it has filled them), then `tuteur: next: commit`, or, for a flake at the top that lacks it,
  `tuteur: next: commit; a git flake also needs inputs.self.submodules = true;`.
- When the pattern's `tuteur.nix` (or `graft.nix`) requires a sibling this repository does not have (read from its text,
  `requires.X = "URL";` or `requires = { X = "URL"; };`), it prints
  `tuteur: note: NAME requires X, which this repository does not have: tuteur add URL`.
- Errors: `tuteur: .patterns/NAME is still tracked as files (a copied pattern?): git rm -r -q --cached .patterns/NAME, delete the folder, then tuteur add again`
  (a path the index still holds as files: `git add` would record the clone as files, not as a submodule);
  `tuteur: .patterns/NAME was not recorded as a submodule (git ls-files -s .patterns/NAME); remove it (git rm -r -q --cached .patterns/NAME) and try again`;
  `tuteur: .patterns/NAME exists`; `tuteur: a relative URL (../x.git) won't resolve for Nix; give an absolute URL`;
  `tuteur: URL has no semver tags`; `tuteur: NAME: no tag TAG upstream`; `tuteur: can't list tags at URL: …`
  (git's last line); `tuteur: not inside a git work tree: DIR`;
  `tuteur: --dir P: no flake.nix in D; the patterns folder goes beside the flake that uses them`;
  `tuteur: this repository's patterns are in X; tuteur supports one patterns folder per repository`.

### sync

Only in the repository's own flake. From tuteur's flake it says
`tuteur: sync runs from the repo's own flake (it writes that tuteur version's files): nix run .#tuteur sync, or nix run 'path:DIR#tuteur' sync`.

For each pattern: when it is empty, `git submodule update --init`, then its own empty submodules
(recursively). A pattern the index holds as files stops it, with the message `check` gives. A filled pattern
is never moved, also one on a fix branch or away from its gitlink. One line per pattern; the version comes from
the pattern's local tags:

```
tuteur: .patterns/pa at v1.1.0 (abc1234)
tuteur: .patterns/pa at abc1234 (untagged)
tuteur: .patterns/pa at v1.0.0 (abc1234), not the recorded def5678: left as it is (git add .patterns/pa records it; git submodule update --recursive -- .patterns/pa goes back)
```

Then it writes the marker README (`tuteur: wrote .patterns/README.md` when it changed) and
[`kits.just`](files.md#kitsjust) when the repository uses it (`tuteur: wrote .patterns/kits.just`), and refreshes tuteur's
workflows (`tuteur: refreshed .forgejo/workflows/FILE`; a workflow of graft's, `graft-NAME.yaml` with graft's marker,
is renamed first: `tuteur: renamed .forgejo/workflows/graft-NAME.yaml to .forgejo/workflows/tuteur-NAME.yaml`).
Without `inputs.pot` it writes no `kits.just`: `tuteur: .patterns/kits.just: this flake has no pot-kits (no
inputs.pot); not written`. With no patterns:
`tuteur: no patterns here yet: tuteur add URL`. While [try](#try) is on it runs as usual, and ends with
`tuteur: note: tuteur try is on: tuteur try --stop turns it off before you commit`.

The marker README's commands name this flake's run command: `nix run .#tuteur` for a flake at the top,
`nix run 'path:DIR#tuteur'` for a flake in a subdirectory.

### check

`check [-C REPO] [--committed]`. Each failure is one `tuteur:` line on stderr, naming the pattern; then it exits 1.

| Rule | Message |
|---|---|
| [try](#try) is off (both modes) | `tuteur: tuteur try is on (.tuteur-try): Nix builds read the working tree, patterns included: tuteur try --stop turns it off`; when the marker is committed, `tuteur: .tuteur-try is committed (tuteur try's marker): tuteur try --stop, then commit its removal`; when only an untracked marker is left (after a reset), `tuteur: .tuteur-try is left from tuteur try but untracked, so Nix builds read the recorded patterns: tuteur try --stop removes it, or tuteur try turns try on again`; graft's marker, `tuteur: .graft-try is graft try's marker: tuteur try --stop removes it (then commit, if its removal is staged)` |
| The repository's own app's `dir` is the patterns folder | `tuteur: tuteur's README is in .patterns/ but mkFlake's dir is "patterns": set dir = ".patterns"; in flake.nix (or move the patterns)` (only from `nix run .#tuteur`) |
| Every folder in the patterns folder is a submodule | `tuteur: .patterns/foo is not a submodule: tuteur add URL, or remove it` |
| No `.gitmodules` path is tracked as files (a copied pattern left in the index, then `git add`) | `tuteur: .patterns/x is tracked as files, not as a submodule: git rm -r -q --cached .patterns/x, then git add .patterns/x if .patterns/x/.git exists; otherwise delete the folder and tuteur add its URL@TAG again` |
| Every submodule there is registered in `.gitmodules` | `tuteur: .patterns/x is a submodule .gitmodules doesn't register: git rm --cached .patterns/x, then tuteur add its URL` |
| Every submodule has its folder | `tuteur: .patterns/x is a submodule with no folder: git submodule update --init --recursive -- .patterns/x, or git rm .patterns/x` |
| Every `.gitmodules` entry under the patterns folder is a submodule | `tuteur: .gitmodules registers .patterns/x, which is not a submodule here: tuteur add its URL again, or remove its entry (git config -f .gitmodules --remove-section submodule..patterns/x)` |
| Every URL is absolute | `tuteur: .patterns/x: .gitmodules gives a relative URL (../x.git), which Nix can't resolve: give an absolute one (git config -f .gitmodules submodule..patterns/x.url URL)` |
| A top-level flake with patterns declares `inputs.self.submodules = true;` (unless it carries the comment `# tuteur: no self.submodules`, or graft's) | `tuteur: flake.nix doesn't declare inputs.self.submodules = true;, so Nix sees no patterns: add it (Nix 2.27 or later)` |
| Every pattern is filled | `tuteur: .patterns/pa is empty: git submodule update --init --recursive -- .patterns/pa (or tuteur sync)` |
| Every pattern is clean: no modified or staged tracked file (untracked files do not count) | `tuteur: uncommitted edits in .patterns/pa: docs/status.md (Nix builds ignore them while the rest of the tree is clean)`; the end is `(tuteur try is on: Nix builds use them)` while try is on, and `(a path: flake's builds use them)` for a flake in a subdirectory |
| Every pattern is checked out at its gitlink | `tuteur: .patterns/pa is checked out at e3f04b8 but the repository records 9147b3c: git add .patterns/pa to record it, or git submodule update --recursive -- .patterns/pa to go back` |
| Every pattern's own submodules are filled | `tuteur: .patterns/nest's own submodules are empty (.patterns/docs): git -C .patterns/nest submodule update --init --recursive (or tuteur sync); Nix fails on them while the repo's tree has a modified file` |
| Every `tuteur.nix` (or `graft.nix`) parses | `tuteur: .patterns/x/tuteur.nix doesn't evaluate (above): every output of this flake fails until it does, tuteur's own app too; move the pattern back (git submodule update --recursive -- .patterns/x), or from outside: nix run github:danielnaab/tuteur/v0.1.0 -- upgrade -C . x@TAG` |
| Every gitlink is a version tag's commit | `tuteur: .patterns/pa at ec99ed1 is not a release tag of URL (nearest: v1.0.0-1-gec99ed1): release it, then tuteur upgrade pa@TAG (or tuteur upgrade pa, the newest release of its major)` (`nearest` only for a filled pattern) |
| … and that tag is upstream | `tuteur: .patterns/pa: tag v1.0.1 exists locally but not at URL: push it (git -C .patterns/pa push origin v1.0.1)` |
| The tools and checks evaluate (from `nix run .#tuteur` only, after every other rule passed) | `tuteur: the flake's tools or checks don't evaluate (above): a provider's tuteur.nix fails` |
| `<patterns>/kits.just` matches what the flake generates, when the repository uses it (the file exists, or the top `justfile` names `<patterns>/kits.just`); from `nix run .#tuteur` only, not `--committed` | `tuteur: .patterns/kits.just is stale or edited: tuteur sync`; inside a pot run, `tuteur: .patterns/kits.just is stale or edited: run tuteur sync on the host (the patterns folder is read-only in a run)`; when the flake's bundle fails, `tuteur: .patterns/kits.just: the flake's pot-kits doesn't evaluate (above)`; when the flake has no `pot-kits` (no `inputs.pot`) and the file is there, `tuteur: .patterns/kits.just is here but this flake has no pot-kits (no inputs.pot): add inputs.pot, or remove the file` |
| No `kits.just` recipe has the name of one of the top `justfile`'s own (when it is used) | `tuteur: .patterns/kits.just's recipe X has the name of the justfile's own X: rename one (a kit's recipe never replaces yours)`; `sync` warns with the same line |
| `kits.just` is a file, not a link | `tuteur: .patterns/kits.just is a symbolic link; tuteur writes only a file there: remove it, then tuteur sync` |
| Each root input of the flake's `flake.lock` at a version tag (`github:`, or `git` such as tuteur's own pin) holds its tag's tree: its `narHash` is the NAR hash of `git archive` of the locked commit, fetched by its tag, with the provider's `export-ignore` rules for `github:` and `exportIgnore` inputs and without them for other `git` inputs (both modes) | `tuteur: flake.lock pins tuteur at v0.1.0 (928a188) with narHash sha256-…, but its tag's git archive hashes to sha256-…: Nix's fetch cache probably gave the lock a tree that another fetch of that commit left there (a git+file: or . fetch keeps the files a provider export-ignores), and a machine without that cache, such as CI, fails with NAR hash mismatch: re-lock tuteur through an empty fetch cache: XDG_CACHE_HOME=$(mktemp -d) nix flake update tuteur` (for a flake in a subdirectory, `nix flake update --flake path:… tuteur`). A pin it cannot fetch gets a note and no failure: `tuteur: can't fetch tuteur's v0.1.0 from URL (…): flake.lock's narHash for it not compared with its tag's git archive` |
| tuteur's workflows match this version's | as in [Files](files.md#tuteurs-workflows) |

- graft's names in use (tuteur 0.1.x reads them; 0.2.0 drops them) get one line each on stderr, which never fails
  the check: `tuteur: THING is graft's name; 0.2.0 drops it: WHAT TO DO`. THING is the app `graft` (`nix run
  .#graft`), the marker in the README, a marked `graft-NAME.yaml` workflow, the folder found without `dir`, a
  provider's `graft.nix`, or the arguments `scion` and `scions` that a provider's function (or `perSystem`)
  names. The last three come from mkFlake (`packages.<system>.tools.passthru.tuteurAliases`), from `nix run
  .#tuteur` only. The input name `graft` gets no line: every 0.x reads it.
- `--committed` checks only what is committed: it skips the filled, clean, at-gitlink, nested, parse and
  evaluation rules, and graft's names.
  `tuteur ci check` uses it.
- If `git ls-remote` cannot read a provider, it says
  `tuteur: .patterns/pa: can't list tags at URL: … (upstream unreadable: checked local tags)`, and the pattern's
  local tags decide.
- Inside a [pot](https://github.com/danielnaab/pot/blob/v0.1.0/docs/reference/pot.md) run (`POT` set), tuteur tries a provider's tags only when pot says the run reaches its URL
  (`pot why URL --json`, `"reached": true`: the contract [run-env/1](https://github.com/danielnaab/pot/blob/v0.1.0/contracts/run-env-1.md#pot-why-target---json)): for pot, a `file://` URL or a path; an `https` or `http` host and port
  among the run's network reach; `ssh` when a `git.fetch` binding covers it. When pot gives no usable answer (an
  older pot), tuteur tries the fetch. When pot says no, it does not try, so the run leaves no denial
  behind, and the pattern's local tags decide. `check` then prints one line for the whole check, not one per pattern:
  `tuteur: upstream tags are not reachable from this pot run: checked each pattern's local tags`. Other commands
  that list tags (`add`, `outdated`, `changelog`, `upgrade`) fail for that URL with
  `tuteur: URL is not reachable from this pot run`: run them on the host. `status` reports it as the pattern's
  `latest` reason.
- A pattern with submodules of its own prints `tuteur: note: .patterns/nest has its own submodules (.patterns/docs) …`
  on stdout: a git flake on a clean tree fetches them from their URLs too.
- Success: `tuteur: N patterns clean and at release tags` (`1 pattern`); with `--committed`,
  `tuteur: N patterns registered and at release tags`.
- No patterns folder: `tuteur: no patterns here (no README.md carrying tuteur's marker); tuteur add URL adds one`,
  exit 0 (unless a workflow fails).

`check` does not compare the marker README's text: the marker line is what finds the patterns folder. Each
message and its fix: [`tuteur check` fails](../guides/check-fails.md).

### status

`status [-C REPO] [--json]` joins what `check` and `outdated` read: for each pattern, `check`'s facts and messages,
and the newest release as `outdated` reports it. It reads each upstream's tags once (`git ls-remote`), and does not
evaluate Nix, compare tuteur's workflows, or read a provider's `tuteur.nix`: those are `check`'s alone. It is for a
person or a program looking across checkouts; `check` is the gate.

```
NAME        PATH               TAG      COMMIT   CHECKOUT  LATEST
tuteur      -                  v0.1.0   928a188  -         v0.1.1 (outdated)
page-rules  .patterns/page-rules  v1.0.0   4f1c2d9  dirty     v1.1.0 (outdated; v2.0.0 is a breaking version)
tuteur: uncommitted edits in .patterns/page-rules: docs/status.md (Nix builds ignore them while the rest of the tree is clean)
```

- `TAG` is the highest version tag at the gitlink, upstream; when the upstream cannot be read, the pattern's own
  tag (as `check` reads it), else `?`. `untagged`: the gitlink is no release.
- `CHECKOUT` is `clean`, `dirty` (uncommitted edits to tracked files), `moved` (checked out away from the
  gitlink), `empty` (not filled) or `unregistered` (a folder or submodule in the patterns folder that
  `.gitmodules` does not register).
- `LATEST` is `current`, `vX (outdated)`, `untagged`, or `unknown`, with one more line saying why:
  `tuteur: NAME: can't list tags at URL: …`, or `tuteur: NAME: URL is not reachable from this pot run`.
- Then `check`'s messages, one `tuteur:` line each: the repository's, then each pattern's. Without patterns or a tuteur
  input: `tuteur: no patterns here (no README.md carrying tuteur's marker), and no tuteur input; tuteur add URL adds one`.
- `--json` prints the report that [status/1](../../contracts/status-1.md) defines, with its
  [schema](../../contracts/status-1.schema.json): a value that needs the network and cannot be read is `null`,
  with a `reason`.
- Exit 0 when it printed the report, whatever the patterns' state; 1 when it cannot read the repository (not a git
  work tree, two patterns folders, a copy-mode README); 2 for an argument it does not take
  (`tuteur: status takes no argument ARG`, then `usage: tuteur status [-C REPO] [--json]`).

### try

`try [-C REPO] [NAME...]` and `try [-C REPO] --stop`. For trying an unreleased provider change in the
consumer: [Fix a provider from a consumer](../guides/fix-a-provider.md#steps), step 3.

A git flake builds each pattern at its gitlink while no tracked file of the repository is modified, and reads
the working trees (pattern edits included) only while one is; even then it sees only files that git tracks in
the pattern ([Nix behaviours](nix-behaviours.md#what-a-build-sees-of-a-pattern)). `try` makes the first hold
until `--stop`, and tells you how to get the second:

- It writes `.tuteur-try` at the repository's top, and marks it with intent to add (`git add -N`): a file that
  differs from `HEAD`, so every Nix build reads the working tree. It checks that git sees the change before it
  says try is on.
- It never touches a pattern: no `git add`, no commit, no checkout there. A new file in a pattern, or in a
  pattern's own submodule, stays untracked, and Nix does not see it. For each named pattern (default: every
  pattern) with new files, `try` prints the `git -C … add` that stages them for real. Staged files behave as
  git always does: `git checkout -- .` keeps them, `git reset --hard` deletes them.

It refuses, before changing anything: an unknown name (`tuteur: no pattern named NAME`); a run from inside a
pattern (`tuteur: /…/patterns/pa is a submodule of /…: run tuteur from the repository's top (-C /…)`); a committed
marker, which leaves the tree clean to Nix
(`tuteur: .tuteur-try is committed, so the tree is clean to Nix; nothing changed: tuteur try --stop, commit its removal, then tuteur try`);
or, once `--stop` has staged that removal, `tuteur: .tuteur-try is committed and its removal is staged; nothing changed: commit the removal (git commit -m 'Remove tuteur try marker'), then tuteur try`;
and an empty pattern, because Nix fails on one while the tree is dirty:
`tuteur: .patterns/pa is empty, and Nix fails on an empty pattern while try is on; nothing changed: git submodule update --init --recursive -- .patterns/pa (or tuteur sync)`
(and `tuteur: .patterns/pa's own submodules are empty (…), and Nix fails on them while try is on; nothing changed: …`).

Then it reports one line per pattern: its checkout (a branch or detached), the commit as the nearest release
tag, against the gitlink, and its edits: `N modified`, `N new` (staged), `N new Nix doesn't see` (untracked,
in the pattern or its own submodules), or `no edits`.

```
tuteur: try is on: Nix builds of this repository read its working tree, and its patterns' (.tuteur-try marks it)
tuteur: .patterns/docs: detached at v1.0.0 (aabd284), as recorded: no edits
tuteur: .patterns/kb: branch fix at 1f2e3d4, 1 commit after v2.2.0, not the recorded v2.2.0 (19392ed): 1 modified, 1 new Nix doesn't see
tuteur: .patterns/kb: Nix sees a new file only once git tracks it: git -C .patterns/kb add -- src/kb_linter/statuses.py
tuteur: build from the repository's top: nix build .#tools, nix shell .#tools -c TOOL, or nix flake check
tuteur: tuteur try --stop turns try off (before git stash or a pull with --autostash here), and tuteur check fails until then
```

Running it again reports again and leaves the marker as it is. A git reset of the parent unmarks
`.tuteur-try` (Nix then reads the gitlinks again); `try` marks it again.

A flake in a subdirectory is a `path:` flake: every build copies its directory, patterns and untracked files
included, so `try` changes nothing, writes no marker, and reports:

```
tuteur: nix/tools is a path: flake: every build reads its working tree, patterns and new files included; try has nothing to turn on
tuteur: nix/tools/.patterns/kb: detached at v1.0.0 (19392ed), as recorded: 1 modified, 1 new
tuteur: build from the repository's top: nix build 'path:nix/tools#tools', nix shell 'path:nix/tools#tools' -c TOOL, or nix flake check 'path:nix/tools'
```

`--stop` undoes what `try` did: it removes `.tuteur-try` from the index and the working tree. It never
touches a pattern, and it is safe to run twice:

```
tuteur: try is off: Nix builds the recorded patterns while the tree is clean
tuteur: .patterns/kb stays as you left it: git submodule update --recursive -- .patterns/kb goes back to its pin (commit or stash its edits first)
```

If `.tuteur-try` was committed (`git commit -a`, or `git add -A` or `git add .` then a commit, takes a file
marked with intent to add), `--stop` stages its removal:
`tuteur: .tuteur-try was committed: its removal is staged; commit it`. With try off:
`tuteur: try is not on; nothing to undo`.

While the marker exists, `check` (and `check --committed`, so `ci check`) fails naming `tuteur try --stop`
([Check](#check)), `upgrade` refuses (`tuteur: tuteur try is on; nothing changed: tuteur try --stop first`),
and `sync` adds a note. `git stash` in the repository fails while `.tuteur-try` is marked
(`error: Entry '.tuteur-try' not uptodate. Cannot merge.`), and so do `git pull --autostash` and
`git rebase --autostash`: run `tuteur try --stop` first. `try` reads no flake output, so
`nix run github:danielnaab/tuteur/v0.1.0 -- try -C .` works while the repository's flake cannot evaluate, or
Nix cannot fetch a pattern's gitlink (an unpushed commit).

### outdated

Columns `NAME DIR PINNED LATEST STATUS BREAKING`, then a line explaining `BREAKING` when a row has one:

```
NAME        DIR        PINNED  LATEST  STATUS    BREAKING
tuteur      -          v0.1.0  v0.1.1  outdated  v0.2.0
pot         -          v0.1.0  v0.1.0  current   -
page-rules  .patterns  v1.0.0  v1.1.0  outdated  v2.0.0
BREAKING: a breaking version (a new major, or a new 0.y below 1.0), which tuteur upgrade takes only when named (NAME@TAG): read its CHANGELOG first
```

A version's **series** is its major, `X` for `X.y.z`; below 1.0, its `0.y`, as Cargo reads semver: each `0.y` is
its own series. `LATEST` is the newest version in the pinned series: what `tuteur upgrade NAME` takes. `BREAKING`
is the newest version of a later series.

`PINNED` is the highest version tag upstream at the gitlink; with none, `STATUS` is `untagged` and `PINNED`
the gitlink's first 12 hex digits, and, for a filled pattern with a release behind its gitlink (`git describe`),
`LATEST` is the newest version in that release's series. When the provider cannot be read, `STATUS` is `unknown`
and `PINNED` the pattern's local tag, or the commit.

The rows of `DIR` `-` are flake inputs, from `flake.lock`: tuteur's own pin, the input named `tuteur` (else
`graft`; a `path:` tuteur shows `path`, `untagged`), then an input named `pot` when its ref is a version tag (none
otherwise). An input by either name is left out when a pattern has its name.

In `--json`, the field `major` holds `BREAKING`'s value, the newest breaking version (its name stays: a field is an
interface), and is `null` when there is none. With nothing to list:
`tuteur: no patterns here (no README.md carrying tuteur's marker), and no tuteur input`.

### upgrade

- The target is the newest tag in the pinned series, unless `@TAG` names one (which may also go down).
  A breaking version is never taken unless named; `upgrade` reports it:
  `tuteur: pa: v2.0.0 is a breaking version (new major, or new 0.y); not taken (tuteur upgrade pa@v2.0.0)`.
- tuteur's own pin moves first (`tuteur: tuteur v0.1.0 -> v0.1.1`, or `graft` for an input of that name): tuteur rewrites the tag in `flake.nix`,
  fetches the new tag and runs `nix flake update tuteur` through an empty fetch cache of its own (an
  `XDG_CACHE_HOME` in its temporary folder, and no global flake registry), so the lock holds the tag's own tree
  ([A polluted fetch cache](nix-behaviours.md#a-polluted-fetch-cache-locks-the-wrong-tree)), then runs the new
  version's `lib/refresh.sh`, which writes the marker README and
  `kits.just` (where the repository uses it), and refreshes tuteur's workflows
  ([the version-crossing interface](../development.md#the-version-crossing-interface)). It moves tuteur only to a
  version with that script (`tuteur: tuteur v0.0.9 has no lib/refresh.sh, so tuteur upgrade can't hand it this
  repository; move it by hand`), and in CI only from `tuteur ci` (`tuteur: not moving tuteur itself from a CI job
  that isn't tuteur ci (…)`).
- Then an input named `pot` at a version tag, by the same rule: its tag in `flake.nix`, then
  `nix flake update pot` through the same empty fetch cache (`tuteur: pot v0.1.0 -> v0.1.1`). Nothing of pot's
  runs.
- A filled pattern is fetched at the tag from its `.gitmodules` URL, checked out detached, its own submodules
  filled, and staged. An empty one (in CI) gets its gitlink set directly (`git update-index --cacheinfo`),
  with no clone. Prints `tuteur: pa v1.1.0 -> v1.2.0`. It never changes `.gitmodules`, and never commits.
- An untagged pattern (a fix recorded before its release) moves when named: `tuteur upgrade pa@v1.0.1`, or
  `tuteur upgrade pa` for the newest version in the series of its nearest release. With no names it is left
  alone. A pattern checked out on a fix branch moves too; the branch stays.
- It refuses, before changing anything:
  - `tuteur: tuteur try is on; nothing changed: tuteur try --stop first` ([try](#try))
  - `tuteur: pa: uncommitted edits in .patterns/pa (FILE); nothing changed: commit them in the provider, or git -C .patterns/pa checkout -- .`
  - `tuteur: pa is at <12 hex>, not a release tag, and tuteur can't tell its major: name the tag (tuteur upgrade pa@TAG)`
  - `tuteur: pa: no tag v1.9.0 upstream; nothing changed`
  - `tuteur: pa: can't tell whether v1.0.0 is current (see above); nothing changed`
  - `tuteur: no pattern (or tuteur input) named X`
- A git flake build ignores a staged gitlink while the rest of the tree is clean: commit the upgrade on a
  branch before `nix flake check` ([Take a newer version by hand](../guides/upgrade.md)).

### changelog

The same output as graft's before v2.13.0: per provider (and tuteur's own input and `pot`, from their lock), `### NAME vOLD -> vNEW`, the **Upgrading** sections first,
then the rest, quoted. It reads the provider's `CHANGELOG.md` at the target tag from the URL in `.gitmodules`.
For a GitHub `https` URL it adds a compare link.
It fails after it prints if a provider cannot be read.

### migrate

What moved is tuteur and `pot` (from `flake.lock`, each with its CHANGELOG; another input is only named) and every pattern whose gitlink at the base differs from now (the
pattern's checkout when it is filled, else the index); new and removed patterns are listed as `(new)` and
`(removed)`. The brief tells the reader not to edit the patterns or tuteur's workflows, nor move the pins, and
that a pattern that needs a fix is a provider change. The brief has: what
upstream says (each provider's CHANGELOG, quoted); what moved (`git diff --name-status` between the two
commits of each provider, renames and deletions first); references here (lines of your own files, outside
the patterns folder and tuteur's workflows, that name a renamed or deleted `<dir>/<name>/<path>`); what broke
(`nix flake check`, unless `--no-check`). The base is the merge base of `HEAD` with `origin/HEAD`, else with
the first of `origin/main`, `origin/master`, `main`, `master`; `--base REF` names another. Exits 0 when it
prints a brief, also when checks fail.

### ci

- `ci check`: `flake.lock` committed and matching `flake.nix` for tuteur's input; then `tuteur check
  --committed`, which needs no filled patterns; then `nix flake check --no-build`, so that the whole flake
  evaluates. Success:
  `tuteur: ci check passed: flake.lock is committed, every pattern is at a release tag, tuteur's workflows are current, and the flake evaluates`.
  An evaluation failure ends `tuteur: the flake doesn't evaluate (above)`.
- `ci upgrade`: needs `BRANCH`, and refuses a working tree with changes of its own and a branch other than
  `BRANCH`. Runs `upgrade`, `git add -A`, commits, then runs the whole `nix flake check` on the clean committed
  tree (so Nix fetches the new patterns). On a failure it amends the commit with `nix flake check failed: …` and
  the logs' ends. It force-pushes `BRANCH` either way, and then fails if a check failed. A breaking version that
  `upgrade` held is a `::warning::` line in the run's summary.
- `ci pr`: its body lists what moved, and under "Not taken" each breaking version `upgrade` held; it quotes the
  CHANGELOG of tuteur's own input, `pot` and each moved pattern. It needs `PR_TOKEN`; tuteur's workflow gives it
  `secrets.TUTEUR_PR_TOKEN || secrets.GRAFT_PR_TOKEN || github.token`. It opens or updates the pull request only when the branch changes nothing but `flake.nix`,
  `flake.lock`, gitlinks of patterns that the default branch's `.gitmodules` registers, and the marker README
  when tuteur's own pin moved. A change to `.forgejo/` is refused (`… changes CI workflows …`), also when
  tuteur moved; so is `.gitmodules` and any other file (`… changes files tuteur upgrade never writes: …`).
- `ci signers` (since graft v2.21.0): report-only; it always exits 0. It reads `REF` (the pushed ref), `BEFORE` (its
  old commit; empty or all zeros for a new ref) and `AFTER` (its new commit, default `HEAD`), and checks what the
  push brought against `.forgejo/allowed_signers` as `BEFORE` had it, so a push cannot vouch for itself. A tag, a
  new branch, or a force-push whose old commit is not in the checkout (itself a finding) reads the file from
  `SIGNERS_REF` (the workflow fetches the default branch there), else from `AFTER`; the summary says which. A principal's class is what follows its last `@`:
  `daniel@person` (a person's hardware key), `daniel@routine` (a person's everyday key), `agent@HOST` (a host
  agent's key). Each finding is a `::warning::tuteur signers: …` line:
  - a commit whose signature does not verify against the file: unsigned, `signed by a key not in
    .forgejo/allowed_signers`, a bad, expired or revoked signature;
  - an `agent@` signature with no `Pot-Run:` trailer (pot writes it: its contract `trailer/1`);
  - a change to a protected path not signed by a `@person` key. The paths are `TUTEUR_SIGNERS_PERSON` (graft's
    `GRAFT_SIGNERS_PERSON` is read when it is not set, through 0.1.x; so are `GRAFT_SIGNERS_MAX` and `_FILE`), shell
    patterns where `*` also matches `/` (default: `grants.json`, `.forgejo/allowed_signers`, `AGENTS.md`,
    `CLAUDE.md`, `.claude/*`, `.pi/*`, each at any depth);
  - a tag that is lightweight, unsigned, or signed by neither a `@person` nor a `@routine` key.

  A new branch checks its newest `TUTEUR_SIGNERS_MAX` commits (100). No signers file is itself a finding.
  The summary: `tuteur: signers: N commit(s) on REF, M finding(s) (report-only)`. It reads git objects and the
  signers file as data, and runs nothing from the repository (a commit's subject and a principal reach the log
  with control characters replaced, so no text of theirs starts a line); the workflow that calls it does evaluate the
  repository's flake for `nix run .#tuteur`, as tuteur-check does.

### Argument errors

- `outdated`, `changelog` and `upgrade`: an argument that the command does not take fails with exit 2, a
  `tuteur:` line that names it and the command's usage line (`tuteur: -C needs a repository`,
  `tuteur: outdated takes no names: it lists tuteur and every pattern`, `tuteur: upgrade has no --json`,
  `tuteur: unknown option OPTION`). A bare `--` is skipped.
- `changelog` and `upgrade`: `tuteur: no pattern (or tuteur input) named NAME`,
  `tuteur: NAME: TAG is not a version tag`, `tuteur: NAME: no tag TAG upstream` (exit 1).
- `migrate`: `tuteur: usage: tuteur migrate [-C REPO] [--base REF] [--no-check] [--json]` (exit 1).
- `sync` and `check` take no arguments: `tuteur: sync takes no arguments`, exit 2.
- `status`: `tuteur: status takes no argument ARG` or `tuteur: -C needs a repository`, then
  `usage: tuteur status [-C REPO] [--json]`, exit 2.
- `try`: `tuteur: unknown option OPTION (usage: tuteur try [-C REPO] [NAME...], or tuteur try [-C REPO] --stop)`,
  `tuteur: try --stop takes no names: it undoes all that try did`, `tuteur: no pattern named NAME` (exit 1).
- `ci` with another step: `tuteur: usage: tuteur ci check|upgrade|pr|signers`, exit 1.
- An unknown command prints the usage on stderr, and exits 2.

## Sources

- [lib/mk-flake.nix](../../lib/mk-flake.nix): arguments, discovery, outputs, and the evaluation errors
- [pot/lib/kits-for.nix](https://github.com/danielnaab/pot/blob/v0.1.0/lib/kits-for.nix) and [pot/lib/kit.nix](https://github.com/danielnaab/pot/blob/v0.1.0/lib/kit.nix): `pot.lib.kitsFor`, the kit manifests in `packages.<system>.pot-kits`
- [lib/tuteur.sh](../../lib/tuteur.sh): commands and usage
- [lib/patterns.sh](../../lib/patterns.sh): `add`, `sync`, `check`, `status`, `try`
- [lib/tools.sh](../../lib/tools.sh): `outdated`, `changelog`, `upgrade`
- [lib/common.sh](../../lib/common.sh): finding the patterns folder, tags with `git ls-remote`, `pot_reaches`
- [lib/migrate.sh](../../lib/migrate.sh), [lib/ci.sh](../../lib/ci.sh)
- [tests/run.sh](../../tests/run.sh)
