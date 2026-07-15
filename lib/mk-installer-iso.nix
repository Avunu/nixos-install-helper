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
  # Extra NixOS modules merged into the ISO system itself — e.g. a hardware
  # kernel the installer must boot with (cocalico's strix-halo linuxPackages_6_18).
  isoModules ? [ ],
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
  ]
  ++ isoModules
  ++ [
    (
      { pkgs, lib, ... }:
      let
        # Everything the boot install scripts (unattended-install.sh /
        # guided-install.sh / lib-flash.sh) invoke. Shared between the system
        # profile AND the install service's `path` — a systemd unit does NOT
        # inherit /run/current-system/sw/bin, so without this the service fails
        # with "jq: command not found" etc.
        installerTools = [
          disko.packages.${system}.default # disko + disko-install
          pkgs.nixos-install-tools
          pkgs.util-linux # lsblk, mount, umount
          pkgs.efibootmgr
          pkgs.less
          pkgs.gum # interactive menus / prompts
          pkgs.jq # manifest / schema / settings handling
          pkgs.coreutils # tee, cut, mktemp, stat, seq, cp, chmod, sync, dd
          pkgs.gawk # awk
          pkgs.gnugrep
          pkgs.gnused
          pkgs.systemd # reboot / systemctl
        ]
        ++ extraSystemPackages;
      in
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

        environment.systemPackages = installerTools;

        # ── Console: installer on tty1, kmscon debug shells on tty2…6 ─────────
        # kmscon gives the debug VTs real scrollback (Shift+PageUp). It normally
        # also claims tty1 (pulled into getty.target); we drop that pull-in and
        # hand tty1 to a dedicated, discoverable install service instead.
        services.kmscon = {
          enable = true;
          config.sb-size = 50000;
        };
        services.getty.autologinUser = lib.mkForce "root"; # debug VTs

        # Remove the kmscon `kmsconvt@tty1.service` pull-in so the install service
        # can own tty1. kmscon still serves tty2…6 via its `autovt@` alias.
        systemd.targets.getty.wants = lib.mkForce [ ];

        # The installer as a real systemd unit — findable (`systemctl status
        # nixos-install`), journal-logged (`journalctl -u nixos-install`), and
        # robust (no dependency on login-shell profile sourcing). `tty-force`
        # gives the script a controlling terminal so its Enter-countdown, gum
        # prompts (guided), pager and debug shell (on failure) all work.
        systemd.services.nixos-install = {
          description = "nixos-install-helper: run the installer on boot";
          wantedBy = [ "multi-user.target" ];
          after = [ "systemd-user-sessions.service" ];
          conflicts = [ "getty@tty1.service" ];
          restartIfChanged = false;
          # A systemd unit gets no system PATH — give the script every tool it
          # calls (jq, gum, disko-install, lsblk, coreutils, reboot, …).
          path = installerTools;
          script = "${pkgs.bashInteractive}/bin/bash ${installScript}";
          serviceConfig = {
            RemainAfterExit = true;
            Restart = "no";
            StandardError = "journal+console";
            StandardInput = "tty-force";
            StandardOutput = "tty";
            TTYPath = "/dev/tty1";
            TTYReset = true;
            TTYVHangup = true;
            Type = "oneshot";
          };
        };

        # ── Lighten the installer image ───────────────────────────────────────
        boot.supportedFilesystems.zfs = lib.mkIf dropZfs (lib.mkForce false);
        documentation.enable = lib.mkIf dropDocs (lib.mkForce false);
        documentation.nixos.enable = lib.mkIf dropDocs (lib.mkForce false);
        hardware.bluetooth.enable = lib.mkIf dropBluetooth (lib.mkForce false);
      }
    )
  ];
}
