# @HOST@ — a NixOS machine managed from this repository.
#
# The machine rebuilds straight from GitHub (@OWNER@/@REPO@): push to the
# default branch and its next upgrade switches to it. flake.lock decides every
# version, so update it here (`nix flake update`), not on the machine.
#
#   nix run        install it: network (nixos-anywhere) or an offline ISO
#   nix develop    agenix for editing secrets/; also what direnv loads
{
  @NIX_CONFIG@
  inputs = {
    @UPSTREAM_INPUT@.url = "@UPSTREAM@";
    nixpkgs.follows = "@UPSTREAM_INPUT@/nixpkgs";
  };

  outputs =
    {
      self,
      nixpkgs,
      @UPSTREAM_INPUT@,
      ...
    }@inputs:
    let
      # Reads @ROOT@-settings.json and secrets/ by itself; host.nix is the rest.
      host = @UPSTREAM_INPUT@.lib.mkHost {
        inherit self nixpkgs;
        repo = "github:@OWNER@/@REPO@";
        modules = [ ./host.nix ];
        # host.nix reaches every input above as `inputs`.
        specialArgs = { inherit inputs; };
      };
    in
    {
      inherit (host)
        nixosModules
        nixosConfigurations
        packages
        apps
        devShells
        ;
    };
}
