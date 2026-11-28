---
status: working
---
# Keep private files out of the Nix store

Put the repository's flake, and its patterns, in a subdirectory, and use it as a `path:` flake, so that Nix
copies only that directory, and never your private files, into the Nix store.

## Before you begin

- Why: Nix copies a flake's source into the Nix store, and every user of the machine can read the store. For
  a flake at the repository's top, the source is every file that git tracks, with uncommitted edits, and
  every `nix run .#tuteur`, `nix build` and `nix flake check` copies them again. A `path:` flake in a
  subdirectory copies only that directory.
- What changes:
  - The patterns live **under** the flake's directory, such as `nix/agent-tools/.patterns/`: a `path:` flake
    cannot see anything outside its directory.
  - A `path:` flake reads the working tree, so patterns must be filled. In a fresh clone, `tools` builds
    without them, with a warning, until you run `git submodule update --init --recursive`.
  - Your flake's checks cannot read files outside the directory: a provider's check of your pages skips
    ([Make a pattern's checks gate your merges](gate-merges.md#a-flake-in-a-subdirectory)).
- The steps use `nix/agent-tools` for the subdirectory and `.patterns` for the patterns folder. Use your own
  names. Keep no other files in the subdirectory: Nix copies all of them.
- The commands quote `'path:nix/agent-tools#tuteur'`, as [The tuteur command](../reference/commands.md#the-tuteur-command)
  says.

## Steps

Run every command from the repository's top. Never run `nix run .#tuteur`, `nix flake check`, `nix develop`
or direnv's `use flake` inside `nix/agent-tools/`, and never use a `git+file:` reference to the repository:
those are git flakes, which copy the whole repository.

1. Make the subdirectory, and write a flake in it:

   ```
   mkdir -p nix/agent-tools
   ```

   `nix/agent-tools/flake.nix`:

   ```nix
   {
     description = "This repository's agent tools";
     inputs.tuteur.url = "github:danielnaab/tuteur/v0.3.0";
     outputs = inputs: inputs.tuteur.lib.mkFlake { inherit inputs; dir = ".patterns"; };
   }
   ```

   No `inputs.self.submodules`: a `path:` flake copies the working tree, patterns included. If the repository
   had a flake at the top, move it (`git mv flake.nix flake.lock nix/agent-tools/`) and edit it the same way.

2. Lock it, by its absolute path:

   ```
   git add nix/agent-tools/flake.nix
   nix flake lock "path:$PWD/nix/agent-tools"
   ```

   It prints `warning: creating lock file '…/nix/agent-tools/flake.lock'`.

3. Add a provider into the subdirectory's patterns folder:

   ```
   nix run 'path:nix/agent-tools#tuteur' -- add --patterns nix/agent-tools/.patterns https://github.com/danielnaab/knowledge-base-kit
   ```

   ```
   tuteur: nix/agent-tools/.patterns/knowledge-base-kit <- v2.2.0 (abc1234)
   ```

   It writes `nix/agent-tools/.patterns/README.md`, the marker that tells tuteur where the flake is. Later `add`
   commands find the directory by it, and need no `--patterns`.

4. Put tuteur's workflows at the top, where Forgejo reads them:

   ```
   (cd nix/agent-tools && nix flake init -t github:danielnaab/tuteur/v0.3.0)
   mkdir -p .forgejo/workflows && mv -n nix/agent-tools/.forgejo/workflows/*.yaml .forgejo/workflows/ && rm -r nix/agent-tools/.forgejo
   ```

   `nix flake init` refuses to overwrite your `flake.nix` and exits 1: expected. Skip this step on GitHub.

5. Check it, and build the tools:

   ```
   nix run 'path:nix/agent-tools#tuteur' check
   nix build 'path:nix/agent-tools#tools'
   ```

   `tuteur check` prints `tuteur: 1 pattern clean and at release tags`.

6. Commit the flake, the patterns and the workflows, and nothing else:

   ```
   git add nix/agent-tools .gitmodules .forgejo
   git commit -m "Put the flake and its patterns in nix/agent-tools"
   ```

7. Point paths at the new place: `AGENTS.md`, `just` imports (`import? "nix/agent-tools/.patterns/…"`),
   hooks, and tools' settings that named a pattern.

## Check it worked

From the repository's top, paste this. It prints `ok` only if the patterns are clean and at releases, no flake
is left at the top, everything is committed, and the store copy of the flake is exactly `nix/agent-tools/`,
with nothing from the rest of the repository:

```sh
nix run 'path:nix/agent-tools#tuteur' check && test ! -e flake.nix && test -z "$(git status --porcelain -- nix/agent-tools .gitmodules)" && src=$(nix eval --raw --impure --expr "(builtins.getFlake \"path:$PWD/nix/agent-tools\").outPath") && diff -r "$src" nix/agent-tools && echo ok
```

## If something goes wrong

- **`warning: tuteur: .patterns/knowledge-base-kit, … are empty in the flake's source, so the tools leave out what they give: run git submodule update --init --recursive (or tuteur sync)`.**
  A fresh clone or worktree: the tools build without those providers. Run `git submodule update --init --recursive`. To fill patterns on every clone, see
  [Clones, worktrees, sandboxes and CI](clones-and-worktrees.md).
- **`error: cannot fetch input 'path:nix/agent-tools' because it uses a relative path`.** Nix 2.24 needs
  the absolute path to write the lock: do step 2.
- **`error: path '/…/REPO' is not part of a flake`.** You ran `nix run .#tuteur` or `nix flake check` at the
  top. Write `'path:nix/agent-tools'` for `.`.
- **`tuteur: two patterns folders: A, B; tuteur supports one per repository`.** An old patterns folder at
  the top still has the marker README. Remove it (`git rm -r .patterns`), and commit.

## How it works

| To | Run |
|---|---|
| Fill the patterns | `git submodule update --init --recursive`, or `nix run 'path:nix/agent-tools#tuteur' sync` |
| Check | `nix run 'path:nix/agent-tools#tuteur' check` |
| Build the tools | `nix build 'path:nix/agent-tools#tools'` |
| Upgrade | `nix run 'path:nix/agent-tools#tuteur' upgrade` |
| Lock again after an edit to `flake.nix` | `nix flake lock "path:$PWD/nix/agent-tools"` |
| Run a command from tuteur's own flake | `nix run github:danielnaab/tuteur/v0.3.0 -- outdated -C .` |

- **Always write `path:`.** `.` inside the subdirectory, `./nix/agent-tools` and `git+file:` references are
  git flakes, which copy the whole repository.
- **tuteur finds the flake from the marker README**: the patterns folder's parent. It finds the top with git,
  so the app runs from anywhere in the checkout.
- **A `path:` build always reads the working tree**, pattern edits included. That makes trying a provider fix
  simple ([Fix a provider from a consumer](fix-a-provider.md)), and means `tuteur check` is the only thing
  that stops an unreleased pattern from being committed.
- **A tool rebuild after an upgrade.** A script that caches the tools' build must include the patterns'
  gitlinks in its cache key, for example
  `(cat nix/agent-tools/flake.nix nix/agent-tools/flake.lock; git submodule status -- nix/agent-tools/.patterns) | cksum`.
- **In CI**, tuteur's workflows fill the patterns before they evaluate a flake in a subdirectory.

### Remove old copies

1. Find them. Search for a line that only your private files hold, in the store paths that a flake
   (`-source`) or a `src = ./.` (named after the repository's folder) makes. It can take minutes:

   ```
   find /nix/store -mindepth 1 -maxdepth 1 -type d \( -name '*-source' -o -name "*-$(basename "$PWD")" \) -exec grep -rlF 'THE LINE' {} + 2>/dev/null
   ```

2. For each store path that it names, `nix-store --query --roots PATH` prints what keeps it. Nothing
   printed means that nothing does.
3. Delete each with `nix store delete PATH`. `nix store gc` deletes every unused path on the machine
   instead.

## Related

- [Add a private provider](private-providers.md): a provider that only an ssh key can read.
- [Run commands in pot](https://github.com/danielnaab/pot/blob/v0.1.0/docs/guides/run-in-a-sandbox.md): `pot CMD`, from the repository's top.
- [Nix behaviours](../reference/nix-behaviours.md#path-flakes-in-a-subdirectory), [Commands](../reference/commands.md#mkflake).

## Sources

- [lib/mk-flake.nix](../../lib/mk-flake.nix): `dir`, the empty-pattern error.
- [lib/common.sh](../../lib/common.sh): finding the flake from the marker README.
- [lib/tools.sh](../../lib/tools.sh): `add --patterns`.
- [template/.forgejo/workflows/](../../template/.forgejo/workflows/tuteur-check.yaml): how CI finds the flake
  and fills the patterns.
- [tests/run.sh](../../tests/run.sh): the `path:` subdirectory checks, and "the top's content never entered
  the store".
- [tests/fixtures.sh](../../tests/fixtures.sh) `private`: the repositories this page is read against.
