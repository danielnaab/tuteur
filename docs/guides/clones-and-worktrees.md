---
status: working
---
# Clones, worktrees, sandboxes and CI

A new clone or worktree of a consumer has empty pattern folders until something fills them. Know what still
works when they are empty, fill them where it matters, and set up your machine so that it happens by itself.

## When to use this

- `ls .patterns/NAME` prints nothing, after `git clone`, `git worktree add`, or in an agent sandbox or CI job.
- `just` does not list a provider's recipes, or a tool that reads `.patterns/…` in the working tree fails.
- `nix build 'path:…'` warns `tuteur: … are empty in the flake's source`, or a git flake build fails
  with `error: Failed to fetch git repository '…/patterns/NAME'`.
- `git worktree remove` fails with `fatal: working trees containing submodules cannot be moved or removed`.

## What works with empty patterns

| Use | Empty patterns |
|---|---|
| A top-level git flake: `nix build .#tools`, `nix flake check`, `nix run .#tuteur …`, with no tracked file modified | Works, if every pattern's commit is on its provider's remote: Nix fetches each pattern at its gitlink from the URL in `.gitmodules`, before tuteur runs. Otherwise `nix run github:danielnaab/tuteur/v0.2.1 -- check -C .` still runs. |
| The same, after any tracked file is modified (an agent's first edit, a CI step that writes a file) | Fails inside Nix: `error: Failed to fetch git repository '…/patterns/NAME'`. Nix reads the working tree, and the pattern is empty. `nix run .#tuteur sync` cannot run either, because the flake does not evaluate: run `git submodule update --init --recursive` first. |
| `nix run github:danielnaab/tuteur/v0.2.1 -- outdated -C .` and the other `-C` commands | Works: tuteur reads `.gitmodules` and the gitlinks. |
| A `path:` flake in a subdirectory | `tools` builds without the empty patterns, with a warning; a provider that needs one fails. Fill the patterns first. |
| Reading a pattern's files, agents following them, `PYTHONPATH=.patterns/…` | Nothing to read. Fill the patterns first. |
| `just` with `import? ".patterns/…"` | Lists your own recipes, without the provider's. With `import` (no `?`), `just` fails to parse. |
| `tuteur check` | Fails: `.patterns/NAME is empty: …`. `tuteur ci check` does not need filled patterns. |

## Fill the patterns

Any one of these, from the repository's top:

```
git submodule update --init --recursive   # git alone
nix run .#tuteur sync                      # the same, and rewrites the marker README and tuteur's workflows
git clone --recurse-submodules URL        # at clone time
```

They fill the patterns at their gitlinks, and the patterns' own submodules too. Fill those as well: without
`--recursive`, git leaves them empty, and a build with any tracked file modified then fails on them
(`tuteur check` says `.patterns/NAME's own submodules are empty`). For a shallow clone, add `--depth 1` to `git submodule update`. To fill only some
patterns, name them: `git submodule update --init --recursive -- .patterns/notebook-kit`.

A private pattern needs a key that can read it ([Add a private provider](private-providers.md)). Where
there is none, name only the public patterns.

## Set up your machine once

Git can fill patterns in new clones and worktrees by itself, and refuse a push that would break builds. With
Home Manager, in `programs.git.extraConfig`:

```nix
{
  push.recurseSubmodules = "check";    # refuse to push a gitlink whose commit is on no remote
  status.submoduleSummary = true;      # git status shows pattern moves
  diff.submodule = "log";              # diffs list the provider commits that a pattern move takes
  hook.tuteur-populate = { event = "post-checkout"; command = "${tuteurPopulate}"; };
}
```

with the hook, for example in a `let`:

```nix
tuteurPopulate = pkgs.writeShellScript "tuteur-populate" ''
  # post-checkout: fill the submodules of a new worktree or clone (previous HEAD all zeros).
  # Never fails the checkout: git would report the clone or worktree add as failed.
  case $1 in 0000000000000000000000000000000000000000) ;; *) exit 0 ;; esac
  [ -f .gitmodules ] || exit 0
  [ -z "$(git rev-parse --show-superproject-working-tree)" ] || exit 0   # not for a submodule's own checkout
  git submodule update --init --recursive --quiet ||
    echo "tuteur-populate: could not fill submodules; run git submodule update --init --recursive" >&2
  exit 0
'';
```

Without Home Manager, the same with `git config --global`:

```
git config --global push.recurseSubmodules check
git config --global status.submoduleSummary true
git config --global diff.submodule log
git config --global hook.tuteur-populate.event post-checkout
git config --global hook.tuteur-populate.command ~/.local/bin/tuteur-populate
```

with the script above saved as `~/.local/bin/tuteur-populate` and made executable.

- The hook runs on `git clone` and `git worktree add`, beside any repository's own `core.hooksPath` hook,
  in every repository with a `.gitmodules`, tuteur's or not. When a fetch fails (offline, a private pattern
  without its key), it prints a warning and the checkout still succeeds: run `git submodule update --init --recursive`
  later.
- **Do not set `submodule.recurse = true`.** With it, a checkout, switch or pull of the parent that moves a
  pattern's gitlink also checks out the pattern, and discards uncommitted edits in it without a word: an agent
  fixing a provider in place loses its work. Without it, the pattern stays where it is after a pull, and
  `tuteur check` reports it (`.patterns/NAME is checked out at X but the repository records Y`); move it on
  purpose with `git submodule update --init --recursive -- .patterns/NAME`.
- Even without it, commit (or stash) in a pattern before you switch the parent's branch, and run
  `git submodule update --init --recursive` after.
- Config-based hooks (`hook.<name>.event`) need git 2.54 or later. On older git, run `nix run .#tuteur sync`
  after a clone or `worktree add`.
- `push.recurseSubmodules=check` stops you pushing a consumer whose gitlink points at a pattern commit that you
  have not pushed to the provider: Nix could not fetch it, and every build would fail. It also refuses a
  gitlink at a commit that only a tag reaches (no branch of the provider contains it), which Nix fetches
  fine; `git push --recurse-submodules=no` then pushes. Providers that tag on their default branch never
  hit this.

## Worktrees

- `git worktree add ../repo-topic -b topic` gives empty patterns, which the hook fills.
- `git worktree remove ../repo-topic` refuses a worktree with filled patterns. Use
  `git worktree remove --force ../repo-topic`. It deletes uncommitted work in the worktree, the patterns'
  included: commit or push what you need first.
- Tools that manage worktrees for you (workmux, for example) call `git worktree remove`: set them to force, or
  remove the worktree yourself.

## Agent sandboxes and cloud environments

Add the fill to the environment's setup script, after the checkout:

```
git submodule update --init --recursive --depth 1
```

Without it, agents see empty `.patterns/` folders, and the rules in them are missing. [pot](https://github.com/danielnaab/pot)
runs in your checkout, with the patterns that it has: fill them before the run
([Run commands in pot](https://github.com/danielnaab/pot/blob/v0.1.0/docs/guides/run-in-a-sandbox.md)). An environment with no network
after setup must fill the patterns during setup.

## CI

- **tuteur's Forgejo workflows** fill the patterns where it is needed (a flake in a subdirectory), and leave it
  to Nix for a top-level flake.
- **GitHub Actions:** `actions/checkout` with `submodules: recursive`. For a private pattern, also pass an `ssh-key`
  that can read it.
- **Automation that clones or pulls** (a systemd pull timer, a workflow engine's job, a bootstrap script for
  a new machine): clone with `--recurse-submodules`, and run `git submodule update --init --recursive --quiet` after each
  pull or fast-forward. Do not rely on the machine's hook: a service may not read the user's git config, and
  a new machine has none yet. Until the patterns are filled, a `path:` flake builds
  `tools` without them, and a git flake build fails once the job modifies a tracked file.

## Check it worked

From the top of a new clone or worktree, paste this. It prints `ok` only if every pattern is filled and at
its gitlink:

```sh
test -z "$(git submodule status | grep -v '^ ')" && nix run '.#tuteur' check && echo ok
```

`git submodule status` starts a line with `-` for an empty pattern and `+` for one away from its gitlink.

## Sources

- [lib/tuteur.sh](../../lib/tuteur.sh): `sync`.
- [template/.forgejo/workflows/](../../template/.forgejo/workflows/tuteur-check.yaml): the checkout step.
- [tests/run.sh](../../tests/run.sh): `sync` fills patterns and not nested ones.
- [tests/fixtures.sh](../../tests/fixtures.sh) `worktrees`: the repositories this page was read against.
- [Nix behaviours](../reference/nix-behaviours.md): a fresh clone builds; `path:` reads the working tree; nested
  patterns.
