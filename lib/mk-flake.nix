# mkFlake: a repo's flake outputs, wired from its patterns.
#
# A pattern is a git submodule in the patterns folder (`dir`, beside flake.nix): another repository,
# checked out at a release tag. The gitlink (the commit the repo records) is the pin and .gitmodules
# the source; flake.lock pins tuteur alone. Nix reads the patterns through `inputs.self.submodules =
# true` (a git flake: Nix fetches each at its gitlink) or from the working tree (a `path:` flake).
#
# A pattern whose repository has a `pattern.nix` at its top (`tuteur.nix`, 0.2.0's name, is read through 0.x) is a
# provider: pattern.nix is a function
#
#   { pkgs, lib, system, pattern, patterns, consumer, ... }:
#   { requires ? {}; tools ? {}; apps ? {}; packages ? {}; checks ? {}; kit ? {}; ... }
#
# called once per system, with the repo's own `inputs.nixpkgs` (else tuteur's) as pkgs; pattern is this
# pattern alone, copied to the store without its .git file; patterns.<name> is every pattern (its store
# copy as outPath, merged with that provider's result); consumer is the repo's flake source; and,
# when the function names it, kitArgs: the consumer's perSystem.kitArgs.<pattern> (default { }). The
# repo's own `perSystem` ({ pkgs, lib, system, patterns, ... }: { tools; apps; packages; checks;
# devShells; kit; kitArgs; }) is merged the same way, named `self` in messages. mkFlake merges:
#
#   tools      one pkgs.buildEnv, packages.<system>.tools; a name two give is an error, unless both
#              are the same store path
#   apps packages
#              by name; a duplicate is an error, and so are apps.tuteur, packages.tools,
#              packages.pot-kits (tuteur's), and the reserved names sandbox and pot
#   checks     checks.<system>.<pattern>-<name>; perSystem's as checks.<system>.<name>
#   devShells  perSystem's only; devShells.<system>.default, when none is defined: a shell with the
#              tools
#   requires   { name = "url"; }: siblings the provider needs; a missing one is an error naming
#              `tuteur add url`
#   kit        each provider's (a pattern kit) and perSystem's (the repo kit), handed unread to pot's
#              library (pot.lib.kitsFor, contract pot-lib/1) with each one's file, the tools and tuteur's
#              CLI for the repo, and what tuteur has pot protect (every provider file, the patterns folder):
#              packages.<system>.pot-kits, which pot builds with path: and reads (contract pot-kits/1).
#
# plus apps.<system>.tuteur, the tuteur command (lib/tuteur.sh). The repo's own `outputs` are merged
# last (per system, per name), so the repo can add or override; apps.<system>.tuteur and
# packages.<system>.pot-kits is tuteur's, and a repo's own is an error raised by tuteur's own value; sandbox and
# pot are reserved names in apps and packages.
#
# Every check on the patterns (the marker README, .gitmodules against what the source holds, names,
# requires, collisions) is an error inside the values it guards, never on an attribute set's names,
# and the names a provider gives are read so that a failing provider gives none (builtins.tryEval):
# apps.<system>.tuteur (`tuteur sync` fills empty patterns) and the repo's own outputs evaluate
# whatever state the patterns are in; pot-kits, like the tools, fails on a failing provider. An
# empty pattern (a path: flake's fresh clone; a private one left uninitialised) fails only what uses
# it (patterns.<name>); the tools leave its own out, with a warning.
{ nixpkgs, systems, cli }:

{ inputs, dir ? null, perSystem ? null, outputs ? { } }:

let
  lib = nixpkgs.lib;
  src = inputs.self;
  # pot's library (contract pot-lib/1), when the consumer takes pot as an input of its own (inputs.pot): tuteur
  # depends on nothing of pot's. Without it there is no pot-kits, the tools are not wrapped and there is no
  # kits.just; a unit that declares a kit gets one warning
  kitsFor = inputs.pot.lib.pot.kitsFor or null;
  hasPot = kitsFor != null;
  # the first line of the patterns README (lib/tuteur.sh writes it); also lib/common.sh's MARKER. graft's (graft
  # v2) is read no more: a folder that carries it is an error naming the way on (tuteur 0.2.x first)
  marker = "<!-- managed by tuteur: https://github.com/danielnaab/tuteur -->";
  oldMarker = "<!-- managed by graft: https://github.com/danielnaab/graft -->";
  marked = t: lib.hasInfix marker t;
  readmeOf = d: let f = "${src}/${d}/README.md"; in if builtins.pathExists f then builtins.readFile f else "";
  markedDir = d: marked (readmeOf d);

  # the patterns folder: dir, else .patterns (graft's scions and .scions are no default: dir = "scions"; keeps one)
  folder = if dir != null then dir else ".patterns";
  validDir = builtins.isString folder && builtins.match "[A-Za-z0-9._-]+" folder != null
    && folder != "." && folder != ".." && folder != ".git";
  validName = n: builtins.match "[A-Za-z0-9][A-Za-z0-9._-]*" n != null && n != "self";
  root = "${src}/${folder}";
  hasRoot = validDir && builtins.pathExists root;
  readme = "${root}/README.md";
  readmeText = if hasRoot && builtins.pathExists readme then builtins.readFile readme else "";
  hasMarker = marked readmeText;

  entries = if hasRoot then builtins.readDir root else { };
  dirs = lib.attrNames (lib.filterAttrs (_: t: t == "directory") entries);
  names = lib.filter validName dirs;
  badNames = lib.filter (n: !validName n) dirs;
  contents = n: builtins.readDir "${root}/${n}";
  # a submodule Nix didn't fetch (a path: flake's fresh clone) is an empty directory in the source
  empty = lib.filter (n: contents n == { }) names;
  isEmpty = n: lib.elem n empty;

  # .gitmodules, when the source holds it (a flake at the repo's top): the submodules registered
  # in the patterns folder, one level down
  gitmodules = "${src}/.gitmodules";
  hasGitmodules = builtins.pathExists gitmodules;
  registered = if !(validDir && hasGitmodules) then [ ] else
    lib.filter (p: p != null) (map (l:
      let m = builtins.match "[[:space:]]*path[[:space:]]*=[[:space:]]*(.*[^[:space:]])[[:space:]]*" l;
          p = if m == null then "" else lib.head m;
      in if lib.hasPrefix "${folder}/" p && !(lib.hasInfix "/" (lib.removePrefix "${folder}/" p))
         then lib.removePrefix "${folder}/" p else null)
      (lib.splitString "\n" (builtins.readFile gitmodules)));
  absent = lib.sort lib.lessThan (lib.filter (n: !(lib.elem n dirs)) registered);
  # a folder that isn't a submodule: not registered (at the top), or (in a subdirectory flake, whose
  # source has no .gitmodules) holding files but no .git, which every checked-out submodule has
  unregistered = if hasGitmodules then lib.filter (n: !(lib.elem n registered)) names
    else lib.filter (n: !(isEmpty n) && !((contents n) ? ".git")) names;

  # folders at the top of the flake's source holding tuteur's README: one that isn't dir means dir is wrong
  topDirs = lib.attrNames (lib.filterAttrs (_: t: t == "directory") (builtins.readDir src));
  markerDirs = if !validDir then [ ] else lib.filter markedDir topDirs;
  wrongDir = markerDirs != [ ] && !(lib.elem folder markerDirs);
  # graft v2's README (its marker): a repository not yet moved from graft's names, which tuteur 0.2.x read
  graftDirs = if !validDir then [ ] else lib.filter (d: lib.hasInfix oldMarker (readmeOf d)) topDirs;

  paths = ns: lib.concatMapStringsSep ", " (n: "${folder}/${n}") ns;
  github = ". Fetched with github:? use git+https://…, which keeps submodules.";
  problems =
    if !validDir then [ "tuteur: mkFlake's dir must be one folder name (letters, digits, . _ -; not ., .. or .git), got \"${toString folder}\"" ]
    else if graftDirs != [ ] then [ "tuteur: ${lib.head graftDirs}/README.md carries graft's marker (graft v2): tuteur 0.3.0 no longer reads graft's names: move with tuteur 0.2.x first (its guide Move from graft v2), then follow v0.3.0's Upgrading steps in tuteur's CHANGELOG.md" ]
    else if wrongDir then [ "tuteur: tuteur's README is in ${lib.head markerDirs}/ but mkFlake's dir is \"${folder}\": set dir = \"${lib.head markerDirs}\"; (or move the patterns)" ]
    else lib.optional (hasRoot && !hasMarker)
        "tuteur: ${folder}/README.md lacks tuteur's marker: is dir right? (mkFlake's dir = \"${folder}\")"
      ++ lib.optional (absent != [ ])
        "tuteur: .gitmodules registers ${paths absent} but the flake's source lacks ${if lib.length absent == 1 then "it" else "them"}: add inputs.self.submodules = true; to flake.nix (Nix >= 2.27)${github}"
      ++ map (n: "tuteur: ${folder}/${n} is not a submodule: tuteur add URL, or remove it") unregistered
      ++ map (n: "tuteur: ${folder}/${n}: a pattern's folder name must be letters, digits, . _ and - (starting with a letter or digit), and not self") badNames;
  # every value that reads the patterns goes through this
  ok = x: if problems == [ ] then x else throw (lib.concatStringsSep "\n" problems);
  emptyMsg = ns: why: "tuteur: ${paths ns} ${if lib.length ns == 1 then "is" else "are"} empty in the flake's source${why}: run git submodule update --init --recursive (or tuteur sync)${lib.optionalString hasGitmodules github}";

  # a provider's file: pattern.nix, else tuteur.nix (0.2.0's name, read through 0.x). graft v2's graft.nix is read no
  # more (tuteur check fails on a pattern that has only it)
  providerFile = n: if builtins.pathExists "${root}/${n}/pattern.nix" then "pattern.nix"
    else if builtins.pathExists "${root}/${n}/tuteur.nix" then "tuteur.nix" else null;
  providers = lib.filter (n: !(isEmpty n) && providerFile n != null) names;
  fileOf = n: "${folder}/${n}/${providerFile n}";
  # the units merged: each provider, then the repo's own perSystem as `self`
  units = providers ++ lib.optional (perSystem != null) "self";
  # each pattern alone, without its .git file: a tool built from it doesn't change when the repo
  # does (interpolating "${src}/${folder}/x" would make every repo commit a new tool)
  copies = lib.genAttrs names (n: builtins.path {
    path = "${root}/${n}";
    name = "pattern-${n}";
    filter = p: _: baseNameOf p != ".git";
  });

  forSystem = system:
    let
      pkgs = (inputs.nixpkgs or nixpkgs).legacyPackages.${system};
      args = { inherit pkgs system; lib = pkgs.lib; };
      # the names a function is called with: pattern and patterns (provider/3). graft's scion and scions (provider/2)
      # are given no more: a function that names one is an error saying so, not Nix's missing argument
      named = who: f: one: let a = lib.filter (x: (builtins.functionArgs f) ? ${x}) [ "scion" "scions" ]; in
        if a != [ ] then throw "tuteur: ${who} names ${lib.concatStringsSep " and " a}, graft's arguments (provider/2), which tuteur 0.3.0 no longer gives: name ${if lib.length a > 1 then "them pattern and patterns" else if a == [ "scion" ] then "it pattern" else "it patterns"} (provider/3)"
        else { patterns = siblings; } // lib.optionalAttrs (one != null) { pattern = one; };
      # an error inside a provider names it
      ctx = n: x: if n == "self" then x
        else builtins.addErrorContext "while evaluating ${fileOf n} (tuteur calls it for the pattern ${n})" x;
      # kitArgs: the consumer's perSystem.kitArgs.<pattern>, for a provider whose function names it
      kitArgsOf = n: (raw.self.kitArgs or { }).${n} or { };
      raw = lib.genAttrs providers (n: ctx n (
        let f = import "${copies.${n}}/${providerFile n}"; in
        f (args // named (fileOf n) f copies.${n} // { consumer = inputs.self; }
          // lib.optionalAttrs ((builtins.functionArgs f) ? kitArgs) { kitArgs = kitArgsOf n; })))
        // lib.optionalAttrs (perSystem != null) { self = perSystem (args // named "the consumer's perSystem" perSystem null); };
      # a provider's result, its requires asserted before anything else of it is used
      results = lib.mapAttrs (n: r:
        let
          req = if n == "self" then { } else r.requires or { };
          missing = lib.filter (m: !(lib.elem m names)) (lib.attrNames req);
        in
        if missing == [ ] then r else throw (lib.concatMapStringsSep "\n" (m:
          "tuteur: ${n} needs ${m}, which this repository does not have: tuteur add ${toString req.${m}}") missing))
        raw;
      siblings = lib.genAttrs names (n:
        if isEmpty n then throw (emptyMsg [ n ] "")
        else { outPath = copies.${n}; } // (results.${n} or { }));

      # the names a unit gives for KIND, read from its raw result: a provider that fails fails them,
      # loudly (never dropped). keysOf, for apps and packages alone, gives none instead, so that
      # apps.tuteur (the repair path) and the repo's own outputs still evaluate; the tools and the
      # checks read every provider with keysStrict, so a failing one fails them, naming it
      keysStrict = n: kind: ctx n (lib.attrNames (raw.${n}.${kind} or { }));
      keysOf = n: kind:
        let t = builtins.tryEval (let ks = keysStrict n kind; in builtins.deepSeq ks ks);
        in if t.success then t.value else [ ];
      # KIND's names from every unit, each with the units that give it
      gather = keys: kind: lib.foldl' (acc: n:
        acc // lib.genAttrs (keys n kind) (k: (acc.${k} or [ ]) ++ [ n ])) { } units;
      who = n: if n == "self" then "the consumer's perSystem" else "pattern ${n}";
      merge = keys: kind: lib.mapAttrs (k: from:
        let
          v = n: ctx n results.${n}.${kind}.${k};
          # the same store path from two units (both pass on one tool) is one tool
          same = kind == "tools" && lib.length (lib.unique (map (n: toString (v n)) from)) == 1;
        in
        if lib.length from > 1 && !same
        then throw (if lib.elem "self" from
          then "tuteur: ${kind} ${k} (from ${lib.concatMapStringsSep " and " who from}): both provide the same name; rename the consumer's own"
          else "tuteur: ${kind} ${k} (from ${lib.concatStringsSep " and " from}): two patterns provide the same name")
        else ok (v (lib.head from))) (gather keys kind);

      tools = merge keysStrict "tools";
      # tuteur's own names, taken by a unit: raised by the tools, which every repo builds
      taken = kind: k: map (n: "tuteur: ${kind} ${k} (from ${n}): that name is tuteur's; ${if n == "self" then "rename the repo's own" else "the provider must rename it"}")
        (lib.filter (n: lib.elem k (keysOf n kind)) units);
      reserved = taken "apps" "tuteur" ++ taken "packages" "tools"
        ++ lib.concatMap (k: taken "apps" k ++ taken "packages" k) [ "sandbox" "pot" "pot-kits" ];
      warnEmpty = x: if empty == [ ] then x
        else lib.warn (emptyMsg empty ", so the tools leave out what ${if lib.length empty == 1 then "it gives" else "they give"}") x;
      toolsUnwrapped = ok (if reserved != [ ] then throw (lib.concatStringsSep "\n" reserved)
        else warnEmpty (pkgs.buildEnv { name = "tools"; paths = lib.attrValues tools; }));
      # v2.18.0 (D4): each kit command's wrapper over the tool of the same name, so pot runs kit code under its
      # own policy; passthru.unwrapped is the tools as before, for Nix consumers and a worker that runs no pot
      toolsEnv = if !hasPot then warnKits toolsUnwrapped else ok (builtins.seq toolsUnwrapped.drvPath pkgs.buildEnv {
        name = "tools";
        paths = lib.attrValues tools ++ [ (lib.hiPrio potKits.wrappers) ];
        passthru = { unwrapped = toolsUnwrapped; };
      });
      # the kits, for pot: the repo kit (perSystem's `kit`) and each provider's, handed to pot's library unread
      kitOf = n: results.${n}.kit or null;
      kitFile = n: if n == "self" then "flake.nix (perSystem)" else fileOf n;
      kitUnits = lib.filterAttrs (_: v: v != null) (lib.genAttrs units (n:
        let k = ctx n (kitOf n); in if k == null then null else { kit = k; file = kitFile n; }));
      tuteurForRepo = cli pkgs { TUTEUR_DIR = folder; TUTEUR_IN_REPO = "1"; };
      # no inputs.pot: the kits go nowhere, said once (on the tools, which every repo builds)
      warnKits = x: if kitUnits == { } then x
        else lib.warn ("tuteur: ${lib.concatMapStringsSep ", " kitFile (lib.attrNames kitUnits)} declare${lib.optionalString (lib.length (lib.attrNames kitUnits) == 1) "s"} a kit for pot, "
          + "but this flake has no inputs.pot: no packages.<system>.pot-kits, so no run applies ${if lib.length (lib.attrNames kitUnits) == 1 then "it" else "them"}; "
          + "add inputs.pot.url = \"github:danielnaab/pot/v0.3.0\"; to use pot") x;
      potKits = ok (kitsFor {
        inherit pkgs;
        self = kitUnits.self or null;
        scions = removeAttrs kitUnits [ "self" ];
        tools = lib.attrValues tools ++ [ tuteurForRepo ];
        # tuteur's own files: every provider file (pattern.nix, or tuteur.nix) and the patterns folder are read-only in a run
        files = [ "**/pattern.nix" "**/tuteur.nix" folder ];
        # tuteur's own recipes, in the same kits.just as the kits' (v2.18.0)
        recipes = {
          outdated = { run = "tuteur outdated"; description = "Show the pinned and newest tag of each pattern"; };
          upgrade = { run = "tuteur upgrade"; description = "Move patterns to newer release tags (NAME, or NAME@TAG)"; };
          tuteur-check = { run = "tuteur check"; description = "Check that every pattern is clean and at a release tag"; };
        };
      });
      devShells = lib.mapAttrs (_: ok) (results.self.devShells or { });
      ownDefault = devShells ? default || outputs ? devShells.${system}.default;
    in
    {
      # packages' names by keysOf too: `nix build .#NAME` and `nix eval` look in packages.<system>
      # first, so its names must evaluate for the repo's own outputs (and apps.tuteur) to; the tools
      # (strict) fail on the provider instead
      packages = removeAttrs (merge keysOf "packages") [ "tools" "pot-kits" "sandbox" "pot" ]
        // { tools = toolsEnv; } // lib.optionalAttrs hasPot { pot-kits = potKits; };
      apps = removeAttrs (merge keysOf "apps") [ "tuteur" "sandbox" "pot" "pot-kits" ];
      checks = lib.foldl' (acc: n:
        acc // lib.listToAttrs (map (k: lib.nameValuePair (if n == "self" then k else "${n}-${k}")
          (ok (ctx n results.${n}.checks.${k}))) (keysStrict n "checks"))) { } units;
      devShells = devShells // lib.optionalAttrs (!ownDefault) {
        default = ok (pkgs.mkShell { packages = [ toolsEnv ]; });   # the wrapped tools
      };
    };

  bySystem = lib.genAttrs systems forSystem;
  tuteurOut = lib.genAttrs [ "packages" "apps" "checks" "devShells" ]
    (kind: lib.mapAttrs (_: o: o.${kind}) bySystem);

  # the repo's own last, per system and name (a derivation is replaced whole, never merged into)
  merged = lib.recursiveUpdateUntil
    (path: l: r: lib.length path >= 3 || !(builtins.isAttrs l && builtins.isAttrs r)) tuteurOut outputs;

  # tuteur's own outputs: the repo's own `outputs` may not replace them; sandbox and pot are reserved
  own = system: kind: k: v: if outputs ? ${kind}.${system}.${k}
    then throw "tuteur: mkFlake's outputs has ${kind}.${system}.${k}: that name is tuteur's; rename the repo's own"
    else v;
  reservedOut = lib.concatMap (kind: lib.concatMap (s: map (k: "tuteur: mkFlake's outputs has ${kind}.${s}.${k}: that name is reserved (pot); rename the repo's own")
    (lib.filter (k: lib.elem k [ "sandbox" "pot" ]) (lib.attrNames (outputs.${kind}.${s} or { }))))
    (lib.attrNames (outputs.${kind} or { }))) [ "apps" "packages" ];
  noReserved = v: if reservedOut == [ ] then v else throw (lib.concatStringsSep "\n" reservedOut);
  tuteurApps = system:
    let pkgs = nixpkgs.legacyPackages.${system}; in
    lib.mapAttrs (own system "apps") {
      tuteur = {
        type = "app";
        program = lib.getExe (cli pkgs { TUTEUR_DIR = folder; TUTEUR_IN_REPO = "1"; });
        meta.description = "tuteur: add, sync, check, outdated, upgrade, changelog, migrate, ci";
      };
    };
in
merged // {
  apps = (merged.apps or { }) // lib.genAttrs systems (s: lib.mapAttrs (_: noReserved) (merged.apps.${s} or { }) // tuteurApps s);
  packages = (merged.packages or { }) // lib.genAttrs systems (s: lib.mapAttrs (_: noReserved) (merged.packages.${s} or { })
    // lib.optionalAttrs (hasPot || outputs ? packages.${s}.pot-kits) {
      pot-kits = own s "packages" "pot-kits" (bySystem.${s}.packages.pot-kits or null);
    });
}
