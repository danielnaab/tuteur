# Agent entrypoint

tuteur holds a repository to other repositories' patterns: it pins each as a git submodule at a release tag, and
wires what it ships into the repository's Nix flake: a flake library and one command. Read [README.md](README.md),
then [Concepts](docs/concepts.md).

## Orientation

- **Configuration:** [knowledge-base.yaml](knowledge-base.yaml)
- **Docs:** [guides](docs/guides/), [reference](docs/reference/), [decisions](docs/decisions.md)
- **Code:** [lib/](lib/) (see [Development](docs/development.md#layout)); tests in [tests/run.sh](tests/run.sh).
  pot is its own repository ([danielnaab/pot](https://github.com/danielnaab/pot)); tuteur's tests take it from
  `dev/flake.nix`.
- **Its own pattern:** `.patterns/knowledge-base-kit`, a submodule: the conventions these docs follow. If it is
  empty, run `git submodule update --init --recursive`.

## Rules

1. `.patterns/knowledge-base-kit` is another repository. Ask before you edit it, and fix a bug in it only as a
   change to knowledge-base-kit: a branch in the pattern, its own tests, a pull request there. To check tuteur's
   docs with the fix: `nix flake check ./dev --override-input knowledge-base-kit path:$PWD/.patterns/knowledge-base-kit`.
   Take the release with `nix run .#tuteur upgrade knowledge-base-kit`, and move the `knowledge-base-kit` input
   in `dev/flake.nix` to the same tag ([Development](docs/development.md#test)). Never commit the pattern away from a release tag:
   `nix run .#tuteur check` fails.
2. Behaviour and docs change together. A change to a command, argument, message or file format updates its
   reference page in the same commit.
3. Keep tuteur in [scope](docs/decisions.md#scope-nix-git-submodules-and-a-tag-comparison).
4. Do not change `CHANGELOG.md` sections of released versions.

## Verify

1. `nix flake check`: bash -n and shellcheck. `flake.nix` must not declare `inputs.self.submodules`: tuteur is
   other flakes' input. `nix flake check ./dev`: the docs check (knowledge-base-kit from `dev/flake.nix`'s input,
   not the pattern; tests/run.sh `own` runs it too). Run it from this checkout, never as `path:`.
2. `nix run .#tuteur check`: the pattern is clean and at a release tag.
3. `bash tests/run.sh` after a change to `lib/` or `template/`. It takes minutes; do not run two at once.
