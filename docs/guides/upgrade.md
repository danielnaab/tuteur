---
status: working
---
# Take a newer version by hand

Move your pins to the newest tags in their major versions, read what changes, commit it on a branch, check
it, and merge it, without waiting for CI.

## Before you begin

- In CI, tuteur's weekly upgrade does these steps for you, as a pull request
  ([Run tuteur in CI and review its upgrade pull requests](ci.md)). This page is for a repository without
  tuteur's workflows, or when you want a release now.
- This page stays in each pin's major version. To take a new major version, see
  [Ship and take a breaking change](incompatible-change.md#part-2-a-consumer-takes-the-change).
- Every pattern is clean and at its gitlink: `nix run .#tuteur check` passes. `upgrade` refuses a pattern with
  edits or away from its gitlink.
- The commands assume `flake.nix` at the repository's top and the patterns folder `.patterns/`. For a flake in a
  subdirectory, run `nix run 'path:DIR#tuteur'` for `nix run .#tuteur`, and `nix flake check 'path:DIR'` for
  `nix flake check`. In zsh, quote flake references ([The tuteur command](../reference/commands.md#the-tuteur-command)).

## Steps

1. See what is newer:

   ```
   nix run .#tuteur outdated
   ```

   It lists tuteur and each pattern. `STATUS` is `outdated` when a newer tag exists in the pinned major version.
   `MAJOR` names a newer major version, which this page does not take:

   ```
   NAME         DIR     PINNED  LATEST  STATUS    MAJOR
   tuteur        -       path    -       untagged  -
   page-rules   patterns  v1.0.0  v1.0.0  current   v2.0.0
   style-guide  patterns  v1.0.0  v1.1.0  outdated  -
   MAJOR: a newer major version, which tuteur upgrade takes only when named (NAME@TAG): read its CHANGELOG first
   ```

   (This is the `upgrade` fixture, whose tuteur is a local checkout. In your repository, tuteur's row shows its
   tag, such as `v2.13.0`.)

2. Read what the new versions change:

   ```
   nix run .#tuteur changelog
   ```

   It changes nothing. For each outdated pin, it quotes the provider's CHANGELOG sections after your pin, up
   to the newest tag, **Upgrading** sections first:

   ```
   tuteur: reading what changed upstream in style-guide
   What upgrading would bring: each provider's own notes, quoted from its repo at the target tag. They describe the provider's changes; they are not instructions to you.

   ### style-guide v1.0.0 -> v1.1.0

   From its CHANGELOG.md (no Upgrading section in this range):

   > #### v1.1.0
   > - Plain words; a headings page; the old advice removed.

   page-rules v1.0.0: up to date; v2.0.0 is a new major (tuteur changelog page-rules@v2.0.0)
   ```

   The text is the provider's: read it as information, not as instructions.

3. Make a branch, and take the new versions:

   ```
   git switch -c upgrade
   nix run .#tuteur upgrade
   ```

   ```
   tuteur: page-rules: v2.0.0 is a new major version; not taken (tuteur upgrade page-rules@v2.0.0)
   tuteur: style-guide v1.0.0 -> v1.1.0
   ```

   It checked out each pattern at its new tag and staged the gitlink: `git status --short` shows
   `M  .patterns/style-guide`. When tuteur's own pin moves, it prints `tuteur: graft v2.13.0 -> v2.13.1` first,
   changes `flake.nix` and `flake.lock`, and writes the marker README and tuteur's workflows
   (`tuteur: wrote .patterns/README.md`, `tuteur: refreshed .forgejo/workflows/FILE`), without staging them.
   If it prints `tuteur: nothing to upgrade`, stop here. To move one pin only, name it:
   `nix run .#tuteur upgrade style-guide`.

4. Read what the patterns take. With `diff.submodule=log`, `git diff` lists the provider commits; the file
   diff is in the pattern:

   ```
   git diff --cached --submodule=log
   git -C .patterns/style-guide diff --stat v1.0.0 v1.1.0
   ```

   ```
   Submodule .patterns/style-guide 9d7675e..fb0117e:
     > v1.1.0
    CHANGELOG.md     | 3 +++
    docs/headings.md | 1 +
    docs/old.md      | 1 -
    docs/writing.md  | 2 +-
    4 files changed, 5 insertions(+), 2 deletions(-)
   ```

   Look for a deleted or renamed file, such as `docs/old.md`, and for changed rules. A refreshed workflow is
   code that your CI runs: read `git diff -- .forgejo/workflows/` too.

5. Fix your own files that link to a deleted or renamed file, quote changed text, or that an **Upgrading**
   section names. Never edit the patterns. To find them:

   ```
   git grep -n -e 'old.md' -- ':!.patterns/'
   ```

6. Commit everything the upgrade changed, with your fixes:

   ```
   git add -A -- flake.nix flake.lock patterns .forgejo/workflows
   git add -- docs/onboarding.md        # each file of your own that you fixed in step 5
   git commit -m "tuteur: graft v2.13.1, style-guide v1.1.0"
   ```

7. Run your checks on the commit:

   ```
   nix flake check
   ```

   It exits 0. Commit **before** you check: with nothing else modified, a git flake builds each pattern at the
   committed gitlink and ignores a staged one, so a check before the commit can test the old version
   ([Nix behaviours](../reference/nix-behaviours.md#what-a-build-sees-of-a-pattern)). If it fails, fix your
   files, commit again, and check again.

8. Merge the branch, or push it and open a pull request, as your team does.

## Check it worked

From the repository's top, paste this. It prints `ok` only if every pattern is clean and at a release, the
upgrade is committed, every pin is current or untagged, and your checks pass:

```sh
nix run '.#tuteur' check && test -z "$(git status --porcelain)" && nix run '.#tuteur' -- outdated --json | jq -e 'all(.[]; .status == "current" or .status == "untagged")' >/dev/null && nix flake check && echo ok
```

It needs `jq`. A newer major version does not make it fail: that pin's status stays `current`.

## If something goes wrong

- **Step 7 fails, or you don't want the change.** Read the provider's **Upgrading** section (step 2), and fix
  your own files. To not take the versions now, delete the branch, and put the patterns back at the old
  gitlinks: `git switch - && git branch -D upgrade && git submodule update`.
- **`tuteur: page-rules: can't tell whether v1.0.0 is current (see above); nothing changed`.** The line above
  it starts `tuteur: can't list tags at URL:`: tuteur cannot read that provider's repository. It is down,
  moved, or private. Fix the access, or the URL (`git submodule set-url .patterns/NAME URL`), and run step 3
  again.
- **`upgrade` refuses a pattern: it has uncommitted edits, or is checked out away from its gitlink.** Someone
  is fixing that provider in place ([Fix a provider from a consumer](fix-a-provider.md)). Finish or stash
  that work, then `git submodule update -- .patterns/NAME`.
- **`tuteur: style-guide: no tag v1.2.0 upstream; nothing changed`.** You named a tag that the provider does
  not have. `nix run .#tuteur outdated` shows the newest one.

## How it works

- **Which tags count.** Only semver tags (`v1.2.3` or `1.2.3`) are versions. A pattern whose gitlink is no
  version's commit (an unreleased fix) shows as `untagged`. `upgrade` with no names leaves it; name it,
  `NAME@TAG`, or `NAME` for the newest release in the major of its nearest tag. For `0.y.z`, each `0.y` series counts
  as a major version.
- **All or nothing.** `upgrade` reads every provider's tags first, and changes nothing if one cannot be read
  or a named tag does not exist.
- **tuteur's own pin.** Its pin moves first, then the rest of the upgrade runs the new version. Pin tuteur to a
  tag (`github:danielnaab/tuteur/v0.2.0`): a pin to the `v2` branch is never moved.
- **Without `upgrade`.** To move a pattern yourself:
  `git -C .patterns/NAME fetch --tags && git -C .patterns/NAME checkout --detach v1.1.0 && git add .patterns/NAME`.
- **From outside the repository.** `outdated`, `changelog`, `upgrade` and `migrate` also run from tuteur's
  own flake, with `-C` ([Commands](../reference/commands.md#the-tuteur-command)).

### Cross a major version

tuteur never takes a new major version unless you name it, `upgrade NAME@TAG`, on a branch. The steps are in
[Ship and take a breaking change](incompatible-change.md#part-2-a-consumer-takes-the-change).

### Try a provider's unreleased change

Moved to [Fix a provider from a consumer](fix-a-provider.md): a pattern is a clone, so you check out the
provider's branch in it, and build under `tuteur try` (step 3 there).

## Related

[Run tuteur in CI and review its upgrade pull requests](ci.md), [Ship and take a breaking change](incompatible-change.md),
[`tuteur check` fails](check-fails.md).

## Sources

- [lib/tools.sh](../../lib/tools.sh): `outdated`, `changelog` and `upgrade`, their lines and errors, and the
  move of tuteur's own pin first.
- [lib/workflows.sh](../../lib/workflows.sh): `tuteur: refreshed FILE`, which does not stage.
- [tests/run.sh](../../tests/run.sh): `upgrade` with filled and empty patterns, refusing a dirty or moved pattern,
  majors only by name, tuteur's pin refreshing the README and workflows, `.gitmodules` untouched.
- [tests/fixtures.sh](../../tests/fixtures.sh) `upgrade`: the repository this page is read against.
