---
status: living
---
# Decisions

Why tuteur is the shape it is. Each section is a decision that still holds. Change one only with a new
section that says what replaces it and why.

## Scope: Nix, git submodules, and a tag comparison

tuteur has no configuration file and no lock of its own. A pattern's pin is its gitlink, and tuteur's own pin is
in `flake.lock`. tuteur provides commands only. Automation, such as the weekly upgrade, is a workflow in the
repository or a central job that runs those commands. A feature that cannot be expressed as Nix, git
submodules, and a tag comparison does not belong in tuteur.

Why: graft v1 grew into a workflow runner as well as a dependency manager, and became hard to change.

One named flake input besides its own is in scope: a consumer's `pot` input, which `upgrade` moves by the same
rule as a pattern ([Two repositories](#two-repositories-tuteur-produces-kits-pot-runs-them)). tuteur is no
general input updater.

Until v2.13.0 this section read "Nix, a copy, a diff and a tag comparison": the copy and the diff went with
copy mode ([below](#pin-with-git-submodules-let-providers-wire-themselves)). From graft v2.14.0 to v2.22.0 it read
"Nix, git submodules, a tag comparison, and a sandbox policy": the sandbox, pot, went to its own repository in
tuteur 0.1.0.

## Pin with git submodules; let providers wire themselves

A pattern is a git submodule at a provider's release tag. The gitlink is the pin, and `.gitmodules` names the
source. Nix reads patterns through `inputs.self.submodules = true` (or from the working tree, for a `path:`
flake). Each provider's `tuteur.nix` contributes its tools, apps and checks, so a consumer's `flake.nix` names
no provider.

Why: in the twelve days of v2 copy mode, the measured cost was Nix's export hashing, not the copy. Lock
hashes that differed between Nix 2.24 and 2.34 broke checks in about ten repositories, and every fix to a
provider needed a release before any consumer could try it. Submodules remove the hash pin, and give agents an
edit-in-place loop: a pattern is a clone that can be fixed, tested and pushed upstream. graft v1's submodule
failures (empty directories in new clones, worktrees that could not be removed) are answered by Nix fetching
patterns itself, a post-checkout hook, `tuteur check`, and `git worktree remove --force`
([Clones, worktrees, sandboxes and CI](guides/clones-and-worktrees.md)).

Costs accepted:

- A pattern is the provider's whole repository, tests included: export rules no longer apply. The marker README
  keeps knowledge-base checkers out of the patterns folder.
- Nix fetches nested submodules, so [One level](#one-level) is now a rule, not only a convention.
- Nix 2.27 or later, for `inputs.self.submodules`.
- A git flake sees a pattern's uncommitted edits only while another tracked file is modified
  ([Nix behaviours](reference/nix-behaviours.md)). `tuteur try` turns that on and off on purpose, with a marker
  file that `tuteur check` refuses, so it never merges.

Reopen when Nix can apply a provider's export rules to a submodule (`exportIgnore` with `submodules`), or a
real consumer cannot use git.

This replaces two decisions of v2.0.0 to v2.12.0:

- **Commit the copy:** patterns were committed files, the provider's export copied into the tree, so that a
  fresh clone had them at once. Replaced because the copy needed a hash pin and a drift check, and gave no
  way to fix a provider in place. A git flake now fetches patterns itself, so a fresh clone builds anyway.
- **Let Nix fetch and pin:** each provider was a `flake = false` input, pinned by commit and `narHash` in
  `flake.lock`. Replaced because the `narHash` of an export differed between Nix versions and fetch caches.
  tuteur itself is still an ordinary flake input.

## One level

A consumer adds every provider that it uses directly, so it sees each pin in its own tree. A provider may
add another provider for its own use, but Nix fetches every nested submodule when it evaluates a consumer,
and ignores `update = none` and `active = false`. So **a provider must not add a repository that its
consumers cannot read**: the consumer's evaluation would fail. `tuteur add` and `tuteur check` say when a pattern
has submodules of its own.

Until v2.13.0, the rule was only that a provider did not export its own patterns.

## A breaking version is a person's decision

tuteur never crosses a breaking version by itself: a new major version, or, below 1.0, a new `0.y` series (as
Cargo reads semver: 0.3.1 moves to 0.3.4 by itself, never to 0.4.0). A provider declares a break with one, and
says what to do in its CHANGELOG. The weekly upgrade continues to take fixes, and the break waits for a person.
tuteur's own pin and a consumer's `pot` input follow the same rule.

## tuteur hands text to agents, and never runs one

`tuteur migrate` prints a brief, and the upgrade pull request carries the provider's notes. Any agent, or
a person, can take them, and tuteur does not change when agent tools change. Running an agent, in a sandbox, is
pot's ([pot](https://github.com/danielnaab/pot)).

## Declarations live in the files they describe

tuteur reads what is already in the repository instead of a list in a separate file: `.gitmodules` for the
patterns and their URLs, the marker README for the patterns folder and the flake, each provider's `tuteur.nix`
for its outputs, and marker lines in workflows (`# managed by tuteur`, `# tuteur ssh:`). A declaration in the
file cannot drift from it.

## Two repositories: tuteur produces kits, pot runs them

From graft v2.16.0 to v2.22.0, graft and pot shipped in one repository and one flake, with one-way arrows between
them, until the contracts at their seam held. They did, and tuteur 0.1.0 and pot 0.1.0 are two repositories:

- **pot depends on nothing of tuteur's.** It finds a repository's kits from git facts (`.gitmodules`, the
  gitlinks) and the flake's `pot-kits` output, never from tuteur's files or conventions.
- **tuteur only produces kits for pot**, and only for a consumer that takes pot as an input of its own
  (`inputs.pot`). mkFlake then calls `inputs.pot.lib.pot.kitsFor` ([pot-lib/1](https://github.com/danielnaab/pot/blob/v0.1.0/contracts/pot-lib-1.md))
  and hands it each kit unread. Without `inputs.pot` there is no `pot-kits`, the tools are not wrapped, there is
  no `kits.just`, and a unit that declares a kit gets one warning. tuteur's own flake never names pot.
- **tuteur re-exports nothing of pot's.** `lib.mkRoot`, `kits`, `apis` and `homeManagerModules.pot` are pot's
  flake's; the old names fail, naming it.
- **tuteur reads two things of pot's, both contracts:** `pot why URL --json` inside a run
  ([run-env/1](https://github.com/danielnaab/pot/blob/v0.1.0/contracts/run-env-1.md)), and the `Pot-Run:` trailer that `ci signers`
  looks for (pot's `trailer/1`). `ci signers` stays in tuteur for 0.1.0.
- **A consumer's `inputs.pot` does not follow the root's pot.** [pot-kits/1](https://github.com/danielnaab/pot/blob/v0.1.0/contracts/pot-kits-1.md) exists so
  that the pot that writes a bundle and the pot that reads it can be pinned apart. `tuteur upgrade` moves the
  consumer's `pot` input, by the patch-only rule below 1.0.

Why: "each must work well alone". With the seam's contracts stable, one repository only made a consumer that uses
tuteur alone lock pot, and mixed two products' releases in one tag line.

## Where graft v1's features went

graft v1 is on the read-only `v1` branch of graft's repository (2025-12 to 2026-10). Earlier experiments are on
`v0.2` and `v0.1` there. None of these features return:

| v1 | Now |
|---|---|
| `changes:`, migration commands, atomic upgrade with rollback | The upgrade pull request is the transaction: a branch, checked by the whole `nix flake check`, merged or closed. A breaking version declares a break, the CHANGELOG says what to do, and `tuteur migrate` writes a brief. |
| `commands:`, `graft run dep:command` | A provider's `tuteur.nix`: its tools go on the consumer's `PATH` through `packages.<system>.tools`, its apps and checks into the consumer's flake. A tool that is not tied to a pattern can be an ordinary flake input, as tuteur is. |
| State queries, run logs | The repository's own checks and CI. |
| Grove (a terminal UI for many repositories) | Out of scope. `nix run github:danielnaab/tuteur/v0.1.0 -- outdated -C <repo>` reads any checkout, and `tuteur status --json` ([status/1](../contracts/status-1.md)) is what a program like grove reads. |
| Scions as agent sessions | Agent tools outside tuteur. A pattern is another repository at a release tag. |
| Transitive dependencies (`.graft/` in `.graft/`) | One level. |
| Providers that place files anywhere in a consumer | Only tuteur's own workflows, by their marker. This waits for a second real case. |
