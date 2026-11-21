# tuteur

tuteur (say "too-TUR") holds your repository to patterns that other people maintain. It pins each provider's
pattern as a git submodule at a release tag, wires its tools, apps and checks into your Nix flake with no
provider-specific code, and brings each improvement as a pull request that you review.

Agents now write much of a team's knowledge base, faster than people can review it. The knowledge stays
trustworthy only if every change follows good rules, and the rules keep improving. A well-made set of rules
is worth reusing, but a copy stops improving. When its author tightens a rule or fixes the checker, your copy
never hears about it.

tuteur calls such a set of rules, agent instructions, tools and checks a **pattern**. A **provider**
repository publishes it, with version tags. tuteur adds the provider to your repository as a git submodule,
at one release, in the `.patterns/` folder. In gardening, a tuteur is the stake a young plant is trained on:
the plant grows freely, but it is tied in along the support, and a shoot that grows the wrong way is pruned.

tuteur was called graft until v2.22.0; [Move from graft v2](docs/guides/move-from-graft.md) is the one pull
request each graft consumer makes.

## An example: a knowledge base that agents write

[knowledge-base-kit](https://github.com/danielnaab/knowledge-base-kit) publishes one such pattern:

- **Policies.** A claim that drives a decision cites its sources. Every page has a status, such as draft,
  stable or deprecated.
- **Playbooks for agents.** Plan the change, make the smallest patch, then verify it.
- **Tools and a check.** `kb-lint` fails a page that has no status, or that cites no sources in a folder that
  needs them. `check-links` fails a link to a missing page or heading. The kit's `tuteur.nix` puts both on your
  `PATH` and in your `nix flake check`.

```
team-kb/
├── flake.nix                     # three lines: tuteur, and nothing about knowledge-base-kit
├── .gitmodules                   # .patterns/knowledge-base-kit = https://github.com/danielnaab/knowledge-base-kit
├── .patterns/knowledge-base-kit/ # a submodule, at the release tag v2.2.0
├── AGENTS.md                     # points agents at the kit's policies and playbooks
├── knowledge-base.yaml           # your settings: which folders need sources, which statuses a page may have
└── .forgejo/workflows/           # tuteur's check and weekly upgrade
```

## While pinned, the pattern governs each change

Your CI runs the pattern's checks on every pull request, and your forge can require them to pass before a
merge ([Make a pattern's checks gate your merges](docs/guides/gate-merges.md)). A change that follows the
pattern merges whole. One that does not is pruned: the check fails, and nothing merges until the change
follows the pattern.

Say an agent writes up last week's outage. The provenance policy tells it to cite the incident ticket and
the runbook it relied on. If the page cites neither, or links to a runbook heading that someone renamed, the
check fails and the page does not merge. The agent fixes the page, and it lands.

`tuteur check` keeps the patterns themselves fixed while you work: it fails unless every pattern is clean
and at a release tag, so every clone, worktree and agent session works by the same version of each pattern.

## When a pattern improves, taking it is a pull request too

The provider releases new versions on its own schedule, and says what changed in its CHANGELOG.

- **A patch release** (and, from 1.0, a minor one) should not break your repository. Each week, a Forgejo
  job moves each pattern to the newest such release, runs `nix flake check`, and opens a pull request that
  quotes the provider's CHANGELOG. You review it, and merge.
- **A breaking release** (a new major version, or a new `0.y` below 1.0) changes the pattern itself, so what
  already grew may need retraining. tuteur holds it back until a person takes it. `tuteur migrate` turns the
  provider's **Upgrading** steps, with the checks that now fail, into a brief for a person or an agent.

## When the pattern has a bug, fix it where you found it

A pattern is a real clone of the provider. You, or an agent, can fix a provider's bug in it, run the provider's
tests there, build your repository with it (`tuteur try`, then `tuteur try --stop`), and push the fix to the
provider as a branch. `tuteur check` keeps the unreleased fix from merging; when the provider releases it, every consumer takes it as an upgrade
([Fix a provider from a consumer](docs/guides/fix-a-provider.md)).

## What tuteur adds to plain submodules

git submodules give you a pinned clone. tuteur adds what makes them a dependency you can maintain:

- **Release-tag pins, checked.** `tuteur add` and `tuteur upgrade` move a pattern only to a semver tag, and
  `tuteur check` fails on a pattern that is dirty, away from its gitlink, or on an unreleased commit.
- **A provider fix, tried in place.** `tuteur try` makes your builds use a pattern's uncommitted edits, which a
  git flake otherwise ignores, and says what each build will see and how to make new files visible;
  `tuteur try --stop` undoes it.
- **Breaking versions are a person's decision.** Upgrades stay in each series (a major version; below 1.0, a
  `0.y`) unless you name the new one.
- **Upgrade pull requests** that quote each provider's CHANGELOG, Upgrading sections first, checked by your
  whole `nix flake check`.
- **Migration briefs**: what moved, what the provider says, which of your files name a moved path, which
  checks fail.
- **Provider wiring.** Each provider's `tuteur.nix` contributes tools, apps and checks; your `flake.nix` names
  no provider.
- **Empty folders answered.** Nix fetches patterns itself for a git flake while its tree is clean, a
  post-checkout hook that the guide gives fills them in new clones and worktrees, and `tuteur sync` fills them
  ([Clones, worktrees, sandboxes and CI](docs/guides/clones-and-worktrees.md)).
- **An agent rule** for working with patterns, ready to paste into `AGENTS.md`.
- **Kits for pot.** A provider's `tuteur.nix` may return a `kit` for [pot](https://github.com/danielnaab/pot),
  which runs agents and commands in a sandbox. tuteur hands it to pot unread, when your flake takes pot as an
  input of its own ([Declare kit commands](docs/guides/kit-commands.md)). tuteur depends on nothing of pot's.

Compared with the other ways:

- **Copying files, or git subtree,** records no pin that a tool can check, and gives no way to send a fix back.
- **Templates** (Copier, cookiecutter) generate files that you then own. Use a template for the pages that you
  own, and a pattern for the rules that they follow.
- **Dependency bots** (Renovate, Dependabot) move pins and quote release notes. Renovate's submodule support
  follows a branch, not semver tags, and has no gate on breaking versions and no migration brief.

## Quick start

Nix 2.27 or later, with flakes. In a git repository:

```
nix flake init -t github:danielnaab/tuteur/v0.1.0
```

It writes tuteur's CI workflows and this `flake.nix`:

```nix
{
  inputs.self.submodules = true;
  inputs.tuteur.url = "github:danielnaab/tuteur/v0.1.0";
  # Where agents or kit commands run under pot, take pot too (mkFlake then builds pot-kits):
  #   inputs.pot.url = "github:danielnaab/pot/v0.1.0";
  outputs = inputs: inputs.tuteur.lib.mkFlake { inherit inputs; };
}
```

Then add a provider's pattern, and commit:

```
nix run .#tuteur add https://github.com/danielnaab/knowledge-base-kit
git commit -m "Add knowledge-base-kit"
```

Its tools are in `nix shell .#tools`, its checks in `nix flake check`. Next:
[Add your first pattern](docs/guides/add-a-pattern.md).

- A flake at the repository's top copies every file that git tracks into the Nix store, which every user of
  the machine can read. To keep private files out of it, put the flake in a subdirectory, and run its own
  command, such as `nix run 'path:nix/agent-tools#tuteur'`
  ([Keep private files out of the Nix store](docs/guides/flake-in-a-subdirectory.md)).
- On GitHub, run `nix run .#tuteur ci check` and `ci upgrade` from your own workflows
  ([Run tuteur in CI and review its upgrade pull requests](docs/guides/ci.md)).
- Coming from graft v2? [Move from graft v2](docs/guides/move-from-graft.md).

## Publish a pattern

Any repository with semver tags can be a provider:

- Tag each release with a semver tag on your default branch, and give it a `CHANGELOG.md` section.
- Release a breaking change as a new major version (below 1.0, a new `0.y`), with **Upgrading** steps that a person or agent can
  follow without knowing your repository's internals.
- To give consumers tools and checks, add a `tuteur.nix`.

See [Publish a pattern](docs/guides/publish.md), [Write a provider's tuteur.nix](docs/guides/write-tuteur-nix.md),
and [Ship and take a breaking change](docs/guides/incompatible-change.md).

## Documentation

| Who, doing what | Read |
|---|---|
| Anyone: the terms, and how they map to git and Nix | [Concepts](docs/concepts.md) |
| Consumer of graft v2: move to tuteur | [Move from graft v2](docs/guides/move-from-graft.md) |
| Consumer: add a first pattern | [Add your first pattern](docs/guides/add-a-pattern.md) |
| Anyone: clone, make a worktree, run CI with patterns | [Clones, worktrees, sandboxes and CI](docs/guides/clones-and-worktrees.md) |
| Person or agent: fix a provider's bug from a consumer, and upstream it | [Fix a provider from a consumer](docs/guides/fix-a-provider.md) |
| Consumer: find and fix what fails `tuteur check` or a build | [`tuteur check` fails](docs/guides/check-fails.md) |
| Consumer: run a pattern's checks in CI, and require them before a merge | [Make a pattern's checks gate your merges](docs/guides/gate-merges.md) |
| Consumer: take the weekly upgrade pull request | [Run tuteur in CI and review its upgrade pull requests](docs/guides/ci.md), and why it is safe: [CI security](docs/ci-security.md) |
| Consumer: take newer versions outside CI | [Take a newer version by hand](docs/guides/upgrade.md) |
| Both: release or take a breaking change (a new major, or a new `0.y`) | [Ship and take a breaking change](docs/guides/incompatible-change.md) |
| Consumer: keep private files out of the Nix store | [Keep private files out of the Nix store](docs/guides/flake-in-a-subdirectory.md) |
| Consumer: add a provider that only an ssh key can read | [Add a private provider](docs/guides/private-providers.md) |
| Provider: release a version | [Publish a pattern](docs/guides/publish.md) |
| Provider: ship tools, apps and checks | [Write a provider's tuteur.nix](docs/guides/write-tuteur-nix.md) |
| Provider: hand pot a kit; consumer: import `kits.just` | [Declare kit commands](docs/guides/kit-commands.md) |
| Anyone: run an agent or a command in a sandbox | [pot](https://github.com/danielnaab/pot), its own repository |
| Look up a command, flag, `mkFlake` argument or error | [Commands](docs/reference/commands.md) |
| Look up a file tuteur reads or writes, or the `tuteur.nix` contract | [Files](docs/reference/files.md) |
| Look up a format that tuteur shares with other programs | [provider/3](docs/reference/provider.md), [status/1](contracts/status-1.md), and pot's: [pot's contracts](https://github.com/danielnaab/pot/blob/v0.1.0/contracts/README.md) |
| Know how Nix sees a pattern | [Nix behaviours](docs/reference/nix-behaviours.md) |
| Know why tuteur is this small | [Decisions](docs/decisions.md) |
| Change tuteur itself | [Development](docs/development.md) |
| graft's history, and its guides for moving between v2 versions | [graft's repository](https://github.com/danielnaab/graft) (archived) and this [CHANGELOG](CHANGELOG.md) |

Releases and upgrade steps are in the [CHANGELOG](CHANGELOG.md).
