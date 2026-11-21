---
status: working
---
# provider/3: tuteur.nix

The contract between a provider and tuteur: what a provider's `tuteur.nix` is, and what tuteur's mkFlake makes of
it. For the steps, see [Write a provider's tuteur.nix](../guides/write-tuteur-nix.md). The other contracts, which pot
owns, are listed in [pot's contracts](https://github.com/danielnaab/pot/blob/v0.1.0/contracts/README.md).

| | |
|---|---|
| Version | 3. provider/2 is graft's `graft.nix`, which tuteur 0.1.x still reads (below). A breaking change to this contract is provider/4, in a breaking version of tuteur. |
| Producer | a provider's `tuteur.nix`, at the top of its repository (else its `graft.nix`, through 0.1.x) |
| Reader | tuteur's mkFlake, in each consumer, once per system |
| Owner | tuteur |

## Shape

`tuteur.nix` is a function:

```nix
{ pkgs, lib, system, pattern, patterns, consumer, kitArgs ? { }, ... }:
{
  requires ? { };     # { <name> = "<url>"; }
  tools    ? { };     # { <name> = <derivation>; }
  apps     ? { };     # { <name> = { type = "app"; program = "…"; }; }
  packages ? { };     # { <name> = <derivation>; }
  checks   ? { };     # { <name> = <derivation>; }
  kit      ? null;    # a kit, for pot; tuteur hands it on unread
}
```

| Argument | Type | Value |
|---|---|---|
| `pkgs`, `lib`, `system` | nixpkgs, its lib, a system string | the consumer's `inputs.nixpkgs` if it has one, else tuteur's |
| `pattern` | a store path | this pattern alone, without its `.git` file |
| `patterns` | attrs | every pattern of the consumer: its store path as `outPath`, merged with its `tuteur.nix` result |
| `scion`, `scions` | | provider/2's names for `pattern` and `patterns`, passed beside them through 0.1.x. A function that names only `scion` or `scions` gets only those two; one that names only `pattern` or `patterns`, only the new two; any other gets all four. |
| `consumer` | a store path | the consumer flake's source |
| `kitArgs` | attrs | the consumer's `perSystem.kitArgs.<pattern>`, or `{ }`. Passed only when the function names it. |

| Attribute | Type | Becomes |
|---|---|---|
| `requires` | attrs of strings | nothing. Each named pattern must exist, or evaluation fails naming `tuteur add URL`. |
| `tools` | attrs of derivations | part of `packages.<system>.tools` |
| `apps` | attrs of apps | `apps.<system>.<name>` |
| `packages` | attrs of derivations | `packages.<system>.<name>` |
| `checks` | attrs of derivations | `checks.<system>.<pattern>-<name>` |
| `kit` | a [kit](https://github.com/danielnaab/pot/blob/v0.1.0/contracts/kit-1.md), or `null` | when the consumer has `inputs.pot`: the pattern's kit in `packages.<system>.pot-kits`, which mkFlake has pot's [kitsFor](https://github.com/danielnaab/pot/blob/v0.1.0/contracts/pot-lib-1.md) write, with the file `<dir>/<pattern>/tuteur.nix`. Without `inputs.pot`: nothing, and one warning |
| anything else | any | visible to other providers as `patterns.<name>.<attr>`; not a flake output |

Reserved names, an evaluation error when a provider or `perSystem` gives them: `apps.tuteur`, `apps.graft`, `packages.tools`,
and in both `apps` and `packages`: `sandbox`, `pot`, `pot-kits` and `graft-kits`. The full merge and collision
rules are in [Files](files.md#tuteurnix).

tuteur reads no field of `kit`. Its schema, its checks and their messages are pot's: an unknown field fails the
consumer's `pot-kits` build with `pot: <dir>/<pattern>/tuteur.nix: <field> is not a kit field (…)`.

## Compatibility

- **Arguments are added, never removed within a version.** A provider takes `...`, so a later tuteur can pass
  more. provider/3 renamed provider/2's `scion` and `scions`; 0.1.x passes both, and 0.2.0 drops the old two.
- **`graft.nix`** (provider/2's file) is read when the provider has no `tuteur.nix`, through 0.1.x; `tuteur check`
  names it. A provider can ship both files meanwhile: tuteur reads `tuteur.nix`, graft reads `graft.nix`. pot
  protects both names in a run.
- **Every attribute is optional.** A missing one is empty.
- **`sandbox`,** graft v2.14.0's attribute, is an error that names its replacement:
  ``tuteur: <file> gives `sandbox`: graft v2.15.0 replaced it with `kit` (pot; see graft's CHANGELOG)``.
- **A kit's format is not this contract's.** It moves with [kit/1](https://github.com/danielnaab/pot/blob/v0.1.0/contracts/kit-1.md): a provider that
  writes a newer kit needs its consumers' roots on a pot that reads it, not a newer tuteur.

## Sources

- [lib/mk-flake.nix](../../lib/mk-flake.nix): the arguments, the merge, the reserved names, the call to kitsFor
- [Files: tuteur.nix](files.md#tuteurnix)
