---
status: working
---
# `tuteur check` fails

Find the message that `tuteur check`, `tuteur ci check` or a Nix build printed, and fix what it names. Each
heading below is one message.

## Before you begin

- Run the check from the repository's top: `nix run .#tuteur check`. For a flake in a subdirectory,
  `nix run 'path:DIR#tuteur' check`. In zsh, quote flake references
  ([The tuteur command](../reference/commands.md#the-tuteur-command)).
- It prints one `tuteur:` line per problem, naming each pattern, and exits 1. Fix them in the order printed.
- Read your patterns folder for `.patterns/` below.
- If a pattern has edits that someone meant, keep them before you go back to the pin: they are a provider fix
  ([Fix a provider from a consumer](fix-a-provider.md)).

## Steps

1. Run the check, and find each message below.
2. Do the fix under it.
3. Run the check again. On success it prints `tuteur: N patterns clean and at release tags` (`1 pattern` for
   one), and exits 0.
4. Commit what the fixes changed: `git status --short` names it.

## Check it worked

From the repository's top, paste this. It prints `ok` only if the check passes, nothing is left to commit,
and `nix flake check` passes on the committed tree:

```sh
nix run '.#tuteur' check && test -z "$(git status --porcelain)" && nix flake check && echo ok
```

## `tuteur check` messages

### tuteur: tuteur try is on (.tuteur-try): Nix builds read the working tree, patterns included: tuteur try --stop turns it off

`tuteur try` is on: someone (or an agent) is building the repository with a pattern's uncommitted edits
([Fix a provider from a consumer](fix-a-provider.md#steps), step 3). Its marker, `.tuteur-try`, must not be
committed. When the trial is done, turn it off from the repository's top:

```
nix run .#tuteur -- try --stop
```

It removes `.tuteur-try`; the patterns' edits stay. Then deal with them as the messages below say.
`tuteur upgrade` refuses while try is on, with `tuteur: tuteur try is on; nothing changed: tuteur try --stop first`,
and `git stash` fails (`error: Entry '.tuteur-try' not uptodate. Cannot merge.`).

### tuteur: .tuteur-try is committed (tuteur try's marker): tuteur try --stop, then commit its removal

A commit holds `.tuteur-try`: `git commit -a`, or `git add -A` (or `git add .`) then a commit, takes a file
marked with intent to add. In CI this is `tuteur ci check`'s failure. Run `nix run .#tuteur -- try --stop` (it stages the removal:
`tuteur: .tuteur-try was committed: its removal is staged; commit it`), then commit. If the commit also moved a
pattern to an unreleased commit, the release-tag message below says so.

### tuteur: .tuteur-try is left from tuteur try but untracked, so Nix builds read the recorded patterns: …

A `git reset` of the repository unmarked try's marker, so builds no longer read the patterns' working trees.
`nix run .#tuteur -- try` marks it again; `nix run .#tuteur -- try --stop` removes it.

### tuteur: no patterns here (no README.md carrying tuteur's marker); tuteur add URL adds one

Not a failure (exit 0). tuteur found no `README.md` with its marker line: the repository adds nothing yet,
or the patterns README was deleted. If you have patterns, run `nix run .#tuteur sync`, which writes it again, and
commit `.patterns/README.md`.

### tuteur: tuteur's README is in .patterns/ but mkFlake's dir is "DIR": set dir = ".patterns"; …

`mkFlake`'s `dir` in `flake.nix` names another folder than the one holding your patterns, so Nix would build
without them. Set `dir` to the folder the message names (or leave `dir` out for `patterns`), and commit. mkFlake
gives the same message when Nix evaluates the tools.

### tuteur: .patterns/x is tracked as files, not as a submodule: …

`.gitmodules` registers `.patterns/x`, but git records it as ordinary files: `git add` ran over a clone while the
path was still in the index, typically a copied v2.12 pattern removed with `rm` but not with `git rm --cached`.
Nix then builds those files, never the provider's release, and the pattern cannot be upgraded.

If the folder is a clone (`test -e .patterns/x/.git` succeeds), do what the message says:

```
git rm -r -q --cached .patterns/x
git add .patterns/x
git ls-files -s .patterns/x     # one line, mode 160000
```

If it holds only files (no `.git`), `git add` would record the files again. Remove them, and add the
provider afresh at the version you want, with the URL that `.gitmodules` gives:

```
git config -f .gitmodules submodule.patterns/x.url
git rm -r -q --cached .patterns/x && rm -rf .patterns/x
nix run github:danielnaab/tuteur/v0.2.0 -- add -C . URL@TAG x
git ls-files -s .patterns/x     # one line, mode 160000
```

Then commit. `tuteur add` refuses to add over such a path until it leaves the index, and `sync` stops on it.

### tuteur: .patterns/foo is not a submodule: tuteur add URL, or remove it

A folder in the patterns folder is not a submodule: files committed there by hand, or a copy-mode pattern left
over from v2.12.0. If it is a provider, `git rm -r .patterns/foo`, then `nix run .#tuteur add URL`. If it is not,
move it out of the patterns folder.

### tuteur: .patterns/x is a submodule .gitmodules doesn't register: …

The tree has a gitlink at `.patterns/x`, but `.gitmodules` has no entry for it, so nobody can fetch it. Do what
the message says: `git rm --cached .patterns/x`, then `nix run .#tuteur add URL`.

### tuteur: .patterns/x is a submodule with no folder: …

The tree records the submodule, but its folder is gone from the working tree. Fill it,
`git submodule update --init --recursive -- .patterns/x`, or remove the pattern, `git rm .patterns/x`.

### tuteur: .gitmodules registers .patterns/x, which is not a submodule here: …

A `.gitmodules` entry is left over from a pattern that was removed without `git rm`. Remove the entry,
`git config -f .gitmodules --remove-section submodule.patterns/x`, or add it again with `tuteur add`. Commit
`.gitmodules`.

### tuteur: .patterns/x: .gitmodules gives a relative URL (../x.git), which Nix can't resolve: …

git resolves a relative URL from your remote, but Nix cannot. Write the absolute URL:

```
git config -f .gitmodules submodule.patterns/x.url https://forge.example/team/x.git
git submodule sync -- .patterns/x
```

Then commit `.gitmodules`.

### tuteur: flake.nix doesn't declare inputs.self.submodules = true;, so Nix sees no patterns: add it (Nix 2.27 or later)

A git flake at the repository's top leaves patterns out of its source without this line. Add
`inputs.self.submodules = true;` to `flake.nix`, and commit. If your flake deliberately reads no patterns (it
only adds docs, say), put the comment `# tuteur: no self.submodules` in `flake.nix` instead.

### tuteur: .patterns/NAME is empty: git submodule update --init --recursive -- .patterns/NAME (or tuteur sync)

The pattern is not filled: a fresh clone or worktree. Run `git submodule update --init --recursive` first: it
always works, while `nix run .#tuteur sync` needs the flake to evaluate, which a fresh clone with a modified
tracked file cannot (below). To make it happen by itself, see
[Clones, worktrees, sandboxes and CI](clones-and-worktrees.md).

### tuteur: .patterns/NAME's own submodules are empty (…): git -C .patterns/NAME submodule update --init --recursive (or tuteur sync); …

The provider adds other repositories, and git did not fill them: `git submodule update --init` without
`--recursive` leaves them empty. Run `git -C .patterns/NAME submodule update --init --recursive`, or
`nix run .#tuteur sync`. Until then, a build with any tracked file modified
fails with `error: Failed to fetch git repository '…/patterns/NAME/…'`.

### tuteur: uncommitted edits in .patterns/NAME: FILE … (Nix builds ignore them while the rest of the tree is clean)

(The end reads `(tuteur try is on: Nix builds use them)` while try is on, and `(a path: flake's builds use
them)` for a flake in a subdirectory, which always builds the working tree.)

Someone edited a provider's tracked files in the pattern, or staged a change there. A formatter or a linter's
`--fix` may have done it. New untracked files, such as `__pycache__/`, do not count. Look:

```
git -C .patterns/NAME status --short
git -C .patterns/NAME diff
```

- **A provider fix that someone meant:** follow [Fix a provider from a consumer](fix-a-provider.md) from
  step 1. The edit stays in the pattern until you push it.
- **Anything else:** discard it with `git -C .patterns/NAME reset -q --hard`. Then stop the cause: tell each
  tool that the patterns folder is not yours.

  | Tool | Add |
  |---|---|
  | ruff | `extend-exclude = ["patterns"]` and `force-exclude = true`, under `[tool.ruff]` in `pyproject.toml` |
  | black | `extend-exclude = "^/patterns/"` and `force-exclude = "^/patterns/"`, under `[tool.black]` |
  | pre-commit | `exclude: ^.patterns/` at the top of `.pre-commit-config.yaml` |
  | Prettier | `.patterns/` in `.prettierignore` |
  | treefmt | `excludes = [".patterns/**"]` under `[global]` in `treefmt.toml` |
  | An agent | the `AGENTS.md` section in [Add your first pattern](add-a-pattern.md#steps), step 6 |

### tuteur: .patterns/NAME is checked out at X but the repository records Y: git add .patterns/NAME to record it, or git submodule update --recursive -- .patterns/NAME to go back

The pattern's checkout and the gitlink disagree (`git submodule status` shows `+`). Either someone switched the
pattern to another commit, or the gitlink moved (a pull, a merge, `git checkout` without
`submodule.recurse=true`) and the pattern did not follow. While this lasts, a build reads the gitlink when the
tree is clean and the checkout when it is not.

- To go back to the recorded pin: `git submodule update --recursive -- .patterns/NAME`. (`tuteur sync` never
  moves a filled pattern.) Commit or stash edits in the pattern first.
- To record the checkout as the new pin: `git add .patterns/NAME`. Only do this at a release tag, or the next
  message follows. To take a newer release, prefer `nix run .#tuteur upgrade NAME`.

### tuteur: .patterns/NAME at abc1234 is not a release tag of URL (nearest: v1.0.0-1-g…): release it, then tuteur upgrade NAME@TAG …

The gitlink is not the commit of any version tag of the provider: an unreleased fix was committed
([Use the fix before its release](fix-a-provider.md#use-the-fix-before-its-release)), or a tag was moved or
deleted upstream. `nearest` is `git describe` of the commit.

- Once the provider has released the fix: `nix run .#tuteur upgrade NAME@v1.0.1` (that release), or
  `nix run .#tuteur upgrade NAME` (the newest release in the major of the nearest tag). Then commit.
- To go back to the last release instead: `nix run .#tuteur upgrade NAME@v1.0.0`, and commit.

If the pattern's commit was never pushed to the provider, `nix run .#tuteur` cannot even evaluate (Nix fails with
`Cannot find Git revision …`, below). Run tuteur from its own flake instead:
`nix run github:danielnaab/tuteur/v0.2.0 -- check -C .`.

If a line before it says `(upstream unreadable: checked local tags)`, tuteur could not reach the provider, and
compared with the pattern's local tags. Fix the access, and run the check again. Inside a `pot` run, the line is
`tuteur: upstream tags are not reachable from this pot run: checked each pattern's local tags`: run
`tuteur check` on the host to compare with upstream ([Commands](../reference/commands.md#check)).

### tuteur: .patterns/NAME: tag vX.Y.Z exists locally but not at URL: push it …

The pattern's commit carries a release tag in your clone only: the provider's release was tagged but never
pushed. Push it, `git -C .patterns/NAME push origin vX.Y.Z`, and run the check again. Until then, Nix (which
fetches from the URL) cannot fetch that commit unless a pushed branch holds it.

### tuteur: flake.lock pins NAME at vX.Y.Z (abc1234) with narHash sha256-…, but its tag's git archive hashes to sha256-…: …

The lock holds the hash of a tree that is not the tag's: Nix's fetch cache on the machine that locked it had the
commit from another fetch (a `git+file:` or `.` fetch keeps the files the provider export-ignores), and gave that
tree to the lock. Builds pass on that machine and fail elsewhere, in CI first, with
`NAR hash mismatch in input 'github:…'`
([A polluted fetch cache](../reference/nix-behaviours.md#a-polluted-fetch-cache-locks-the-wrong-tree)). Re-lock the
input through an empty fetch cache, as the message says:

```
XDG_CACHE_HOME=$(mktemp -d) nix flake update NAME
```

Run the check again: the message is gone, and `git diff flake.lock` shows the `narHash` changed to the second hash
of the message. Commit it.

### tuteur: .patterns/NAME/tuteur.nix doesn't evaluate (above): every output of this flake fails until it does, …

The provider's `tuteur.nix` does not parse (the lines above show Nix's error). Nix cannot contain a parse
error, so every output of the flake fails, `nix run .#tuteur` too: `check` prints this only when run from
tuteur's own flake, `nix run github:danielnaab/tuteur/v0.2.0 -- check -C .`. Move the pattern back to a release
that parses: `git submodule update --recursive -- .patterns/NAME` (back to the recorded pin, if you edited it),
or `nix run github:danielnaab/tuteur/v0.2.0 -- upgrade -C . NAME@TAG` (an earlier release). Tell the
provider.

### tuteur: the flake's tools or checks don't evaluate (above): a provider's tuteur.nix fails

Every rule passed, but evaluating the flake's tools or checks failed; the lines above name the provider
(`… while evaluating .patterns/NAME/tuteur.nix`) and its error. tuteur never leaves a failing provider out. Fix it in
the provider ([Fix a provider from a consumer](fix-a-provider.md)), or move the pattern back to a release that
works: `nix run .#tuteur upgrade NAME@TAG`.

### tuteur: .patterns/README.md is stale or edited: tuteur sync

The patterns README is tuteur's: its rules for the patterns, and a link to each pattern's guide at its recorded
commit. It is stale after a pattern moved by hand (`git add .patterns/NAME`), and edited when someone wrote in
it. Run `nix run .#tuteur sync`, which writes it again, then commit it. Put your own rules in `AGENTS.md`.
Inside a pot run the patterns folder is read-only: run sync on the host.

### .forgejo/workflows/FILE differs from the copy this tuteur version ships

One of tuteur's workflows was edited, or tuteur's pin moved without a sync. `nix run .#tuteur sync` restores
it (`tuteur: refreshed .forgejo/workflows/FILE`). To keep your edits instead, delete its marker line first
([Keep your own edits to a workflow](../reference/files.md#keep-your-own-edits-to-a-workflow)).

### tuteur: two patterns folders: A, B; tuteur supports one per repository

Two `README.md` files carry tuteur's marker line. tuteur finds the patterns folder and the flake by it. Keep
the one beside your flake, and delete the other README (or its folder, if it is a left-over copy-mode
patterns folder).

### tuteur: note: .patterns/NAME has its own submodules (…)

Not a failure. The provider adds other repositories. tuteur's `add`, `sync` and `upgrade` fill them on
disk, and a git flake on a clean tree fetches them from their URLs as well. If one of them is private and you
cannot read it, your evaluation fails: ask the provider to drop it ([One level](../decisions.md#one-level)).

## Nix evaluation errors

mkFlake raises these when Nix evaluates `packages`, `apps`, `checks` or `devShells`: in `nix build`,
`nix flake check`, `nix run .#…`, and `tuteur ci check`.

### error: Failed to fetch git repository '…/patterns/NAME'

Nix's own message, before tuteur can say anything: the pattern is empty (a fresh clone or worktree) and a
tracked file is modified, so Nix reads the working tree and finds nothing to read. The same happens for an
empty submodule *inside* a pattern (`…/patterns/NAME/patterns/OTHER`). Fill the patterns with git:

```
git submodule update --init --recursive
```

`nix run .#tuteur sync` may not evaluate here; git always works. A clean clone builds without this, because
Nix then fetches the patterns itself ([Nix behaviours](../reference/nix-behaviours.md#what-a-build-sees-of-a-pattern)).

### Cannot find Git revision '<sha>' in ref 'refs/heads/main' of repository '<url>'

Nix's own message: the consumer records a pattern commit that the provider's remote does not have. On a
clean tree `nix run .#tuteur …` fetches every pattern before tuteur runs, so it fails here too: run tuteur from
its own flake, `nix run github:danielnaab/tuteur/v0.2.0 -- check -C .`. The same happens to `tuteur add` of a
provider whose own pinned submodules are not pushed yet (before the provider's release is pushed): push
first. Push the pattern's commit to the provider (any branch or tag), or go back to a release:
`git submodule update --recursive -- .patterns/NAME`, then `git add .patterns/NAME`. `push.recurseSubmodules=check` prevents
this ([Clones, worktrees, sandboxes and CI](clones-and-worktrees.md#set-up-your-machine-once)).

### tuteur: .gitmodules registers .patterns/NAME but the flake's source lacks it: add inputs.self.submodules = true; …

Nix gave mkFlake a source without submodules. Either `flake.nix` lacks `inputs.self.submodules = true;`
(add it), Nix is older than 2.27 (upgrade it), or the flake was fetched as `github:OWNER/REPO`, a tarball
with no submodules: use `git+https://…` instead ([Nix behaviours](../reference/nix-behaviours.md)).

### tuteur: .patterns/a, .patterns/b are empty in the flake's source, so the tools leave out what they give: run git submodule update --init --recursive (or tuteur sync)

A warning: `tools` built without those patterns. A `path:` flake reads the working tree, and the patterns are not
filled; or the flake was fetched as `github:`, which has no submodules (use `git+https://…`). The same cause
fails a provider that needs the empty pattern: `tuteur: .patterns/NAME is empty in the flake's source: …`. Run either command from the
repository's top; `git submodule update --init --recursive` always works ([Clones, worktrees, sandboxes and CI](clones-and-worktrees.md)).

### tuteur: DIR/README.md is graft's copy-mode README (v2.12 or earlier): …

Every command and mkFlake say this. The repository is still in graft v2.12's copy mode.
The message ends `… follow the Upgrading steps of v2.13.0 in graft's CHANGELOG.md (https://github.com/danielnaab/graft/blob/v2/CHANGELOG.md)`. Follow
[Move from copy mode](https://github.com/danielnaab/graft/blob/v2.22.0/docs/guides/move-from-copy-mode.md).

### tuteur: DIR/NAME: a pattern's folder name must be letters, digits, . _ and - …

Rename the submodule's folder: `git mv .patterns/OLD .patterns/NEW`. `self` is reserved for your own `perSystem`.

### tuteur: mkFlake's dir must be one folder name …

`dir` is a single folder name in the flake's directory, such as `".patterns"`, not a path.

### tuteur: tuteur's README is in .patterns/ but mkFlake's dir is "DIR": set dir = ".patterns"; (or move the patterns)

The same fix as for this message from `tuteur check`, above: set `dir` to the folder the message names.

### tuteur: DIR/README.md lacks tuteur's marker: is dir right? (mkFlake's dir = "DIR")

`mkFlake`'s `dir` names a folder without the marker README: `dir` is wrong, or the README was deleted or
edited. Correct `dir` in `flake.nix`, or write the README again with `nix run .#tuteur sync`.

### tuteur: A needs B, which this repository does not have: tuteur add URL

Provider `A`'s `tuteur.nix` requires provider `B` (it uses B's tools or files). Run the `tuteur add` command
that the message prints, then commit. If you added B under another folder name, rename the folder to B's
name: `requires` finds it by name.

### error: … while evaluating .patterns/NAME/tuteur.nix (tuteur calls it for the pattern NAME)

The provider's `tuteur.nix` threw: the line after names its error. It fails `packages.<system>.tools`,
`checks` and `nix flake check`; `nix run .#tuteur` still works. Fix it as for
[the flake's tools or checks don't evaluate](#tuteur-the-flakes-tools-or-checks-dont-evaluate-above-a-providers-tuteurnix-fails).

### tuteur: tools NAME (from A and B): two patterns provide the same name

Two providers ship a tool (or app or package) with the same name. When one side is your own `perSystem` the
message says `(from pattern A and the consumer's perSystem): both provide the same name; rename the consumer's own`:
rename your tool. Neither consumer setting can
choose between them: ask one provider to rename its tool, or stop adding one of them
(`git rm .patterns/A`). Two providers that ship the same store path, such as the same `just`, do not
collide.

## Sources

- [lib/patterns.sh](../../lib/patterns.sh): `check` and its messages.
- [lib/mk-flake.nix](../../lib/mk-flake.nix): the evaluation errors.
- [lib/workflows.sh](../../lib/workflows.sh): the workflow comparison.
- [tests/run.sh](../../tests/run.sh): one failing fixture per `check` rule, and each mkFlake error.
- [tests/fixtures.sh](../../tests/fixtures.sh) `check-fails`: the repositories this page was read against.
- [Commands](../reference/commands.md#check).
