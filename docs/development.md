---
status: working
---
# Development

How to change tuteur, test it, and release it.

## Layout

pot is its own repository ([danielnaab/pot](https://github.com/danielnaab/pot)). tuteur's flake never names it:
mkFlake calls pot's library only through a consumer's own `inputs.pot`, and tuteur's tests take pot from
`dev/flake.nix`. tuteur's command is built from `lib/` and `template/` alone, so a change to mkFlake leaves it
unchanged (`tests/run.sh own` proves it).

| Path | Contents |
|---|---|
| `flake.nix` | `lib.mkFlake`, the `tuteur` package (`packages.default`), tuteur's own app (`apps.tuteur`), the template, and the checks; and pot's old names (`lib.mkRoot`, `lib.pot`, `kits`, `apis`, `homeManagerModules.pot`), each an error that names pot's flake. It does not call `mkFlake` on itself and does not declare `inputs.self.submodules` ([below](#test)). |
| `lib/mk-flake.nix` | `mkFlake`: discovery of patterns, `pattern.nix` (or `tuteur.nix` or `graft.nix`) calls, the merge of outputs, the evaluation errors, and the call to `inputs.pot.lib.pot.kitsFor` when the consumer has pot. It reads no kit field. |
| `lib/tuteur.sh` | The command: dispatches to the scripts below. |
| `lib/patterns.sh` | `add`, `sync`, `check`, `status`, `try`. |
| `lib/tools.sh` | `outdated`, `changelog`, `upgrade`. |
| `lib/common.sh` | Shared helpers: finds the marker README and the flake, reads `.gitmodules`, tags and the lock's own and `pot` inputs, and asks `pot why URL --json` inside a pot run. |
| `lib/refresh.sh` | What `sync` writes, and what an older tuteur's `upgrade` runs of this version ([below](#the-version-crossing-interface)). |
| `lib/assemble.sh` | A stub: it fails, with a link to graft's v2.13.0 Upgrading steps, when a graft v2.12 `upgrade` runs this version. |
| `lib/migrate.sh`, `lib/migrate.jq` | `migrate`. |
| `lib/ci.sh`, `lib/upstream.jq` | `ci`, and the provider text in the pull request. |
| `lib/workflows.sh` | tuteur's workflow files. |
| `template/` | What `nix flake init -t` writes. Its workflows are the copies that consumers must match. |
| `contracts/` | tuteur's contracts: [status/1](../contracts/status-1.md), its schema and fixtures. |
| `dev/flake.nix` | Development-only inputs (knowledge-base-kit, pot) and the docs check, kept out of tuteur's lock and so out of consumers' locks. |
| `tests/run.sh`, `tests/stub-api.py` | The end-to-end test, and a stub of Forgejo's API. |
| `tests/fixtures.sh` | The repositories that a guide is read against. |
| `docs/`, `README.md`, `AGENTS.md` | Documentation, checked against knowledge-base-kit's conventions. |
| `.patterns/` | tuteur's own pattern, knowledge-base-kit, a submodule, for reading. The docs check reads the same commit from `dev/flake.nix`'s `knowledge-base-kit` input. |
| `.forgejo/workflows/` | tuteur's own CI: the template's workflows, kept current by `nix run .#tuteur sync`. |

### The version-crossing interface

When `upgrade` moves tuteur's own pin, the version that runs (the old one) fetches the new one and runs the new
one's `lib/refresh.sh` from the repository's top:

```
bash NEW/lib/refresh.sh PATTERNS FLAKE RUN TEMPLATE
```

- `PATTERNS`: the patterns folder, from the top, or empty when there is none yet.
- `FLAKE`: the flake's folder, from the top (`.` at the top).
- `RUN`: how a person runs the repository's app, such as `nix run .#tuteur` or `nix run 'path:nix/tools#tuteur'`.
- `TEMPLATE`: the new version's `template/` folder (its workflows).

It writes the new version's marker README and workflows, and prints one line per file it changed. That path and
its four arguments are an interface between releases, as a contract is: every 0.x release keeps them, and so must
a rewrite (as a script that runs the new binary, if need be). An old version refuses to move to a version without
`lib/refresh.sh`. graft v2.13.0 to v2.22.0 call it the same way; they never reach tuteur, whose URL differs.

## Test

```
git submodule update --init --recursive      # tuteur's own pattern, to read its conventions
nix flake check                  # bash -n and shellcheck
nix flake check ./dev            # the docs check
nix run .#tuteur check           # the pattern is clean and at a release tag
bash tests/run.sh                # the whole cycle against throwaway provider repositories
bash tests/run.sh mkflake kits   # some sections only
KEEP=1 bash tests/run.sh         # the same, and keep the work directory to debug a failure
```

`nix flake check` runs `shellcheck`. The `kits` section of `tests/run.sh` needs pot: it reads the `pot` input of
`dev/flake.nix` (source only, `flake = false`), and its test consumers take it as `inputs.pot`. Move that input to
pot's newest release with tuteur's; while both are developed together, point it at a local checkout
(`path:/ABSOLUTE/PATH/TO/pot`) and run `nix flake update pot --flake ./dev`.

tuteur's flake is other flakes' input (`github:` for consumers, `path:` and a tarball in the tests), so it must
not declare `inputs.self.submodules`: Nix applies the attribute to that fetch, and those schemes reject it
(`error: input attribute 'submodules' not supported by scheme 'github'`; graft v2.13.0 had this bug). The
`own` section of `tests/run.sh` fails if the line comes back. Without it, tuteur's own pattern is absent from
its flake's source, so tuteur does not call `mkFlake` on itself:

- The docs check is in `dev/flake.nix`, so that knowledge-base-kit is in no consumer's lock. It reads the whole
  repository, so run it from the checkout as a git flake, `nix flake check ./dev`, never as `path:`. Like any git
  flake it sees only what git tracks: `git add` a new page before you check it. It reads knowledge-base-kit's
  checker from the `knowledge-base-kit` input (`flake = false`), at the pattern's gitlink, and `tests/run.sh own`
  fails when the two differ. When you move the pattern (`nix run .#tuteur upgrade knowledge-base-kit`, or the weekly
  job), move the input too: set its tag in `dev/flake.nix`, run
  `XDG_CACHE_HOME=$(mktemp -d) nix flake update knowledge-base-kit --flake ./dev` (an empty fetch cache: the pattern's
  own checkout may have left the commit's whole tree in yours, [A polluted fetch cache](reference/nix-behaviours.md#a-polluted-fetch-cache-locks-the-wrong-tree)),
  and commit both. To check the docs against an unreleased edit in the pattern:
  `nix flake check ./dev --override-input knowledge-base-kit path:$PWD/.patterns/knowledge-base-kit`.
- `apps.tuteur` is tuteur's own app, as `mkFlake` gives a consumer one (`nix run .#tuteur check`, `sync`,
  `ci …`); `packages.tools` is an empty environment, which `tuteur check` evaluates.
- `flake.nix` carries the comment `# tuteur: no self.submodules`, so `tuteur check` accepts it.

To try a checkout of tuteur in another repository: `--override-input tuteur path:/ABSOLUTE/PATH/TO/tuteur` (its
working tree) or `git+file:///ABSOLUTE/PATH/TO/tuteur` (what git tracks). `tests/run.sh` uses a copy of the
checkout's working tree as a `path:` input, and a tarball of it as a `tarball+file:` input.

`tests/run.sh` builds local bare provider repositories with tags and `file://` submodule URLs, and covers
mkFlake (discovery, isolation, siblings, collisions, the evaluation errors), the Nix fetch rules that tuteur
depends on, the seam between mkFlake and pot's `kitsFor` (`kits`), `add`, `sync`, `check` (one fixture per rule),
`outdated`, `status`, `changelog`, `upgrade` (with a `0.y` series), tuteur's own pin (`tuteur`), `migrate`, `ci`
against a local origin and a stub API, the workflows, graft's names that 0.2.x reads (`aliases`), and a consumer of
graft v2.22.0 moved by [Move from graft v2](guides/move-from-graft.md) (`fromgraft`). `own` checks tuteur's own
flake: no `inputs.self.submodules`, no pot in its lock, the command unchanged by an edit to mkFlake, and the docs
check. It takes several minutes and fetches nixpkgs on its first run. Do not
run several copies in parallel.

## Documentation

The docs follow knowledge-base-kit's conventions, added in `.patterns/knowledge-base-kit/`: its
[style policy](https://github.com/danielnaab/knowledge-base-kit/blob/v2.1.0/docs/policies/style.md)
(plain language, ASD-STE100 procedures, one term per concept, Diátaxis document types), and its
[linking](https://github.com/danielnaab/knowledge-base-kit/blob/v2.1.0/docs/policies/linking.md) and
[lifecycle](https://github.com/danielnaab/knowledge-base-kit/blob/v2.1.0/docs/policies/lifecycle.md)
policies. `nix flake check ./dev` runs the kit's checker on them, with the scopes in `knowledge-base.yaml`, which
cover `contracts/` too.

tuteur's own rules:

- Use the terms that [Concepts](concepts.md) defines.
- Reference pages end with a `## Sources` section that links the code they describe.
- A guide is one user goal: a title that names the goal or symptom, numbered steps with the exact command
  and its expected output, a runnable "Check it worked" block, the two to four real failures, and Sources.
  "Not yet: …" marks a known gap.
- A page whose goal has two actors, such as a provider and a consumer, can have two parts, each with its own
  steps (at most ten) and its own check under a heading that names it ([example](guides/incompatible-change.md)).
- Read a new or changed guide literally, against a fixture: `tests/fixtures.sh NAME OUT` builds one
  (`first-pattern`, `check-fails`, `fix-a-provider`, `gate-merges`, `private`, `ci`, `breaking-change`,
  `upgrade`, `publish`, `worktrees`, `copy-mode`). A
  reader that sees only the page and its links follows each step and says what it expects first. Then a
  reviewer checks its claims against the code.

These links cite the kit by URL at a tag, so that they work on GitHub, where a submodule is a link. When you
upgrade the kit with `nix run .#tuteur upgrade`, change their tag too.

## Release

Release from a shell with an empty fetch cache of its own. The checks fetch tuteur's checkout as `git+file:`, which
keeps the files that `.gitattributes` export-ignores; in your own cache, that tree would reach the next lock of
`github:danielnaab/tuteur/vX.Y.Z` on this machine, and CI would refuse it
([A polluted fetch cache](reference/nix-behaviours.md#a-polluted-fetch-cache-locks-the-wrong-tree)).

1. Start the release shell: `export XDG_CACHE_HOME=$(mktemp -d)`.
2. Add a section at the top of `CHANGELOG.md`: `## vX.Y.Z - YYYY-MM-DD`. A breaking version (below 1.0, a new
   `0.y`) needs an `### Upgrading` subsection.
3. Change the tuteur tag in `template/flake.nix`, `README.md`, `flake.nix`'s welcome text, `lib/patterns.sh`'s
   message for a provider file that doesn't evaluate, and the docs to the new version. Move `dev/flake.nix`'s
   `pot` input to pot's newest release, if it moved.
4. Run `nix flake check`, `nix flake check ./dev` and `bash tests/run.sh`.
5. Commit.
6. Tag the commit, signed and annotated: `git tag -s -m vX.Y.Z vX.Y.Z`. Use your own recognized signing key;
   an agent key is fine too. The signer workflow reports which key signed and which forge account pushed.
7. Push the `main` branch and the tag. Never push a `v2.*` tag here: graft's tags stay in graft's repository, and a
   `v2` tag would read as a later series than every `0.y`.
8. Print the hash that consumers lock, through another empty cache:
   `XDG_CACHE_HOME=$(mktemp -d) nix flake prefetch --json github:danielnaab/tuteur/vX.Y.Z | jq -r .hash`.

Take the release into other repositories with `nix run .#tuteur upgrade`, which fetches and locks tuteur's pin through
an empty fetch cache of its own, or by hand with `XDG_CACHE_HOME=$(mktemp -d) nix flake update tuteur`. Their
`tuteur check` fails when a lock's `narHash` is not the tag's (step 8's hash).
