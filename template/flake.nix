{
  inputs.self.submodules = true;
  inputs.tuteur.url = "github:danielnaab/tuteur/v0.1.0";
  # Where agents or kit commands run under pot, take pot too (mkFlake then builds pot-kits):
  #   inputs.pot.url = "github:danielnaab/pot/v0.1.0";
  outputs = inputs: inputs.tuteur.lib.mkFlake { inherit inputs; };
}
