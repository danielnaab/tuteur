---
status: working
---
# Move from graft v2

graft is now two repositories: tuteur, which pins patterns, and [pot](https://github.com/danielnaab/pot), which
runs agents and commands in a sandbox. Move a consumer of graft v2 to tuteur 0.1.0 with one pull request. The
input keeps its name, `graft`, so nothing else in your flake changes.

## Before you begin

- The repository is at graft v2.22.0 (`nix run .#graft outdated` lists `graft` at `v2.22.0`), and
  `nix run .#graft check` passes. Take v2.22.0 first if you are behind: it is an ordinary v2 release.
- tuteur 0.2.x still reads graft's names: the input name `graft`, the app `graft`, `scions/` or `.scions/` as the
  folder, graft's marker README, a provider's `graft.nix`, its arguments `scion` and `scions`, and `.graft-try`.
  `tuteur check` prints one line for each one in use, and never fails on it. tuteur 0.3.0 drops them, except the
  input name `graft`, which every 0.x reads.
- This pull request does not move the folder. Keep `scions/` (or `.scions/`) for now: tuteur 0.3.0's Upgrading
  steps move it to `.patterns/`.
- If any agent or kit command runs under pot here (the repository has kits, a `kits.just`, or agents run in it),
  the consumer now takes pot as an input of its own. Your root moves to pot 0.1.0 first
  ([pot](https://github.com/danielnaab/pot)).
- The commands assume `flake.nix` at the repository's top. For a flake in a subdirectory, run
  `nix run 'path:DIR#graft'` for `nix run .#graft`, and `nix flake check 'path:DIR'` for `nix flake check`.

## Steps

1. On a new branch, change the input's URL in `flake.nix`, and, under pot, add pot:

   ```nix
   inputs.graft.url = "github:danielnaab/tuteur/v0.2.1";
   inputs.pot.url = "github:danielnaab/pot/v0.3.0";     # only where agents or kit commands run under pot
   ```

   A `git+https://…/graft?ref=refs/tags/vX&exportIgnore=1` URL becomes
   `git+https://…/tuteur?ref=refs/tags/v0.2.1&exportIgnore=1` the same way. Keep the name `graft`. Then lock,
   through an empty fetch cache:

   ```
   XDG_CACHE_HOME=$(mktemp -d) nix flake update graft
   ```

   It locks `graft` at tuteur 0.1.0, and `pot` if you added it.

2. Write tuteur's files, by the app's old name (tuteur 0.1.0, through the alias):

   ```
   nix run .#graft sync
   ```

   It rewrites the marker README, renames each of graft's marked workflows (`graft-check.yaml` to
   `tuteur-check.yaml`, and the others) with tuteur's marker and lines, and rewrites `kits.just` (under pot):

   ```
   tuteur: wrote scions/README.md
   tuteur: renamed .forgejo/workflows/graft-check.yaml to .forgejo/workflows/tuteur-check.yaml
   tuteur: wrote scions/kits.just
   ```

   A `# graft ssh:` line becomes `# tuteur ssh:`; its default secret is `TUTEUR_SSH_KEY`, else `GRAFT_SSH_KEY`.

3. Check:

   ```
   nix run .#tuteur check
   nix flake check
   ```

   `check` passes, and names the graft names still in use, such as:

   ```
   tuteur: the folder scions/, which mkFlake finds without dir, is graft's name; 0.3.0 drops it: keep it with dir = "scions"; in mkFlake, or move it to .patterns/ (0.3.0's Upgrading steps)
   tuteur: 1 pattern clean and at release tags
   ```

   Under pot, `pot explain` lists the same kits, and the first run asks for one `pot grant` for the repo kit,
   because `flake.lock` changed.

4. On the forge:
   - Add the Actions secret `TUTEUR_PR_TOKEN`, or keep `GRAFT_PR_TOKEN`: the new workflow reads either, then the
     job's token.
   - Edit any branch rule whose required status checks name `graft-check / …`: the workflow is now
     `tuteur-check`, and its job `patterns`.
   - Close the open `graft/upgrade` pull request, if there is one. Delete that branch after the merge: the weekly
     job now pushes `tuteur/upgrade`.

5. Commit everything, open the pull request, review it, and merge it.

## Check it worked

```
nix run .#tuteur outdated
nix run .#tuteur check
```

`outdated` lists `graft` at `v0.2.1` (the input's name, tuteur's version). `check` passes. The next weekly
`tuteur-upgrade` run takes tuteur's and pot's 0.1.x patches by itself, and holds 0.2.0 for a person.

## If something goes wrong

| What you see | What to do |
|---|---|
| `nix flake check` fails in `pot-kits`, or `check` says `kits.just is here but this flake has no pot-kits (no inputs.pot)` | The repository uses kits: add `inputs.pot` (step 1), lock it, and run `nix run .#graft sync` again. To go on without pot, delete `kits.just` and its import: no run applies the kits then. |
| A warning that a unit `declares a kit for pot, but this flake has no inputs.pot` | The same: a provider gives a kit. Add `inputs.pot` if agents or kit commands run here; otherwise the warning is harmless. |
| `tuteur: lib.mkRoot is pot's, not tuteur's` (or `kits`, `apis`, `homeManagerModules.pot`) | A root reads pot's outputs from graft's input. Take pot's flake for those (`inputs.pot`, `pot.lib.mkRoot`, `pot.homeManagerModules.pot`): see pot's README. |
| A workflow still named `graft-*.yaml` after `sync` | It has no `# managed by graft:` line: it is yours, and tuteur never touches it. Rename and edit it yourself. |

To undo the move, revert the merge: `git revert -m 1 MERGE`. `flake.nix` and `flake.lock` point at graft v2.22.0
again (graft's repository stays, archived), and the workflows and README are graft's again.

## How it works

tuteur 0.1.0 is graft's code with graft's names changed and pot taken out; its version line starts again at 0.1.0,
in a new repository with no `v2.*` tags, so `outdated` compares it only with tuteur's own releases. The weekly job
can't make this move: the URL changes, `v0.2.0` is not newer than `v2.22.0`, and `ci pr` never opens a pull
request that changes `.forgejo/`. So each consumer moves by a person's pull request.

## Related

- [Concepts: graft's words](../concepts.md#grafts-words)
- [Decisions: two repositories](../decisions.md#two-repositories-tuteur-produces-kits-pot-runs-them)
- [CHANGELOG, 0.1.0](../../CHANGELOG.md#v010---2026-11-21)

## Sources

- [lib/mk-flake.nix](../../lib/mk-flake.nix): the folder fallback, `graft.nix`, the arguments, `inputs.pot`, the
  app `graft`, and the lines `check` prints for them
- [lib/workflows.sh](../../lib/workflows.sh): `sync` renames graft's marked workflows and reads `# graft ssh:`
- [lib/patterns.sh](../../lib/patterns.sh): `check`'s lines for graft's names, `.graft-try`
- [lib/common.sh](../../lib/common.sh): the input named `tuteur`, else `graft`; graft's marker
- `tests/run.sh`, sections `aliases` and `fromgraft` (this page's steps, on a consumer of graft v2.22.0, then
  rolled back)
