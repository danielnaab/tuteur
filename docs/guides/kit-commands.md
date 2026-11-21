---
status: working
---
# Declare kit commands

A provider's `tuteur.nix` may return a `kit` for [pot](https://github.com/danielnaab/pot), which runs agents and
commands in a sandbox: the commands it ships, the recipes that run them, a hook command, and what they ask to
reach. tuteur hands the kit to pot unread; what a kit may say, and how pot runs it, is pot's
([pot's guide: Declare kit commands](https://github.com/danielnaab/pot/blob/v0.1.0/docs/guides/kit-commands.md),
[kit/1](https://github.com/danielnaab/pot/blob/v0.1.0/contracts/kit-1.md)). This page is tuteur's half: the
provider's wiring, and the consumer's.

## Before you begin

- Your provider has a `tuteur.nix` with `tools` ([Write a provider's tuteur.nix](write-tuteur-nix.md)).
- A consumer gets your kit only when its flake takes pot as an input of its own (`inputs.pot`). Without it,
  mkFlake builds no `pot-kits`, the tools are not wrapped, there is no `kits.just`, and the consumer's build
  prints one warning that names your `tuteur.nix`.

## Steps

1. In the provider, return the kit from `tuteur.nix`, beside the tools it names:

   ```nix
   # tuteur.nix (notebook-kit's, trimmed)
   { pkgs, lib, ... }:
   let check-kb = pkgs.writeShellApplication { name = "check-kb"; text = "…"; }; in
   {
     tools.check-kb = check-kb;
     kit = {
       version = "1.2";
       commands.check-kb = { program = lib.getExe check-kb; access = "read";
                             description = "Check links, lifecycle status, and Sources"; };
       recipes.check-kb = { run = "check-kb"; description = "Check links, lifecycle status, and Sources"; };
     };
   }
   ```

   A kit that reads the consumer's settings takes `kitArgs` (the consumer's `perSystem.kitArgs.<pattern>`):
   name it in the function's arguments ([provider/3](../reference/provider.md)).

2. In a consumer that runs under pot, take pot, and lock it:

   ```nix
   inputs.pot.url = "github:danielnaab/pot/v0.1.0";
   ```

   ```
   XDG_CACHE_HOME=$(mktemp -d) nix flake update pot
   ```

   mkFlake then calls `inputs.pot.lib.pot.kitsFor` ([pot-lib/1](https://github.com/danielnaab/pot/blob/v0.1.0/contracts/pot-lib-1.md))
   with every kit, and gives `packages.<system>.pot-kits`. `tuteur upgrade` moves `pot` with tuteur's own pin,
   by the same rule.

3. To run the kits' recipes with `just`, import the generated file from the consumer's `justfile`, then write it:

   ```just
   set allow-duplicate-recipes
   import? ".patterns/kits.just"
   tools := `nix build --no-link --print-out-paths .#tools`
   ```

   ```
   nix run .#tuteur sync
   ```

   It prints `tuteur: wrote .patterns/kits.just`. Commit the file: `tuteur check` compares it with what the flake
   generates ([kits.just](../reference/files.md#kitsjust)).

4. Release the provider: a new field in a kit is a patch or minor release of yours, nothing removed.

## Check it worked

```
nix build --no-link --print-out-paths .#pot-kits
just --list
nix run .#tuteur check
```

`pot-kits` builds, `just --list` shows your recipes, and `check` passes. In a run, `pot explain` lists your kit.

## If something goes wrong

- **A warning that a unit `declares a kit for pot, but this flake has no inputs.pot`.** The consumer has no
  `inputs.pot`: add it (step 2) if agents or kit commands run there. Otherwise the kit is unused, and the warning
  is harmless.
- **`tuteur: .patterns/kits.just is here but this flake has no pot-kits (no inputs.pot): add inputs.pot, or remove
  the file`.** The same, for a consumer that has a `kits.just`.
- **`tuteur: .patterns/kits.just's recipe X has the name of the justfile's own X: …`.** A kit's recipe never
  replaces the consumer's own; rename one of the two.
- **`pot: …` while `pot-kits` builds.** pot's check of the kit: see pot's guide.
- **``tuteur: FILE gives `sandbox`: graft v2.15.0 replaced it with `kit` ``.** Give `kit` instead.

## Sources

- [lib/mk-flake.nix](../../lib/mk-flake.nix): `inputs.pot`, the kits handed to `kitsFor`, the warning, the
  reserved names
- [lib/common.sh](../../lib/common.sh), [lib/patterns.sh](../../lib/patterns.sh): `kits.just` in `sync`, `add`,
  `upgrade` and `check`
- `tests/run.sh`, section `kits`
