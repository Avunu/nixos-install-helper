# examples/cluster-node — one machine of several: mkProject called per machine,
# with nothing to ask, no single install disk and a pre-install hook.
# Evaluates the pieces a network deploy uses:
#   nix eval .#examples.x86_64-linux.cluster-node --json
{
  self,
  nixpkgs,
  system,
}:
let
  pkgs = nixpkgs.legacyPackages.${system};

  # Two disks, each named by the machine itself: there is no `disk.main`.
  machine =
    name:
    { ... }:
    {
      networking.hostName = name;
      fileSystems."/" = {
        device = "/dev/disk/by-label/${name}-root";
        fsType = "ext4";
      };
      boot.loader.grub.devices = [ "/dev/disk/by-id/${name}-a" ];
      system.stateVersion = "25.11";
    };

  installer =
    name:
    self.lib.mkProject {
      inherit nixpkgs system;
      self = self;
      installModules = [ (machine name) ];
      hostAttr = name;
      diskName = null;
      questionnaire = false;
      lifecycle = false;
      guided = false;
      agePlugins = [ pkgs.age-plugin-yubikey ];
      ageIdentities = [ "secrets/master/yubikey-1.pub" ];
      preInstall = pkgs.writeShellScriptBin "pre-install" ''
        echo "would make a key on $IH_TARGET's TPM for $IH_HOST_ATTR"
      '';
    };

  node1 = installer "node1";
in
{
  cluster-node = {
    inherit (node1) resolvedRoots;
    # The machine is returned under its own name as well as `install`.
    hostNames = builtins.attrNames node1.nixosConfigurations;
    hostName = node1.nixosConfigurations.node1.config.networking.hostName;
    # Only what a network install needs is offered.
    apps = builtins.attrNames node1.apps.${system};
    packages = builtins.attrNames node1.packages.${system};
    checks = builtins.attrNames node1.checks.${system};
  };
}
