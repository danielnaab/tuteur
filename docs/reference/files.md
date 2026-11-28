---
status: working
---
# Files

The files tuteur reads and writes, and the lines in them that tuteur recognizes.

## In a consumer

| File | Read or written | Purpose |
|---|---|---|
| `flake.nix` | Read as data. `upgrade` changes tuteur's tag, and `pot`'s. | The input named `tuteur` (else `graft`, read through 0.x) is tuteur's pin. An input named `pot`, under pot, gives mkFlake pot's library; at a version tag, `upgrade` moves it too. A top-level flake declares `inputs.self.submodules = true;`. Names no provider. |
| `flake.lock` | Written by Nix, and by `upgrade` for tuteur's input and `pot`. | tuteur's commit and hash, pot's, and nixpkgs if you have one. No provider entries. Must be committed: `tuteur ci check` fails when it is not in `HEAD`. |
| `.gitmodules` | Written by `git submodule add` (through `tuteur add`) and `git rm`. Read by every command. | Each pattern's path and URL. `upgrade` never changes it. |
| The gitlinks | Written by `add` and `upgrade`, or by `git add .patterns/NAME`. | The pins. Each must be a gitlink (mode 160000 in `git ls-files -s`), never the pattern's files: `check` fails on a registered path tracked as files, and `add` refuses to add over one. |
| `<dir>/<name>/` | A submodule. Filled by `git submodule update --init --recursive`, `tuteur sync`, a recursive clone, or the post-checkout hook. | The provider's whole repository at a release tag. |
| `<dir>/README.md` | Written by `add`, `sync` and `upgrade`; `check` finds the folder by its marker line, and compares its text. | The [marker README](#the-marker-readme): tuteur's rules for the patterns, and a link to each pattern's guide. Do not edit. Point your `AGENTS.md` at it. |
| `<dir>/kits.just` | Written by `add`, `sync` and `upgrade`, and staged; compared by `check`. Only where the repository uses it (the file exists, or the top `justfile` names `<dir>/kits.just`) and the flake has `pot-kits` (`inputs.pot`). Tracked. | The [generated recipes](#kitsjust). Do not edit. |
| `.tuteur-try` | Written by `try`, at the repository's top, and marked with intent to add; removed by `try --stop`. `check` fails while it exists. Never committed. | Makes every Nix build of a git flake read the working tree. Two `#` comment lines. See [try](commands.md#try). |
| `.forgejo/workflows/tuteur-*.yaml` | Restored by `sync`, replaced by `upgrade`, compared by `check`. graft's marked `graft-*.yaml` are not tuteur's since 0.3.0: `check` fails on one. | tuteur's workflows, if they carry the marker. |
| Settings files, such as `knowledge-base.yaml` | Read by providers' tools and checks, never by tuteur. | What a provider lets you configure. Each provider's README names its file. |

Inside a [pot run](https://github.com/danielnaab/pot/blob/v0.1.0/docs/reference/pot.md#protected-paths), the flake directory, `.gitmodules`, `.envrc`, `justfile` and
`.pre-commit-config.yaml` (at any depth), and the git metadata, are read-only. So are each provider file
(`pattern.nix`, `tuteur.nix`) and the patterns folder, which mkFlake names in the bundle's `protect`
([pot-lib/1](https://github.com/danielnaab/pot/blob/v0.1.0/contracts/pot-lib-1.md)), when the flake has `inputs.pot`.

## The marker README

`<dir>/README.md`. `add`, `sync` and `upgrade` write it (`tuteur: wrote .patterns/README.md` when it changed):
`upgrade` with the text of the tuteur version it moves to, when tuteur's pin moves. For a flake at the
repository's top, with the patterns `knowledge-base-kit` and `notebook-kit`:

```markdown
<!-- managed by tuteur: https://github.com/danielnaab/tuteur -->
# Patterns

Each folder here is a git submodule: another repository's pattern, at a release tag. Empty folders?
Run `git submodule update --init --recursive` (or `nix run .#tuteur sync`).

- Read them freely. Ask before you edit one: a fix belongs in the provider. See tuteur's "Fix a provider from
  a consumer" guide: edit on a branch, test, build with it (`nix run .#tuteur -- try NAME`, then `nix run .#tuteur -- try --stop`),
  push to the provider, release, then `nix run .#tuteur upgrade NAME`.
- `nix run .#tuteur check` fails until every pattern is clean and at a release tag, and while try is on.
- Versions: `nix run .#tuteur outdated`.

## What each pattern offers

Each pattern's guide says what it ships for this repository (tools, recipes, checks, settings) and
which of its docs to read when. Read a pattern's guide before you use what it ships. Point this repository's
AGENTS.md here, then add its own rules.

- [knowledge-base-kit](knowledge-base-kit/README.md) (it has no USING.md: its README)
- [notebook-kit](notebook-kit/USING.md)
```

tuteur's text is `lib/patterns-readme.md`, with `@RUN@` replaced by the flake's run command (for a flake in a
subdirectory, `nix run 'path:nix/agent-tools#tuteur'`), then one line per pattern that `.gitmodules` registers,
by name. Each links the pattern's [`USING.md`](#usingmd) at its recorded commit, or its `README.md` when it has
none (`lib/patterns-readme.sh`). The links are relative to the README, so they hold for a flake in a
subdirectory too.

- **`check` compares the text** from the repository's own app (`nix run .#tuteur check`), not with
  `--committed`, and only when every pattern is filled: an empty pattern's guide can't be told. A difference
  fails: `tuteur: .patterns/README.md is stale or edited: tuteur sync`.
- **An empty pattern stops a write.** `add`, `sync` and `upgrade` leave the file as it is and say so:
  `tuteur: .patterns/README.md: not written: .patterns/x is empty (tuteur sync fills it)`.
- **Your own rules go in your `AGENTS.md`,** not here: link this README from it, and add what is yours, such as
  which pattern's rules win where two differ ([Add your first pattern](../guides/add-a-pattern.md#steps), step 6).

- **The marker line** is how tuteur's commands and workflows find the patterns folder, and the flake (its
  parent directory). Exactly one per repository.
- **Other tools skip the directory by it.** knowledge-base-kit's checkers (`kb_linter`, `link_validator`)
  do not walk a directory whose `README.md` has the marker, so they do not check providers' tests and
  fixtures.
- graft's marker, `<!-- managed by graft: https://github.com/danielnaab/graft -->`, is not read since 0.3.0:
  every command, and mkFlake, refuses a README that carries it, naming tuteur 0.2.x, whose `sync` rewrote it
  ([Move from graft v2](../guides/move-from-graft.md)).

## kits.just

`<dir>/kits.just` holds a just recipe for each kit's `recipes` entry and for tuteur's own (`outdated`, `upgrade`,
`tuteur-check`), sorted by name, generated from the flake's `pot-kits`, so only where the flake has `inputs.pot` (contract
[pot-kits/1](https://github.com/danielnaab/pot/blob/v0.1.0/contracts/pot-kits-1.md)) by evaluation alone (`nix eval --raw
<flake>#packages.<system>.pot-kits.kitsJust`). tuteur writes and compares it only where the repository uses it: the
file exists, or the top `justfile` names it. To start, add the import line below, then `tuteur sync`. Each body is
one line that runs a [wrapped command](https://github.com/danielnaab/pot/blob/v0.1.0/docs/reference/pot.md#wrapped-commands):

```just
# Generated from the kits' recipes (pot-kits/1) by the bundle's producer, which writes and compares it:
# do not edit. The importing justfile defines `tools`, the tools package (its root, not its bin/).

# Check links, lifecycle status, and Sources with knowledge-base-kit's checker
[positional-arguments]
check-kb *args:
    exec "{{tools}}/bin/check-kb" "$@"
```

A recipe with fixed arguments single-quotes each: `exec "{{tools}}/bin/check-kb" '--all' "$@"`.

Import it after any provider's own `.just` file, with `set allow-duplicate-recipes` (just then keeps the first of
two recipes with one name, so the provider's hand-written one runs; it calls the same wrapper from `tools`), and
define `tools` as the tools package's root:

```just
set allow-duplicate-recipes
import? ".patterns/notebook-kit/tools/kit.just"
import? ".patterns/kits.just"
tools := `nix build --no-link --print-out-paths .#tools`
```

Two recipes with one name fail evaluation: `pot: kitsFor: two recipes are named X (FILE and FILE)`; two kits that
ship one command, `pot: kitsFor: two kits ship a command named X (self and patterns.a): a wrapper has one name`.
A kit's recipe never replaces one of your own: when `kits.just` and the top `justfile`'s own recipes share a name,
`tuteur check` fails and `tuteur sync` warns: `tuteur: .patterns/kits.just's recipe X has the name of the justfile's own X:
rename one (a kit's recipe never replaces yours)`. (A provider's imported `.just` file is not yours: tuteur does not check it.) tuteur writes the file through a temporary file and refuses a link: `tuteur:
.patterns/kits.just is a symbolic link; tuteur writes only a file there: remove it, then tuteur sync` (the same for the
marker README; `tuteur check` reports it too).
`tuteur check` fails when the file differs from what the flake generates: `tuteur sync` writes it again. When the
bundle does not evaluate, sync leaves the file as it is: `tuteur: .patterns/kits.just: the flake's pot-kits doesn't
evaluate (above); left as it is`. With no `pot-kits` (no `inputs.pot`), sync writes none
(`tuteur: .patterns/kits.just: this flake has no pot-kits (no inputs.pot); not written`), and check fails on a
`kits.just` that is there. The header is pot's (pot-kits/1).

## `just` imports from a pattern

A justfile that imports a provider's recipes uses `import?` (with `?`), so a fresh clone with empty patterns
still parses: `import? ".patterns/notebook-kit/tools/kit.just"`. That holds only while no recipe of your own
depends on an imported one. A recipe `check: kit-check` makes `just` fail to parse when the import is missing
(`error: Recipe 'check' has unknown dependency 'kit-check'`), whatever recipe you ask for. Call the imported
recipe from the body instead, which `just` resolves only when it runs:

```just
import? ".patterns/notebook-kit/tools/kit.just"

check:
    just kit-check
```

## Nested patterns: the One-level cost

A provider's own submodules are filled recursively by `add`, `sync` and `upgrade` (git leaves them empty
otherwise, and Nix fails on an empty one while a tracked file is modified), and Nix fetches them on every
evaluation of a git flake. So each level costs every consumer a fetch, and a private or unpushed nested
submodule breaks consumers who cannot read it: a consumer of notebook-kit fetches knowledge-base-kit, then
living-specifications, then meta-knowledge-base. Keep providers to one level
([One level](../decisions.md#one-level)).

## In a provider

| File | Purpose |
|---|---|
| Tags | Semver tags (`v1.2.3` or `1.2.3`) are versions. Other tags, such as `v1.3.0-rc.1`, are ignored. A tag may be lightweight, annotated or signed. Never move a released tag: consumers' gitlinks point at its commit. |
| `CHANGELOG.md` | One `## vX.Y.Z` (or `## X.Y.Z`) section per release; anything can follow the version, such as the date. A major version's section has an `### Upgrading` subsection (tuteur also takes `### Migration`). tuteur reads it from the provider's repository at the target tag. |
| `pattern.nix` | Optional. What the provider contributes to a consumer's flake ([below](#patternnix)). |
| `USING.md` | Optional. The guide for the repositories that use the provider, which each consumer's marker README links ([below](#usingmd)). |
| `README.md` | What the provider is. A consumer's marker README links it when there is no `USING.md`. |
| `.gitattributes` | No longer read by tuteur. A consumer gets the whole repository. `export-ignore` lines still apply to `git archive`, if you use it. |

A consumer gets every committed file, so link only to files that exist in the repository, and keep a
provider's own agent instructions (`AGENTS.md`, `CLAUDE.md`) for work on the provider: a consumer's agent
reads the files that its own `AGENTS.md` points at, not the pattern's.

### USING.md

The provider's guide for an agent, or a person, in a repository that uses it: what the provider ships and how
to use it from there. Each consumer's [marker README](#the-marker-readme) links it, so a consumer's `AGENTS.md`
needs one line for every pattern, not a section each. Keep it short, and write it for a reader who knows only
their own repository:

- what it ships for the consumer: tools, `just` recipes, checks, and the settings file they read, such as
  `knowledge-base.yaml`;
- which of its docs to read for which task, as links relative to `USING.md`, to files in the repository;
- what the consumer owns and may change, and what it reads in place and must not.

A provider's `AGENTS.md` stays about work on the provider. tuteur reads only whether the file exists at the
pattern's recorded commit.

### pattern.nix

A function, called once per system by the consumer's mkFlake. Its versioned contract is
[provider/3](provider.md).

```nix
{ pkgs, lib, system, pattern, patterns, consumer, ... }:
{
  requires = { knowledge-base-kit = "https://github.com/danielnaab/knowledge-base-kit"; };
  tools    = { nb-index = pkgs.writeShellApplication { … }; };
  apps     = { check-kb = { type = "app"; program = "…"; }; };
  checks   = { tasks = pkgs.runCommand "tasks" { } "…"; };
  packages = { obsidian-plugins = …; };
  kit      = { tools = [ pkgs.ripgrep ]; requests.network = [ "api.example.com" ]; };
}
```

**Arguments.** Always passed, except `kitArgs`. Take `...`, so that a later tuteur version can add one. graft's
`scion` and `scions` are not passed since 0.3.0: a function that names one is an error
([provider/3](provider.md)). A pattern with no `pattern.nix` has its `tuteur.nix` read (the name before 0.2.1,
through 0.x); graft's `graft.nix` is not read since 0.3.0.

| Argument | Value |
|---|---|
| `pkgs`, `lib`, `system` | The consumer's `inputs.nixpkgs` if it has one, else tuteur's pinned nixpkgs. |
| `pattern` | This pattern, copied alone into the store, without its `.git` file. Relative paths (`./bin/tool`) resolve in it too. |
| `patterns` | Every pattern of the consumer. `patterns.NAME` is the pattern's store path (`"${patterns.NAME}/src"` works) merged with its `pattern.nix` result (`patterns.NAME.tools.TOOL`). |
| `consumer` | The consumer flake's source: the repository for a top-level flake, only the flake's directory for a `path:` flake. Checks read the consumer's settings from it, such as `${consumer}/knowledge-base.yaml`, and skip, not fail, when the file is absent. |
| `kitArgs` | The consumer's `perSystem.kitArgs.<pattern>` for this pattern, or `{ }`. A kit computes its requests from it, never from a file in the workspace. Passed only when the function names `kitArgs`. |

**Returned attributes.** All optional.

| Attribute | Becomes | Collision |
|---|---|---|
| `tools` | Part of `packages.<system>.tools`, on the consumer's `PATH` | An error, unless both are the same store path. |
| `apps` | `apps.<system>.<name>` | An error; `tuteur`, `sandbox`, `pot` and `pot-kits` are reserved. |
| `packages` | `packages.<system>.<name>` | An error; `tools`, `sandbox`, `pot` and `pot-kits` are reserved. |
| `checks` | `checks.<system>.<pattern>-<name>` | None: prefixed. |
| `kit` | The provider's [pattern kit](https://github.com/danielnaab/pot/blob/v0.1.0/docs/reference/pot.md#schema), in `packages.<system>.pot-kits` when the consumer has `inputs.pot`. Its `requests` apply only when a person grants them, in their root, with `pot grant`. | None: each kit keeps its own identity. |
| `requires` | Nothing. Checked first: each named pattern must exist, or evaluation fails with `tuteur add URL`. | |
| Anything else | Visible to other providers as `patterns.NAME.ATTR`, not a flake output. | |

- `requires` names other providers by their folder name, which is the URL's last segment, with the URL that
  the error tells the consumer to `tuteur add`. It has no version. A provider that needs a newer release of a
  sibling (one that first ships a tool it uses) releases a new major version of its own, and says so in its
  Upgrading steps. A consumer that renames a folder breaks `requires`, by design.
- Providers ship no dev shells. A consumer's `devShells.default` has every tool on `PATH`.
- Never read the provider's own patterns from `pattern.nix`: a git flake consumer has them, a `path:` flake
  consumer has them empty.
- A provider's own `flake.nix` and `flake.lock` are for work on the provider. Consumers never evaluate them.
  To pin something other than the consumer's nixpkgs, fetch it in `pattern.nix` with a fixed hash
  ([Write a provider's pattern.nix](../guides/write-tuteur-nix.md#pin-your-own-inputs)).

### Naming

A provider's name ends with what the content is, not the role that the repository plays:

| Suffix | Content | A consumer should |
|---|---|---|
| `-kit` | Something to adopt and keep upgrading: tools, skills, structure, often with the rules that they enforce | run or adopt it |
| `-conventions` | Rules only | comply with it |
| `-knowledge` | A knowledge base about a topic | read it |

- A repository that defines a named method takes that name, such as `living-specifications`.
- Do not use role words (`-provider`, `-pattern`), words that other tools own (`-pack`, `-bundle`,
  `-template`), or words that suggest a one-time copy (`-seed`, `-starter`).
- Give the repository the topic `tuteur-provider` on its forge (Forgejo or GitHub).
- Tool names share one `PATH` across every provider a consumer adds: start them with something of yours
  (`kb-lint`, not `lint`). App names share one namespace too. Check names are prefixed for you.

## tuteur's workflows

A file in `.forgejo/workflows/` is tuteur's when it has the name of a file in tuteur's
`template/.forgejo/workflows/` and contains the marker line:

```yaml
# managed by tuteur: https://github.com/danielnaab/tuteur (delete this line to keep your own edits)
```

tuteur renders its own copy with the lines that are yours: `branches:`, `paths-ignore` and `# tuteur ssh:`
(with the steps that it implies). The file must equal that rendering byte for byte.

- `upgrade` replaces the file when tuteur's pin moves.
- `sync` restores the pinned version's copy.
- `check` fails if the file differs.
- To keep your own edits, delete the marker line. tuteur then never reads or changes the file
  ([Keep your own edits to a workflow](#keep-your-own-edits-to-a-workflow)).
- tuteur never adds a workflow that you did not copy in.
- graft's workflows, `graft-check.yaml`, `graft-upgrade.yaml` and `graft-signers.yaml` with graft's marker
  (`# managed by graft: …`), are not renamed since 0.3.0 (tuteur 0.2.x's `sync` renamed them): `check` fails on
  one, since it runs `nix run .#graft`. Copy tuteur's `tuteur-` workflow in its place.

The workflows find the flake from the marker README: its directory's parent; two marker READMEs fail with
`::error::two patterns folders: … tuteur supports one per repository`. A flake in a subdirectory runs as
`path:$PWD/DIR`, and the check and upgrade jobs first fill its patterns (`git submodule update -q --init -- DIR`),
because a `path:` flake reads the working tree. A top-level git flake does not need that: Nix fetches the
patterns itself. tuteur-check's job is `patterns`, and its step is named `Patterns registered and at release tags`.
tuteur-upgrade's upgrade job pushes the branch `patterns/upgrade` (`tuteur/upgrade` before 0.3.0: the job deletes
that branch when it wrote it, which closes its pull request; see [ci](commands.md#ci)), and its pull request step
reads the token `secrets.TUTEUR_PR_TOKEN || secrets.GRAFT_PR_TOKEN || github.token` (graft's secret is still read: only
its owner can rename it).

`tuteur-signers.yaml` (since graft v2.21.0) runs [`ci signers`](commands.md#ci) on each push to the default branch and
each tag: report-only, it never fails. Its `branches:` line is yours, as tuteur-check's is; its step that runs
tuteur is `Signers (report-only)`. It needs `.forgejo/allowed_signers` in the repository: an ssh
`allowed_signers` file with principals such as `daniel@person`, `daniel@routine` and `agent@oak`. On tag pushes
it passes the forge event's account to the check as `PUSH_ACTOR`, separately from the verified tag signer.

### Keep your own edits to a workflow

1. Delete the marker line. Do this before you run `nix run .#tuteur sync`: while the marker is there, sync puts
   tuteur's copy back.
2. Make your edits. The comment below the old marker still says that tuteur replaces the file: change it
   too.
3. Run `nix run .#tuteur check`. It no longer reads the file.
4. Commit the workflow.

Without the marker, `upgrade` no longer replaces the file, so you get none of tuteur's later changes to it.
To take tuteur's copy again, put the marker line back as the first line and run `nix run .#tuteur sync`. It
prints `tuteur: refreshed .forgejo/workflows/FILE`, keeps the `branches:`, `paths-ignore:` and `# tuteur ssh:`
lines, and drops your other edits. tuteur does not stage the workflows, so `git restore` gets back an edit that
git had.

### The branches line

One line under the `push:` trigger of `tuteur-check.yaml`: the branches whose pushes run the check. tuteur's
copy has `branches: [main]`. If your default branch has another name, write it there:

```yaml
  push:
    branches: [v2]
```

A list of branch names on one line, with no comment after it. Names can contain letters, digits, `.`, `_`,
`/` and `-`.

### The paths-ignore line

One line under each of the `pull_request:` and `push:` triggers of `tuteur-check.yaml`, the same under both.
It skips tuteur-check for pushes that change only files that tuteur's check never reads, such as a notes
directory that a bot pushes to often:

```yaml
on:
  pull_request:
    paths-ignore: ["notebook/**", "drafts/**"]
  push:
    branches: [main]
    paths-ignore: ["notebook/**", "drafts/**"]
```

- A list of quoted globs on one line, indented four spaces, with no comment after it. Globs can contain
  letters, digits, `.`, `_`, `/`, `*`, `?` and `-`. `**` crosses directories. A run is skipped only when
  every changed file matches a glob.
- A block list, or two lines that differ, fail the check. If the line is under one trigger only, `sync`
  writes it under the other.
- tuteur refuses a glob that could match a file that tuteur-check reads: the patterns folder, `.gitmodules`,
  `flake.nix`, `flake.lock` (for a flake in a subdirectory, that whole directory) and `.forgejo/`. It also
  refuses a glob that starts with `*` or `/`. Name a directory.
- A pull request that changes only ignored files gets no tuteur-check status. Do not make that status
  required in branch protection.

### The tuteur ssh line

One comment line, for a private pattern that only an ssh key can read (graft's form, `# graft ssh: …`, is not read
since 0.3.0: it is a hand edit to the file)
([Add a private provider](../guides/private-providers.md)), in either workflow file. tuteur keeps it above
`name:`, and renders a step that installs the key before each step that runs tuteur: tuteur-check's check, and
tuteur-upgrade's upgrade and pr steps. In a file whose copy has no such step, the check fails with
`tuteur: X: its "# tuteur ssh:" line is kept only in a workflow with a step that runs tuteur, and this tuteur version's copy has none; delete the line`.

```yaml
# tuteur ssh: host=[git.example.com]:2222 address=192.168.1.51 hostkey=ssh-rsa AAAAB3NzaC1yc2E... secret=TUTEUR_SSH_KEY
```

| Field | Required | Meaning |
|---|---|---|
| `host` | yes | The host as the pattern's URL names it; `[host]:port` when the port is not 22. |
| `address` | no | The address that the host name resolves to, for a runner that cannot resolve it. |
| `hostkey` | yes | The host's public key, `TYPE KEY`, where `TYPE` is `ssh-ed25519`, `ssh-rsa` or `ecdsa-sha2-nistp256` (or `384`, `521`). Pinned: `StrictHostKeyChecking yes`. For Forgejo's built-in ssh server, `data/ssh/gitea.rsa.pub`. |
| `secret` | no | The Actions secret that holds the private key. Default `TUTEUR_SSH_KEY`, else graft's `GRAFT_SSH_KEY`, still read (`secrets.TUTEUR_SSH_KEY \|\| secrets.GRAFT_SSH_KEY`). |

The step writes the key to `~/.ssh/tuteur_patterns`, the host key to `~/.ssh/known_hosts` (under the host name
and the address), and a `Host` entry to `~/.ssh/config`, which both git and Nix's git fetcher read. On an
image with no ssh client, it takes `openssh` from Nix.

## Sources

- [lib/common.sh](../../lib/common.sh): finding the marker README; semver tags
- [lib/mk-flake.nix](../../lib/mk-flake.nix): the `pattern.nix` arguments, merging and collisions, `kit`
- [provider/3](provider.md): the `pattern.nix` contract
- [lib/workflows.sh](../../lib/workflows.sh): workflow ownership, the branches, paths-ignore and ssh lines
- [lib/tools.sh](../../lib/tools.sh): `add`, `upgrade` and `.gitmodules`
- [lib/common.sh](../../lib/common.sh) `upstream_range`, `changelog_between`: `CHANGELOG.md` read from the
  provider, and its headings
