---
status: working
---
# Fix a provider from a consumer

You, or an agent, find a bug in a provider while working in a repository that adds it. Fix it in the pattern,
test the fix in the consumer, push it to the provider, and take it back as a release.

## When to use this

| You want | Do |
|---|---|
| A provider's rule, tool or check is wrong for everyone | This page. |
| A provider's file does not fit your repository only | Keep your own file, outside `.patterns/`, and point your agents and tools at it. A provider cannot leave a file out for one consumer. |
| A provider's tool should behave differently here | Change its settings file in your repository, such as `knowledge-base.yaml`. The provider's README names it. |
| To try a provider's branch that someone else pushed | [Steps](#steps) 3 and 4 only, with their branch. |

A pattern is a real clone of the provider, so the fix can start where you found the bug. What it cannot do is
merge into the consumer before the provider releases it: `tuteur check` fails on a pattern that is not at a
release tag.

## Before you begin

- The example consumer is `team-kb`, which adds `knowledge-base-kit` in `.patterns/`. The bug: `kb-lint`
  rejects a valid status. Read your patterns folder for `.patterns/`. For a flake in a subdirectory, write
  `nix run 'path:DIR#tuteur'` for `nix run .#tuteur`.
- You can push a branch to the provider, or you can hand a patch to someone who can.
- The pattern is filled: `ls .patterns/knowledge-base-kit` lists files. If not:
  `git submodule update --init --recursive -- .patterns/knowledge-base-kit`.
- Know the Nix behaviour that makes this confusing: a git flake build (`nix build .#tools`,
  `nix flake check`) **ignores your uncommitted edit in a pattern while every other tracked file is clean, and
  uses it as soon as any tracked file is modified**. Even then it sees only files that git tracks *in the
  pattern*: a new file is invisible. So the same command can pass, then fail, with no change to the pattern
  ([Nix behaviours](../reference/nix-behaviours.md#what-a-build-sees-of-a-pattern)). The provider's own tests
  (step 2) are the reliable test; `tuteur try` (step 3) makes every consumer build use the fix, until you turn
  it off.
- **Do not switch the consumer's branch while you edit a pattern.** A checkout, switch or pull of the parent
  that moves the pattern's gitlink can move the pattern under your edits, and with `submodule.recurse=true` it
  discards uncommitted ones without a word. Commit or stash in the pattern first.

## Steps

1. Make a branch in the pattern. A pattern is checked out at a tag, with no branch:

   ```
   cd .patterns/knowledge-base-kit
   git switch -c fix-status-values
   ```

2. Fix the bug, and run the provider's own tests there, as its README or `AGENTS.md` says. For
   knowledge-base-kit:

   ```
   PYTHONPATH=src python3 -m pytest tests
   ```

3. Build the consumer with the fix. From the consumer's top, turn on `tuteur try`:

   ```
   cd ../..
   nix run .#tuteur -- try knowledge-base-kit
   ```

   ```
   tuteur: try is on: Nix builds of this repository read its working tree, and its patterns' (.tuteur-try marks it)
   tuteur: .patterns/knowledge-base-kit: branch fix-status-values at v2.2.0 (19392ed), as recorded: 1 modified, 1 new Nix doesn't see
   tuteur: .patterns/knowledge-base-kit: Nix sees a new file only once git tracks it: git -C .patterns/knowledge-base-kit add -- tests/test_statuses.py
   tuteur: build from the repository's top: nix build .#tools, nix shell .#tools -c TOOL, or nix flake check
   tuteur: tuteur try --stop turns try off (before git stash or a pull with --autostash here), and tuteur check fails until then
   ```

   It marks `.tuteur-try` at the top with intent to add, so every Nix build reads the working tree. It does
   not touch the pattern. Check its line for the pattern: the branch, the edits you expect. A new file in the
   pattern stays invisible to Nix until git tracks it there; run the `git -C … add` that `try` prints (it stages
   the file for real, in the provider's branch, where you will commit it anyway). Then build and check with
   the fix:

   ```
   git -C .patterns/knowledge-base-kit add -- tests/test_statuses.py
   nix shell .#tools -c kb-lint .
   nix flake check
   ```

   Created another file in the pattern? `git -C .patterns/knowledge-base-kit add` it, or run `try` again to see
   the command. While try is on, `git stash` in the consumer fails, and so does `git pull --autostash`: turn
   try off first (step 4).

   When `nix run .#tuteur` itself fails (the fix broke `pattern.nix`, or Nix cannot fetch a pattern's gitlink),
   run tuteur from its own flake: `nix run github:danielnaab/tuteur/v0.3.0 -- try -C .`.

   For a flake in a subdirectory, `try` changes nothing and prints `nix shell 'path:DIR#tools' -c TOOL`: a
   `path:` flake reads its working tree, new files included, on every build. Never build `path:.` at a
   repository's top instead: it copies every file there, untracked and ignored ones included, into the
   world-readable Nix store.

4. While try is on, `tuteur check` fails first on that, then on the pattern's uncommitted edits. That is
   expected:

   ```
   nix run .#tuteur check
   ```

   ```
   tuteur: tuteur try is on (.tuteur-try): Nix builds read the working tree, patterns included: tuteur try --stop turns it off
   tuteur: uncommitted edits in .patterns/knowledge-base-kit: src/kb_linter/status.py tests/test_statuses.py (tuteur try is on: Nix builds use them)
   ```

   When you are done building, turn try off. It removes `.tuteur-try`; the pattern stays as it is:

   ```
   nix run .#tuteur -- try --stop
   ```

5. Commit the fix in the pattern (before you switch the consumer's branch), and push the branch to the
   provider:

   ```
   cd .patterns/knowledge-base-kit
   git add -A
   git commit -m "kb-lint: accept every status that knowledge-base.yaml lists"
   git push origin fix-status-values
   ```

   `origin` is the URL in `.gitmodules`. If it is an `https` URL and you push over ssh, set a push URL once:
   `git remote set-url --push origin git@github.com:danielnaab/knowledge-base-kit.git`. Without push rights
   (an agent sandbox, say), write a patch instead, and hand it on:
   `git format-patch -1 -o /tmp/kb-fix`.

6. Open a pull request on the provider from `fix-status-values`. Say which consumer showed the bug, and how
   to reproduce it.

7. Put the pattern back to its pin, so that the consumer stays clean while you wait. If try is still on, turn
   it off first (`tuteur upgrade` refuses while it is on):

   ```
   cd ../..
   nix run .#tuteur -- try --stop
   git submodule update -- .patterns/knowledge-base-kit
   ```

   The pattern is at its gitlink again. Your branch stays in the pattern's git directory.

8. The provider merges the fix, tags a release, and pushes the tag:

   ```
   git -C ~/src/knowledge-base-kit tag v2.2.1 && git -C ~/src/knowledge-base-kit push origin main v2.2.1
   ```

   (Or its maintainers do.) Then take it in the consumer, naming the tag:

   ```
   nix run .#tuteur upgrade knowledge-base-kit@v2.2.1
   ```

   ```
   tuteur: knowledge-base-kit v2.2.0 -> v2.2.1
   ```

   `NAME@TAG` works also when the consumer recorded the unreleased fix
   ([Use the fix before its release](#use-the-fix-before-its-release)). Then commit and check, as in
   [Take a newer version by hand](upgrade.md#steps).

## Check it worked

After step 8, from the consumer's top, paste this. It prints `ok` only if the pattern is clean and at a
release, the move is committed, and the checks pass on the committed tree:

```sh
nix run '.#tuteur' check && test -z "$(git status --porcelain)" && nix flake check && echo ok
```

## Use the fix before its release

Sometimes the consumer's branch needs the fix before the provider releases it, to show it in a pull request.
Record the pushed commit:

```
git add .patterns/knowledge-base-kit
git commit -m "knowledge-base-kit: fix-status-values, until v2.2.1"
```

Nix fetches a commit that is on any branch of the provider, so builds work. `tuteur check` fails with
`tuteur: .patterns/knowledge-base-kit at abc1234 is not a release tag of …: release it, then tuteur upgrade knowledge-base-kit@TAG …`, so the
pull request cannot pass tuteur-check until the pattern is at a release: step 8's
`nix run .#tuteur upgrade knowledge-base-kit@v2.2.1` moves it there. Until the commit is pushed, Nix cannot
fetch it, so `nix run .#tuteur` itself cannot evaluate on a clean tree; run
`nix run github:danielnaab/tuteur/v0.3.0 -- check -C .` instead. With
`push.recurseSubmodules=check` ([Clones, worktrees, sandboxes and CI](clones-and-worktrees.md)), git refuses
to push the consumer while the pattern's commit is on no remote.

## If something goes wrong

- **`nix flake check` passes, and the fix is not in it; or it fails on an edit you already reverted.** A git
  flake build read the pattern at its gitlink, or the working tree, depending on whether another tracked file
  was modified. Turn on `tuteur try` (step 3) and read its line for the pattern.
- **`opening file '/nix/store/…-pattern-knowledge-base-kit/NEW-FILE': No such file or directory`.** git does
  not track the file in the pattern, so Nix does not see it:
  `git -C .patterns/knowledge-base-kit add -- NEW-FILE` (step 3).
- **`tuteur: .tuteur-try is committed …`.** `git commit -a`, or `git add -A` then a commit, took try's marker.
  `nix run .#tuteur -- try --stop` stages its removal; commit that ([`tuteur check` fails](check-fails.md)).
- **`error: Entry '.tuteur-try' not uptodate. Cannot merge.`, from `git stash` or a pull with `--autostash`.**
  Try is on. `nix run .#tuteur -- try --stop`, then stash.
- **`Cannot find Git revision '<sha>' in ref 'refs/heads/main' of repository '<url>'`.** The consumer records
  a pattern commit that the provider does not have: you committed the gitlink before pushing the pattern's
  branch. `nix run .#tuteur` fails the same way, before tuteur runs; use tuteur's own flake meanwhile
  (`nix run github:danielnaab/tuteur/v0.3.0 -- try -C .`, or `-- check -C .`). Push the branch (step 5), or
  record the release again: `git -C .patterns/NAME checkout --detach v2.2.0` (the tag it was at), then
  `git add .patterns/NAME` and commit. Step 7 does not help here: it checks out the recorded commit.
- **`tuteur upgrade` refuses: the pattern has uncommitted edits, or try is on.** Do step 7 first. Commit or stash
  anything in the pattern that you want to keep.
- **`tuteur: .patterns/knowledge-base-kit is checked out at X but the repository records Y: …`.** The pattern is
  on your branch. `git add .patterns/knowledge-base-kit` records it (only for [Use the fix before its
  release](#use-the-fix-before-its-release)); step 7 goes back. `tuteur sync` does not: it never moves a
  filled pattern, so that it cannot lose your branch.

## How it works

- `tuteur try` marks `.tuteur-try` with intent to add (`git add -N`): it differs from `HEAD`, so Nix reads the
  working tree, and nothing is staged for real, so a plain `git commit` leaves it out. It never touches a
  pattern's index: a file marked with intent to add counts as tracked with empty content, so
  `git checkout -- .` would empty it and `git reset --hard` delete it. `tuteur try --stop` removes the marker.
- `tuteur check` fails while try is on, and on uncommitted edits, a pattern away from its gitlink, and a
  gitlink that is not a version tag's commit. So a fix can live in a consumer's working tree and in a pushed branch, and still not
  merge unreleased.
- The provider's release is what every other consumer takes, through its weekly upgrade. Fixing it in the
  provider, not in a consumer's file, is the point.

## Sources

- [lib/tools.sh](../../lib/tools.sh): `upgrade` refuses a dirty pattern, and refuses while try is on.
- [lib/patterns.sh](../../lib/patterns.sh): `try`, `try --stop` and the `check` rules.
- [tests/run.sh](../../tests/run.sh): the Nix semantics tests (clean parent ignores a pattern edit; dirty parent
  uses it; an unpushed gitlink fails; a branch commit is fetched), and `try` (a build sees the edit and a new
  file only while it is on; `check` refuses while it is on).
- [tests/fixtures.sh](../../tests/fixtures.sh) `fix-a-provider`: the repositories this page was read against.
