# examples/minimal — exercises the mkProject schema path on a tiny options module.
# Only the cheap fields (settingsSchema, resolvedRoots) are re-exported so this
# stays a fast evaluation smoke-test:
#   nix eval .#examples.x86_64-linux.minimal.settingsSchema --json
{
  self,
  nixpkgs,
  system,
}:
let
  # A minimal options-bearing module standing in for a real consumer's namespace.
  demoModule =
    { lib, ... }:
    {
      options.demo = with lib; {
        hostName = mkOption {
          type = types.str;
          default = "demo";
          description = "Machine hostname.";
        };
        bootMode = mkOption {
          type = types.enum [
            "uefi"
            "legacy"
          ];
          default = "uefi";
        };
        diskDevice = mkOption {
          type = types.str;
          default = "/dev/sda";
          description = "Install target disk.";
        };
        sshKeys = mkOption {
          type = types.listOf types.str;
          default = [ ];
        };
      };
    };

  proj = self.lib.mkProject {
    inherit nixpkgs system;
    self = self; # the example has no separate consuming flake; reuse framework self
    installModules = [ demoModule ];
    optionRoots = [ "demo" ];
    flakeStyle = "local";
    hints.diskDevice = "disk-device";
  };
in
{
  minimal = {
    inherit (proj) settingsSchema resolvedRoots;
  };
}
