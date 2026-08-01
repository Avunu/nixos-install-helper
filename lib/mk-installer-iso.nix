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
  # The exact per-root settings that produced `target`, as a DIR of flat
  # `<root>-settings.json` files. Shipped to /etc/installer-settings/;
  # unattended-install.sh points IH_SETTINGS_DIR at it so disko-install's impure
  # re-eval reproduces the baked toplevel offline, and seeds the files into /etc/nixos.
  settingsDir ? null,
  # Synthesized minimal local flake.nix (local flakeStyle). Shipped to
  # /etc/installer-local-flake/flake.nix; the install scripts seed it (with
  # settings.json) into /etc/nixos instead of copying the whole project flake.
  localFlakeNix ? null,
  # Placeholder machine-local module seeded alongside it as /etc/nixos/local.nix
  # (extra packages / per-host NixOS config the JSON settings cannot express).
  localModuleNix ? null,
  # Extra store paths to force onto the ISO (guided: trivial-builder deps).
  extraClosurePaths ? [ ],
  extraSystemPackages ? [ ],
  # Extra NixOS modules merged into the ISO system itself — e.g. a hardware
  # kernel the installer must boot with (cocalico's strix-halo linuxPackages_6_18).
  isoModules ? [ ],
  # mksquashfs compression for the ISO's nix store. See the isoImage assignment
  # below for why this is NOT nixpkgs' default. null disables compression.
  squashfsCompression ? "zstd -Xcompression-level 6",
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
    # disko-install forces the --disk devices onto boot.loader.grub.devices, which
    # changes the installed system; the offline closure has to cover that. Empty
    # for a guided ISO, whose device is chosen on the box.
    grubDevices = lib.optional (manifest.diskDevice or "" != "") manifest.diskDevice;
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
            # Manifest read by the boot scripts. `diskoInstallCli` is disko's own
            # install-cli.nix — the expression disko-install evaluates — so the
            # preflight in lib-preflight.sh can ask nix what that evaluation would
            # BUILD before the disk is touched, rather than finding out from a
            # failed download halfway through. Named here rather than discovered
            # on the box: the path is a private detail of the disko package, and
            # digging it out of the wrapper script at runtime would be guesswork.
            {
              "installer-manifest.json".text = builtins.toJSON (
                manifest
                // {
                  diskoInstallCli = "${disko.packages.${system}.default}/share/disko/install-cli.nix";
                }
              );
            }
          ]
          # The per-root settings that baked `target` (a dir of flat
          # <root>-settings.json), so disko-install's impure re-eval (via
          # IH_SETTINGS_DIR) reproduces the exact baked toplevel offline.
          ++ lib.optional (settingsDir != null) {
            "installer-settings".source = settingsDir;
          }
          # Synthesized local flake seeded into /etc/nixos by the install scripts.
          ++ lib.optional (localFlakeNix != null) {
            "installer-local-flake/flake.nix".source = localFlakeNix;
          }
          # …and its placeholder local.nix, seeded next to it.
          ++ lib.optional (localModuleNix != null) {
            "installer-local-flake/local.nix".source = localModuleNix;
          }
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

        # ── squashfs compression ──────────────────────────────────────────────
        # nixpkgs defaults this to `zstd -Xcompression-level 19`, which is sized
        # for a ~1 GB minimal ISO that is built once on Hydra and downloaded a
        # million times. This ISO is the opposite case: it carries a COMPLETE
        # offline install closure (a desktop or router system plus every flake
        # input source — routinely 6-10 GB), it is built by one technician, and
        # it is written straight to a USB stick.
        #
        # The difference is not marginal. Measured on an i7-8550U, zstd -T8 over
        # a 228 MiB store binary: level 19 took 47.2 s (4.8 MB/s), level 6 took
        # 2.1 s (110 MB/s) — 23x — for 18% more output. Over a 9 GB store that
        # is ~30 minutes of mksquashfs versus ~1.5, and mksquashfs suppresses its
        # progress bar when stdout is not a tty, so those 30 minutes are entirely
        # SILENT after "Creating 4.0 filesystem on nix-store.squashfs" — which
        # reads exactly like a hung build.
        #
        # Nothing on the boot side pays for this: zstd decompression speed is
        # essentially independent of the level it was compressed at, so the ISO
        # boots and installs just as fast. mkDefault so a project can still ask
        # for a smaller image via `isoModules`.
        isoImage.squashfsCompression = lib.mkDefault squashfsCompression;

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
          # A bare service inherits no TERM/locale (agetty/login would set them).
          # gum/bubbletea need TERM for cursor addressing and a UTF-8 locale for
          # its box-drawing glyphs — without these the menus render as garbage.
          environment = {
            TERM = "linux";
            LANG = "C.UTF-8";
            LC_ALL = "C.UTF-8";
          };
          script = "${pkgs.bashInteractive}/bin/bash ${installScript}";
          serviceConfig = {
            Restart = "no";
            # BOTH stdout and stderr must be the real tty. gum draws its UI on
            # stderr (stdout carries the chosen value); routing stderr to
            # journald makes it a pipe, so gum's isatty() fails and it renders
            # corrupted. Log to /tmp/install-helper.log (the scripts tee there)
            # instead of the journal so the interactive UI stays clean.
            StandardInput = "tty-force";
            StandardOutput = "tty";
            StandardError = "tty";
            TTYPath = "/dev/tty1";
            TTYReset = true;
            TTYVHangup = true;
            Type = "idle";
            # Keep kernel log spam from painting over the menus mid-render.
            ExecStartPre = "-${pkgs.util-linux}/bin/dmesg --console-level 1";
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
