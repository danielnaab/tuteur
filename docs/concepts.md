---
status: working
---
# Concepts

tuteur holds your repository to other repositories' patterns: it pins each as a git submodule at a release
tag, and wires what it ships into your Nix flake. This page defines the terms, maps graft's words to them, then
shows how they map to git and Nix. For why tuteur works this way, see [Decisions](decisions.md).

## What a provider publishes

- **Pattern:** what a provider publishes, at a version: rules, agent instructions, tools and checks.
- **Provider** and **consumer** are roles, not kinds of repository. A provider publishes a pattern. A consumer
  pins others' patterns. Most repositories are both.
- **Version:** a semver tag, such as `v1.2.3` or `1.2.3`. A **breaking version** means that the provider changed
  something incompatibly: a new major version, or, for `0.y.z`, a new `0.y` series (each counts as its own
  major, as Cargo reads semver). Other tags, such as `v1.3.0-rc.1`, are not versions.
- **Changelog:** the provider's `CHANGELOG.md`, with one section per version. A breaking version's section has
  **Upgrading** steps that a person or agent can follow with knowledge of the consumer only.
- **`tuteur.nix`:** an optional file at the top of the provider's repository. It tells a consumer's flake
  which tools, apps, checks and packages the provider contributes, and which other providers it needs
  ([Write a provider's tuteur.nix](guides/write-tuteur-nix.md)). A provider without one (rules and docs only)
  is still a provider.

## What a consumer holds

- **A pattern, pinned:** a git submodule in the patterns folder, at `<dir>/<name>`. It holds the provider's
  whole repository, checked out at a release tag ("the knowledge-base-kit pattern, at v2.2.0"). The folder name
  is the provider's name.
- **Patterns folder:** one folder, `.patterns/` by default, beside the consumer's `flake.nix`: hidden, like
  `.git/`, because it holds repositories you don't edit. It holds the submodules and tuteur's **marker
  README**, `<dir>/README.md`. tuteur writes that README, and finds the patterns folder and the flake by it.
  Its text is the same in every repository.
- **Pin:** the **gitlink**, the commit that the consumer's tree records for the submodule. `.gitmodules`
  holds the provider's URL. There is nothing else: no lock file of tuteur's own, and no provider entry in
  `flake.lock`.
- **Pinned version:** the highest semver tag upstream that points at the gitlink. tuteur works it out each
  time, and never records it.
- **At a release:** a pattern is at a release when its gitlink is the commit of a version tag. `tuteur check`
  fails on a pattern that is not, so an unreleased fix cannot merge by accident.
- **tuteur's own pin:** a consumer also pins tuteur, as an ordinary flake input, `inputs.tuteur` (or
  `inputs.graft`, graft's name, which tuteur reads through 0.x), in `flake.lock`. It moves the same way as the
  patterns. So does a consumer's `inputs.pot`, when it has one at a version tag.
- **One level:** a consumer adds every provider that it uses directly. A provider may add others, but Nix
  then fetches those too when it evaluates the consumer, so a provider must not add a repository that its
  consumers cannot read.

## How things change

- **Add:** `tuteur add URL` makes a new pattern at the newest release, and writes the marker README.
- **Sync:** `tuteur sync` fills empty patterns (`git submodule update --init --recursive`), writes the marker README, and
  refreshes tuteur's workflows. It never moves a pin.
- **Check:** `tuteur check` fails unless every pattern is registered, filled, clean, checked out at its gitlink,
  and at a release.
- **Upgrade:** a pin moves to a newer tag; within its series unless a person names a breaking version. In CI,
  the consumer's checks run on the result in a pull request, and a person merges it. tuteur's own pin moves
  first, so the rest of the upgrade runs the new version.
- **Migration brief:** after an upgrade, `tuteur migrate` prints what moved, what the provider's changelog
  says, which of your files name a moved path, and which checks fail. A person or an agent does the
  migration. tuteur never chooses to run an agent.
- **Fix in place:** a pattern is a real clone. You or an agent can fix a provider bug in it, push the fix to
  the provider, and take it as a release ([Fix a provider from a consumer](guides/fix-a-provider.md)).

## Kits, for pot

[pot](https://github.com/danielnaab/pot) runs agents and commands in a sandbox; it is its own repository, and
tuteur depends on nothing of it. A provider's `tuteur.nix` may return a `kit` for pot (and a consumer's
`perSystem` its own); tuteur hands each to pot unread, through pot's library, when the consumer's flake takes pot
as an input of its own (`inputs.pot`). The result is `packages.<system>.pot-kits`, which pot reads at a run's
start. Without `inputs.pot`, there is none ([Declare kit commands](guides/kit-commands.md)).

## graft's words

tuteur was graft until v2.22.0. The nouns that changed:

| graft | tuteur |
|---|---|
| graft (the product and command) | tuteur |
| scion (a pattern, pinned in a consumer) | pattern |
| `scions/`, `.scions/` (the scions directory) | `.patterns/` (the patterns folder) |
| `graft.nix` (provider/2) | `tuteur.nix` (provider/3) |
| `scion`, `scions` (a provider's arguments) | `pattern`, `patterns` |
| a new major version | a breaking version (a new major, or a new `0.y`) |
| `graft-check.yaml`, `graft-upgrade.yaml`, `graft-signers.yaml` | `tuteur-check.yaml`, `tuteur-upgrade.yaml`, `tuteur-signers.yaml` |

tuteur 0.2.x still reads graft's names; `tuteur check` says which this repository uses, and 0.3.0 drops them
([Move from graft v2](guides/move-from-graft.md)).

## The git and Nix binding

| Concept | In git and Nix |
|---|---|
| Pattern | A submodule: an entry in `.gitmodules` (path and URL) and a gitlink (mode `160000`) in the tree. |
| Pin | The gitlink. `git ls-files -s .patterns/NAME` prints it. |
| Version | A semver git tag on the provider. tuteur reads tags with `git ls-remote --tags URL`. |
| Patterns in a build | A git flake with `inputs.self.submodules = true;` has each submodule in its source (`${inputs.self}/.patterns/NAME`). Nix fetches **every** submodule in the repository then, not only patterns, so each must be readable. A `path:` flake copies the working tree, submodules included. |
| A pattern in the Nix store | mkFlake copies each pattern alone (`pattern-NAME`), so a tool's store path does not change when an unrelated file of the consumer changes. |
| Provider outputs | Each pattern's `tuteur.nix`, called once per system. Its `tools` become `packages.<system>.tools`, one environment; its checks become `checks.<system>.<pattern>-<name>`. |
| Patterns folder | `<dir>/`, where `dir` is a `mkFlake` argument, default `.patterns`, beside `flake.nix`. |
| tuteur's pin | The flake input named `tuteur` (else `graft`). |
| Kit | A provider's `tuteur.nix` and `perSystem` can return `kit`. With `inputs.pot`, mkFlake passes them to `inputs.pot.lib.pot.kitsFor`, which writes the workspace's kits and tools as `packages.<system>.pot-kits`; `pot` builds it with `path:`. Each declared command becomes a wrapper in `tools`, which runs it in pot under its own policy, and the kits' `recipes` become `<dir>/kits.just`. |

Nix and git see a pattern differently, and one difference matters every day: a git flake's build reads a pattern
at its **committed** gitlink while the rest of your tree is clean, and from your working tree once any tracked
file is modified ([Nix behaviours](reference/nix-behaviours.md)). So test a provider fix with the provider's
own tests, inside the pattern; build your repository with it under [`tuteur try`](reference/commands.md#try),
which makes every build read the working tree until `tuteur try --stop`; and let `tuteur check` keep
unreleased patterns (and try's marker) from merging.

tuteur adds, checks, moves tags, wires outputs and hands kits to pot, and does nothing more. The limits and their reasons are in [Decisions](decisions.md#scope-nix-git-submodules-and-a-tag-comparison).
