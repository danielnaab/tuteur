{
  description = "tuteur's development checks: inputs that tuteur's own flake keeps out of its consumers' locks";

  # The docs check reads the whole repository (../), so run it from tuteur's checkout as a git flake,
  # never path: (that would copy dev/ alone):
  #   nix flake check ./dev        (tests/run.sh `own` runs it)
  # knowledge-base-kit is read from this input, at the pattern's gitlink (tests/run.sh `own` checks they
  # match). To check against an unreleased edit in the pattern:
  #   nix flake check ./dev --override-input knowledge-base-kit path:$PWD/.patterns/knowledge-base-kit
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/ac62194c3917d5f474c1a844b6fd6da2db95077d";   # tuteur's nixos-25.05
  inputs.knowledge-base-kit = { url = "github:danielnaab/knowledge-base-kit/v2.1.0"; flake = false; };
  # pot, for tests/run.sh `kits` (mkFlake's half of the seam: a test consumer takes it as inputs.pot). Source
  # only here: the test consumer evaluates its flake, this one never does. At a release, pot's tag:
  #   github:danielnaab/pot/v0.1.0
  inputs.pot = { url = "path:/home/daniel/src/pot"; flake = false; };

  outputs = { nixpkgs, knowledge-base-kit, ... }:
    let
      lib = nixpkgs.lib;
      forAll = f: lib.genAttrs [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ]
        (system: f nixpkgs.legacyPackages.${system});
      repo = builtins.path { path = ./..; name = "tuteur-source"; };
    in
    {
      checks = forAll (pkgs: {
        # tuteur's docs against knowledge-base-kit's conventions: links and anchors, lifecycle status,
        # provenance (scopes in knowledge-base.yaml). The checker is knowledge-base-kit's src/.
        docs = pkgs.runCommand "tuteur-docs" { nativeBuildInputs = [ pkgs.python3 ]; } ''
          cd ${repo}
          export PYTHONPATH=${knowledge-base-kit}/src
          # one command per line: under set -e, a failure left of `&&` would not stop the build
          python3 -m link_validator .
          python3 -m kb_linter .
          touch $out
        '';
      });
    };
}
