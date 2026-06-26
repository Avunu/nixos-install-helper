# mk-installer-iso.nix
# ─────────────────────────────────────────────────────────────────────────────
# Build the installer-ISO nixosSystem that boots straight into the install
# script with a full OFFLINE closure baked in. Generalized from nixos-router's
# build-iso.sh. Two modes:
#
#   • "unattended" — bakes the EXACT per-host `target` toplevel; the install
#     script runs disko-install non-interactively. Optional secret assets are
#     embedded on the ISO and copied to the target via --extra-files.
#   • "guided"     — bakes a TEMPLATE `target` toplevel + trivial-builder deps;
#     the gum install script collects identity/disk/secrets, installs the
#     template offline, seeds settings, and a first-boot reconcile applies
#     identity. Assets are provided at install time (ISO stays generic).
{
  lib,
  nixpkgs,
  disko,
  system,
  # The consuming flake's `self`; its source is shipped to /etc/installer-flake
  # for disko-install to re-evaluate offline, and its inputs are baked.
  flakeSelf,
  # The evaluated nixosSystem to install (per-host or template).
  target,
  # Install manifest written to /etc/installer-manifest.json and read by the boot
  # scripts: { hostAttr, diskName, diskDevice, mode, flakeStyle, upstream,
  # deployedConfiguration, assets = [{ name; target; mode; }] }.
  manifest ? { },
  # Absolute path to the bash install script run as the boot console session.
  installScript,
  # Secret assets to embed (unattended only): list of
  #   { name; source = <store path/file>; mode ? "0400"; }
  # copied to the target by the install script via --extra-files.
  embeddedAssets ? [ ],
  # Extra store paths to force onto the ISO (guided: trivial-builder deps).
  extraClosurePaths ? [ ],
  extraSystemPackages ? [ ],
  # Lightening toggles (router drops zfs; cocalico's install system is xfs-only).
  dropZfs ? false,
  dropDocs ? true,
  dropBluetooth ? true,
}:
let
  offlineClosure = import ./offline-closure.nix {
    inherit lib flakeSelf target;
    pkgs = nixpkgs.legacyPackages.${system};
    extraPaths = extraClosurePaths ++ (map (a: a.source) embeddedAssets);
  };
in
nixpkgs.lib.nixosSystem {
  inherit system;
  modules = [
    "${nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-minimal.nix"
    (
      { pkgs, lib, ... }:
      {
        environment.etc = lib.mkMerge (
          [
            # Ship the self-contained install flake (consuming flake source + its
            # relative-path inputs) so disko-install can re-evaluate offline.
            { "installer-flake".source = flakeSelf.outPath; }
            # The COMPLETE offline install closure (store paths list).
            { "install-closure".source = "${offlineClosure.closureInfo}/store-paths"; }
            # Manifest read by the boot scripts.
            { "installer-manifest.json".text = builtins.toJSON manifest; }
          ]
          # Embed secret assets (unattended): each lands at
          # /etc/installer-assets/<name>; the script copies it with --extra-files.
          ++ map (a: {
            "installer-assets/${a.name}" = {
              source = a.source;
              mode = a.mode or "0400";
            };
          }) embeddedAssets
        );

        isoImage.storeContents = [ offlineClosure.closureInfo ];

        nix.settings.experimental-features = [
          "nix-command"
          "flakes"
        ];

        # Guaranteed-offline appliance install: forbid network so a missing store
        # path fails fast with a clear error instead of a confusing fetch hang.
        nix.settings.substituters = lib.mkForce [ ];
        nix.settings.builders = lib.mkForce [ ];

        environment.systemPackages = [
          disko.packages.${system}.default # provides disko + disko-install
          pkgs.nixos-install-tools
          pkgs.util-linux
          pkgs.efibootmgr
          pkgs.less
          pkgs.gum # interactive guided-install menus
          pkgs.jq # schema/settings handling on the ISO
        ]
        ++ extraSystemPackages;

        # ── kmscon console with real scrollback (Shift+PageUp) ────────────────
        services.kmscon = {
          enable = true;
          config.sb-size = 50000;
        };
        services.getty.autologinUser = lib.mkForce "root";

        # Launch the installer as the first console login (under kmscon, so its
        # output scrolls). The run-once flag keeps later VTs as debug shells.
        programs.bash.loginShellInit = ''
          if [ ! -e /run/install-helper.started ]; then
            : > /run/install-helper.started
            exec ${pkgs.bashInteractive}/bin/bash ${installScript}
          fi
        '';

        # ── Lighten the installer image ───────────────────────────────────────
        boot.supportedFilesystems.zfs = lib.mkIf dropZfs (lib.mkForce false);
        documentation.enable = lib.mkIf dropDocs (lib.mkForce false);
        documentation.nixos.enable = lib.mkIf dropDocs (lib.mkForce false);
        hardware.bluetooth.enable = lib.mkIf dropBluetooth (lib.mkForce false);
      }
    )
  ];
}
