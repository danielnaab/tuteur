{
  description = "tuteur: hold a repository to other repositories' patterns, pinned as git submodules at release tags and wired into its flake";

  # tuteur is other flakes' input (github:, and path: or tarballs in its tests), so this flake.nix must not
  # declare inputs.self.submodules: Nix applies it to that fetch too, and those schemes reject it
  # ("input attribute 'submodules' not supported by scheme 'github'"). # tuteur: no self.submodules
  # So tuteur can't mkFlake itself: its pattern (knowledge-base-kit) is absent from its source. The docs check is in dev/flake.nix
  # (nix flake check ./dev), with its knowledge-base-kit input, so tuteur's consumers never lock it.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";

  outputs = { self, nixpkgs, ... }@inputs:
    let
      lib = nixpkgs.lib;
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAll = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      # tuteur's command is built from tuteur's own sources alone: lib/'s scripts, its jq files and the
      # patterns README it writes, and template/. lib/mk-flake.nix is not in it, so a change to mkFlake
      # leaves packages.<system>.default as it was (tests/run.sh `own` checks it).
      tuteurLib = builtins.path { path = ./lib; name = "tuteur-lib";
        filter = p: t: t == "regular" && (lib.hasSuffix ".sh" p || lib.hasSuffix ".jq" p || baseNameOf p == "patterns-readme.md"); };
      # The tuteur command (lib/tuteur.sh), with this version's workflows (template/). ENV is exported
      # first: a repo's own app (mkFlake) sets TUTEUR_IN_REPO and TUTEUR_DIR, its patterns folder's name;
      # tuteur's own package sets nothing, and reads any checkout with -C.
      cli = pkgs: env: pkgs.writeShellApplication {
        name = "tuteur";
        runtimeInputs = with pkgs; [ bash coreutils diffutils findutils gawk gnugrep gnused jq git util-linux curl openssh ];
        text = ''
          ${lib.concatStrings (lib.mapAttrsToList (k: v: "export ${k}=${lib.escapeShellArg v}\n") env)}
          export TUTEUR_TEMPLATE=${./template}
          exec bash ${tuteurLib}/tuteur.sh "$@"
        '';
        meta.description = "Hold a repository to other repositories' patterns, pinned as git submodules at release tags";
      };
      mkFlake = import ./lib/mk-flake.nix { inherit nixpkgs systems cli; };
      # an output that went to pot's flake (github:danielnaab/pot) with graft v2's split: an error naming where
      moved = name: there: throw ("tuteur: ${name} is pot's, not tuteur's (tuteur re-exports nothing of pot's): "
        + "take pot as an input of its own, inputs.pot.url = \"github:danielnaab/pot/v0.3.0\";, and use ${there}");
    in
    {
      lib.mkFlake = mkFlake;
      # pot's outputs are pot's own flake's (github:danielnaab/pot). These names are not re-exported: each one
      # fails, naming where it went, so a root or consumer that still reads them from here says what to change
      lib.mkRoot = moved "lib.mkRoot" "pot.lib.mkRoot";
      lib.pot = moved "lib.pot" "pot.lib.pot";
      kits = lib.genAttrs [ "claude-code" "pi" ] (k: moved "kits.${k}" "pot.kits.${k}");
      apis = lib.genAttrs [ "anthropic" "bedrock" "gateway" ] (a: moved "apis.${a}" "pot.apis.${a}");
      homeManagerModules.pot = moved "homeManagerModules.pot" "pot.homeManagerModules.pot";

      # Run against any checkout without evaluating its flake:
      #   nix run github:danielnaab/tuteur -- outdated -C path/to/repo
      # tools: empty (tuteur's own pattern is docs conventions); `tuteur check` from the repo's app evaluates it
      packages = forAll (pkgs: {
        default = cli pkgs { };
        tools = pkgs.buildEnv { name = "tools"; paths = [ ]; };
      });

      # tuteur's own app, as mkFlake gives a consumer one: nix run .#tuteur check, sync, ci …
      apps = forAll (pkgs: {
        tuteur = { type = "app"; program = lib.getExe (cli pkgs { TUTEUR_DIR = ".patterns"; TUTEUR_IN_REPO = "1"; }); meta.description = "tuteur, for this repository"; };
      });

      devShells = forAll (pkgs: { default = pkgs.mkShell { packages = [ (cli pkgs { }) pkgs.shellcheck pkgs.jq ]; }; });

      # A new repo's flake.nix and tuteur's workflows: nix flake init -t github:danielnaab/tuteur
      templates.default = {
        path = ./template;
        description = "A repository held to other repositories' patterns, with tuteur's Forgejo workflows";
        welcomeText = ''
          Add a first pattern (a git submodule at its newest release tag), then commit:
            nix run github:danielnaab/tuteur/v0.2.0 -- add -C . URL
          See https://github.com/danielnaab/tuteur.
        '';
      };

      checks = forAll (pkgs: {
        # bash -n first: bash's own parser, so a script bash can't run fails even where shellcheck's
        # parser would differ
        shellcheck = pkgs.runCommand "tuteur-shellcheck" { nativeBuildInputs = [ pkgs.shellcheck ]; } ''
          for f in ${./tests}/*.sh ${tuteurLib}/*.sh; do bash -n "$f" || exit 1; done
          shellcheck -x ${./tests/run.sh} ${./tests/fixtures.sh} ${tuteurLib}/*.sh
          touch $out
        '';
      });
    };
}
