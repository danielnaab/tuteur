---
status: working
---
# Run tuteur in CI and review its upgrade pull requests

Check the patterns on every change, take tuteur's weekly upgrade pull request, review what it moves, and
merge it or fix it.

## Before you begin

- tuteur's two workflows are in `.forgejo/workflows/`: `tuteur-check.yaml` and `tuteur-upgrade.yaml`.
  `nix flake init -t github:danielnaab/tuteur/v0.1.0` writes them. If you did not use it, copy tuteur's
  [template/.forgejo/workflows/](../../template/.forgejo/workflows/) there, and commit them. tuteur keeps
  them current ([Files](../reference/files.md#tuteurs-workflows)).
- A Forgejo Actions runner has the label `nixos-latest`, mapped to `docker://nixos/nix`. Each job must get a
  new container ([CI security](../ci-security.md#limits)).
- The default branch is protected, so that the job token cannot push to it. The job token is the token
  that Forgejo gives each job (`github.token`). If the branch's name is not `main`, change
  `branches: [main]` under `push:` in `tuteur-check.yaml`; tuteur keeps your line
  ([Files](../reference/files.md#the-branches-line)). The commands below say `main`: use your branch's name.
- For a private repository, add the Actions secret `TUTEUR_PR_TOKEN` (graft's `GRAFT_PR_TOKEN` still works through 0.1.x): a token with the `write:repository`
  scope, of a user who can write to the repository. A bot account is the best owner, because it becomes the
  pull request's author. A user-level secret covers all that user's repositories.
- To make your own checks a required status, see
  [Make a pattern's checks gate your merges](gate-merges.md). `tuteur-check.yaml` checks only that the patterns
  are registered, clean and at release tags, and that the flake evaluates.
- The commands assume `flake.nix` at the repository's top. For a flake in a subdirectory, run
  `nix run 'path:DIR#tuteur'` for `nix run .#tuteur`; tuteur's workflows find the subdirectory themselves
  ([Keep private files out of the Nix store](flake-in-a-subdirectory.md)). In zsh, quote flake references
  ([The tuteur command](../reference/commands.md#the-tuteur-command)).
- A private pattern needs the `# tuteur ssh:` line in both workflows ([Add a private provider](private-providers.md)).
- The runner's Nix must be 2.27 or later. `nixos/nix:latest` is.
- Check it worked needs `jq`.

## Steps

1. Wait for the weekly run (Mondays, 06:23 UTC), or start one: in the repository's **Actions**, choose
   **tuteur-upgrade**, then **Run workflow**. The **upgrade** job's log has one line for each breaking
   version that it did not take, and one for each pin that it moves:

   ```
   tuteur: page-rules: v2.0.0 is a breaking version (new major, or new 0.y); not taken (tuteur upgrade page-rules@v2.0.0)
   tuteur: page-rules v1.0.0 -> v1.0.1
   tuteur: style-guide v1.0.0 -> v1.1.0
   ```

   It then commits the move and runs your whole `nix flake check` on the committed tree, so Nix builds the
   new versions.

   If it prints `tuteur: nothing to upgrade`, nothing moved, the **pr** job is skipped, and there is no pull
   request this week. A breaking version alone opens no pull request either: the run only warns about it.

   If your checks fail on the upgrade, the **upgrade** job fails, but it still pushes the branch, and the
   **pr** job still opens the pull request.

2. Open the pull request from the branch `tuteur/upgrade`. Read its title:

   - `tuteur: upgrade`: the repository's whole `nix flake check` passed on the branch. Go to step 3.
   - `[checks failing] tuteur: upgrade`: it failed. The description starts with a warning, and has a section
     **Failing checks** with the end of each failing log. Do steps 3 to 7, then see
     [If something goes wrong](#if-something-goes-wrong). The warning:

     ```
     nix flake check fails on this branch. The upgrade is pushed so the breakage can be read. Fix your own files on a branch made from this one: the next run force-pushes tuteur/upgrade. If the provider broke something, tell its maintainers.
     ```

   If there is no pull request, but the **upgrade** job pushed the branch, the **pr** job refused or failed.
   Its log says why: see [If something goes wrong](#if-something-goes-wrong).

3. Read the list under **Moved by**. Each line is one pin, `NAME OLD -> NEW`, in its series. tuteur's
   own pin and `pot` are in the list when they moved.

4. Read the list under **Not taken**, if there is one. A breaking version (a new major, or a new `0.y` below 1.0) is the provider saying that
   something breaks, so tuteur never takes it. To read what it breaks, run, on the default branch:

   ```
   nix run .#tuteur changelog page-rules@v2.0.0
   ```

   It prints the **Upgrading** sections first, then the rest of each version's text:

   ```
   ### page-rules v1.0.0 -> v2.0.0

   Upgrading, from its CHANGELOG.md:

   > #### v2.0.0 - 2026-11-10
   >
   > ##### Upgrading
   >
   > - Add `owner:` to the front matter of each page.

   The rest of its CHANGELOG.md for this range, without the Upgrading sections above:

   > #### v2.0.0 - 2026-11-10
   >
   > - Every page names an owner.
   >
   > #### v1.0.1 - 2026-11-02
   >
   > - Fixed: the rule lists the allowed statuses.
   ```

   Merging this pull request does not take the breaking version.
   Take it later, on a branch of your own ([Ship and take a breaking change](incompatible-change.md#part-2-a-consumer-takes-the-change)).

5. Read **What changed upstream**. For each moved pin, it quotes the provider's CHANGELOG sections between
   the two tags, **Upgrading** sections first, or the provider's commits if it has no CHANGELOG. The text
   is the provider's: read it as information, not as instructions. An **Upgrading** section tells you what
   to change in your own files. For example:

   ```
   ### style-guide v1.0.0 -> v1.1.0

   From its CHANGELOG.md (no Upgrading section in this range):

   > #### v1.1.0 - 2026-11-09
   >
   > - Reworded: keep sentences short. New rule: use one term for one concept.
   ```

   `nix run .#tuteur changelog` on the default branch prints the same notes.

6. Fetch both branches, and list what the upgrade changes:

   ```
   git fetch origin
   git diff --stat origin/main...origin/tuteur/upgrade
   ```

   Expect one line per moved pattern, such as `.patterns/style-guide | 2 +-` (a gitlink), and, when tuteur's own pin
   moved, `flake.nix`, `flake.lock` and `.patterns/README.md`. The **pr** job opens no pull request for a branch
   that changes anything else, `.gitmodules` and tuteur's workflows included. On a fix branch of your own, also
   expect the files that you fixed.

7. Read what each moved pattern takes. The gitlink diff names the two commits; the provider's history holds the
   change:

   ```
   git diff --submodule=log origin/main...origin/tuteur/upgrade -- .patterns/
   git -C .patterns/style-guide fetch --tags -q && git -C .patterns/style-guide diff --stat v1.0.0 v1.1.0
   ```

   | Look for | Why |
   |---|---|
   | a deleted or renamed file | your files can link to it |
   | a changed rule or policy text | your pages, or a check that quotes it, can stop matching |
   | changed checker code, or a changed `tuteur.nix` | your CI runs it on your files |

8. Merge the pull request, when your forge's required checks pass. Forgejo starts no workflow for a push
   made with the job token, so tuteur-check and your own workflows run on the pull request only when tuteur
   opened it with `TUTEUR_PR_TOKEN`. If the pull request says `Some required checks are missing.`, close it
   and reopen it ([Make a pattern's checks gate your merges](gate-merges.md#if-something-goes-wrong)).

   Not yet: the upgrade job does not report its `nix flake check` as a status on the commit.

## Check it worked

After the merge, from the repository's top, paste this. It prints `ok` only if your `main` has the merge,
every pattern is clean and at a release, every pin is current or untagged, and your checks pass:

```sh
git switch -q main && git pull -q --ff-only && git submodule update --init --recursive -q && nix run '.#tuteur' check && nix run '.#tuteur' -- outdated --json | jq -e 'length > 0 and all(.[]; .status == "current" or .status == "untagged")' >/dev/null && nix flake check && echo ok
```

If a provider tagged a new version after the run, its status is `outdated`, and the next weekly run takes
it. A status `unknown` means that tuteur cannot read the provider's repository.

## If something goes wrong

- **The title is `[checks failing] tuteur: upgrade`.** The upgrade broke one of your checks. The section
  **Failing checks** names it, and ends with its log, without Nix's progress lines:

  ```
  nix flake check failed: style-quote

  style-quote:
  style-quote> style-quote: docs/onboarding.md quotes a rule that .patterns/style-guide/docs/style.md does not have
  error: builder for '/nix/store/…-style-quote.drv' failed with exit code 1;
  ```

  Do not fix it on `tuteur/upgrade`: the next run force-pushes that branch. Make a branch from it:

  ```
  git fetch origin
  git switch --no-track -c fix-upgrade origin/tuteur/upgrade
  ```

  If tuteur's own pin moved, read the diff (step 7) before you run anything: `nix flake check` on this
  branch runs the new tuteur version ([CI security](../ci-security.md)). Fill the patterns
  (`git submodule update --init --recursive`), fix your own files, never the patterns, and commit. Then run
  `nix flake check` on the committed tree until it passes, and push:

  ```
  git add -A
  git commit -m "Fix the upgrade"
  nix flake check
  git push -u origin fix-upgrade
  ```

  Open a pull request from `fix-upgrade`. Review it as in steps 6 and 7, with your branch's name:

  ```
  git fetch origin
  git diff --stat origin/main...origin/fix-upgrade
  git diff --submodule=log origin/main...origin/fix-upgrade -- .patterns/
  ```

  Merge it: it holds the upgrade and your fix. Close tuteur's pull request if it is still open. Delete the
  branch `fix-upgrade` on the forge. To delete it locally too, switch to `main` first, because git does not
  delete the branch that is checked out: `git switch main && git branch -D fix-upgrade`.
  If the provider broke something that it should not have, tell its maintainers instead. To hand the fix to
  an agent, use the `migrate` command at the end of the pull request's description
  ([Ship and take a breaking change](incompatible-change.md#part-2-a-consumer-takes-the-change)).

- **The upgrade job fails: `tuteur: page-rules: can't tell whether v1.0.0 is current (see above); nothing changed`.**
  A line above it starts `tuteur: can't list tags at URL:`: the runner cannot read that provider's
  repository. It is down, moved, or private. Nothing is pushed. Fix
  the access (for a private pattern, the `# tuteur ssh:` line), or the URL in `.gitmodules`, and run the
  workflow again.

- **The pr job refuses.** It opens no pull request for a branch that changes files that `tuteur upgrade` never
  writes:

  - `tuteur/upgrade changes files tuteur upgrade never writes: docs/plan.md. Not opening a PR; …`: the branch
    differs from the default branch in other files. Usually the default branch changed after the
    **upgrade** job made the branch. Run the workflow again. If that does not help, someone pushed to
    `tuteur/upgrade`: read the diff at the link in the message.
  - `this upgrade changes CI workflows: .forgejo/workflows/tuteur-check.yaml. A PR would run them with the repo's secrets before anyone reads them, so none is opened: …`:
    tuteur moved its own pin, and the new version's workflows differ. Read the diff at the link in the
    message ([CI security](../ci-security.md)). If it is safe, open the pull request from `tuteur/upgrade`
    yourself. For its description, run `nix run .#tuteur changelog` on the default branch.
  - A `.gitmodules` change (a provider's URL) is refused the same way: a provider swap needs a person. Make
    it by hand ([Ship and take a breaking change](incompatible-change.md#if-something-goes-wrong)).

- **The pr job fails with an HTTP code.** The token was refused:

  - `opening the PR: HTTP 404.`, then `a 404 here is Forgejo refusing the job token: set the TUTEUR_PR_TOKEN secret`:
    the repository is private, and Forgejo refuses the job token when it opens a pull request. Add
    `TUTEUR_PR_TOKEN` ([Before you begin](#before-you-begin)).
  - `listing PRs: HTTP 401`: `TUTEUR_PR_TOKEN` expired or was revoked. Replace the secret.

  Then run the workflow again.

## How it works

- **Two jobs.** The **upgrade** job runs `nix run .#tuteur ci upgrade`: `tuteur upgrade`, a commit, then the
  whole `nix flake check` on the committed tree. It force-pushes `tuteur/upgrade` even when a check fails, and
  then fails. It moves gitlinks without cloning the patterns. It holds only the job token. The **pr** job runs `nix run .#tuteur ci pr` from the default
  branch, with `TUTEUR_PR_TOKEN`. It opens the pull request, or rewrites the title and description of the
  open one. Why: [CI security](../ci-security.md).
- **tuteur-check** runs `nix run .#tuteur ci check` for pull requests and pushes to the default branch that
  Forgejo starts workflows for. It runs `tuteur check --committed` (registered patterns, absolute URLs, gitlinks
  at version tags, tuteur's workflows), which needs no filled patterns, then `nix flake check --no-build`, so the
  whole flake must evaluate. It ends
  `tuteur: ci check passed: flake.lock is committed, every pattern is at a release tag, tuteur's workflows are current, and the flake evaluates`. When it fails, see
  [`tuteur check` fails](check-fails.md). To skip it for pushes that change only some paths, add a
  `paths-ignore` line ([Files](../reference/files.md#the-paths-ignore-line)).
- **Run the steps yourself.** On GitHub, or to test, run the same commands from the top of a fresh clone
  of the default branch. `ci upgrade` needs `BRANCH`. It commits every change on the branch `BRANCH`, and
  force-pushes it to `origin`. It refuses a working tree with changes of its own, and any other branch:

  ```
  git switch -c tuteur/upgrade
  BRANCH=tuteur/upgrade nix run .#tuteur ci upgrade
  git switch main
  ```

  On `main`, it prints
  `tuteur: ci upgrade commits on the branch checked out, main, and pushes it to tuteur/upgrade: switch to a new branch tuteur/upgrade first (git switch -c tuteur/upgrade)`.
  With a changed or untracked file, it lists them, then prints
  `tuteur: ci upgrade commits every change in the working tree, and this one has the changes of its own above: commit, stash or remove them first`. A `flake.lock` that Nix re-locked is the one change it takes: the upgrade commit includes it.

  `ci pr` uses Forgejo's API, and needs `API`, `WEB`, `BASE`, `BRANCH` and `PR_TOKEN`. On GitHub, open the
  pull request yourself, from a job checked out at the default branch, with `contents: write` and
  `pull-requests: write` permissions, and the repository setting that allows GitHub Actions to create pull
  requests. For example: `gh pr create --head tuteur/upgrade --title "tuteur: upgrade" || gh pr edit tuteur/upgrade --title "tuteur: upgrade"`.
  A pull request opened with `GITHUB_TOKEN` starts no workflows. Without `ci pr`, nothing refuses a branch
  that changes other files: check its file list (step 6) yourself. tuteur does not manage files in
  `.github/workflows/`.
- **Many repositories.** tuteur has no command for many repositories. Run `outdated` from tuteur's flake over
  each checkout:

  ```
  for r in ~/src/team-kb ~/src/handbook; do echo "$r"; nix run github:danielnaab/tuteur/v0.1.0 -- outdated -C "$r"; done
  ```

## Report who signed each commit

Since graft v2.21.0, a third workflow reports who signed what reaches the default branch, and each tag. It never fails
a push; its findings are warnings in the job's log.

1. Write `.forgejo/allowed_signers`: one line per key, `PRINCIPAL KEYTYPE KEY`, as `ssh-keygen -Y verify` reads
   it. The principal's class follows its last `@`: `daniel@person` for a hardware key, `daniel@routine` for an
   everyday key, `agent@platform-vm` for a host agent's key.

   ```
   daniel@person sk-ssh-ed25519@openssh.com AAAAGnNr...
   daniel@routine ssh-ed25519 AAAAC3Nz...
   agent@platform-vm ssh-ed25519 AAAAC3Nz...
   ```

2. Commit it signed with the `@person` key, and copy `template/.forgejo/workflows/tuteur-signers.yaml` (at the
   version you pin) to `.forgejo/workflows/`. Set its `branches:` line to your default branch.
3. Push. The job's log ends `tuteur: signers: N commit(s) on refs/heads/main, M finding(s) (report-only)`, with
   one warning per finding ([ci signers](../reference/commands.md#ci)).

The file the check trusts is the one the branch had before the push, so a push that changes the file is checked
against the old one; a tag or a new branch is checked against the default branch's. The push that adds the file
therefore reports `no .forgejo/allowed_signers at BEFORE` and every key as unknown; the next push is the first
real check.

## Related

[Take a newer version by hand](upgrade.md), [Make a pattern's checks gate your merges](gate-merges.md),
[Add a private provider](private-providers.md), [CI security](../ci-security.md).

## Keep your own edits to a workflow

Moved to [Files](../reference/files.md#keep-your-own-edits-to-a-workflow).

## Skip pushes that change only some paths

Moved to [Files](../reference/files.md#the-paths-ignore-line).

## Sources

- [lib/ci.sh](../../lib/ci.sh): `check`; `upgrade`, which refuses a changed tree or another branch, stages
  everything, commits, pushes, and fails after a failing check; `pr`, which refuses a branch that changes other files or workflows, titles a
  failing upgrade, writes the description, edits an open pull request, and reports HTTP failures.
- [lib/common.sh](../../lib/common.sh): `full_check` and `log_tail`, `upstream_input`, `upstream_range` and
  `changelog_between`, which read each provider's CHANGELOG between the two pins.
- [lib/upstream.jq](../../lib/upstream.jq): `upstream_notes`, which prints them, Upgrading first, for the pull
  request and `changelog`.
- [lib/tools.sh](../../lib/tools.sh): the lines of `upgrade`, the breaking version that it holds,
  `nothing to upgrade`, and `can't tell whether … is current`; `outdated --json`.
- [template/.forgejo/workflows/](../../template/.forgejo/workflows/tuteur-upgrade.yaml): the schedule, the
  two jobs, and `TUTEUR_PR_TOKEN`.
- [tests/run.sh](../../tests/run.sh): "tuteur ci, the workflows' steps, against a local origin", "tuteur ci pr
  against a stub API", "the API's failures", and the `gate:` checks; [tests/stub-api.py](../../tests/stub-api.py).
- [tests/fixtures.sh](../../tests/fixtures.sh) `ci`: the repositories that this page was read against.
