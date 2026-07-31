# offline-closure.nix
# ─────────────────────────────────────────────────────────────────────────────
# Collect every store path a fully-OFFLINE `disko-install` needs, so the ISO can
# partition + format + install with NO network. Lifted from nixos-router's
# build-iso.sh and generalized.
#
# disko-install RE-EVALUATES the install flake on the appliance, which forces the
# COMPLETE input set (not just the inputs the system uses) — so we ship every
# flake input source transitively, plus the prebuilt system toplevel + disko
# script + the perl modules the activation script needs. We deliberately do NOT
# ship `.drvPath`/the build toolchain: that drags gcc/bootstrap/source tarballs
# (gigabytes) onto the ISO for an appliance that only ever realizes prebuilt
# outputs.
{
  lib,
  pkgs,
  # The flake whose inputs are walked transitively (the consuming project's
  # `self`); its source is what disko-install re-evaluates at /etc/installer-flake.
  flakeSelf,
  # The evaluated target nixosSystem whose closure is baked onto the ISO.
  target,
  # Extra store paths to force onto the ISO (e.g. trivial-builder deps for the
  # guided ISO's first-boot reconcile, or secret-asset files).
  extraPaths ? [ ],
  # The devices disko-install will pass as `--disk <name> <device>`; it forces them
  # onto `boot.loader.grub.devices`, which changes the system it installs. Empty
  # when the device is chosen on the box (guided) — see the note below.
  grubDevices ? [ ],
}:
let
  # Recursively collect EVERY flake input's source path. Keep only top-level
  # store paths; relative-path inputs resolve to subpaths of a flake already
  # shipped via its own source, while their transitive github inputs are still
  # collected by the recursion.
  flakeOutPaths =
    let
      collector =
        parent:
        map (
          child: [ child.outPath ] ++ (if child ? inputs && child.inputs != { } then collector child else [ ])
        ) (lib.attrValues (parent.inputs or { }));
    in
    lib.filter (p: builtins.match "/nix/store/[^/]+" (toString p) != null) (
      lib.unique (lib.flatten (collector flakeSelf))
    );

  # ── What disko-install ACTUALLY installs ───────────────────────────────────
  # Not `target`. disko's share/disko/install-cli.nix installs
  #
  #   originalSystem.extendModules { modules = [{
  #     boot.loader.efi.canTouchEfiVariables = mkVMOverride writeEfiBootEntries;
  #     boot.loader.grub.devices             = mkVMOverride (attrValues diskMappings);
  #   }]; }
  #
  # and `writeEfiBootEntries` is decided ON THE BOX — the install scripts pass
  # --write-efi-boot-entries iff /sys/firmware/efi exists. So the same ISO installs
  # one of TWO systems depending on how the technician's firmware happened to boot
  # it, and baking only `target` leaves the other one unbuilt.
  #
  # The divergence is small — a fresh install-grub.sh, grub-config.xml and the
  # nixos-system derivation that references them — but its consequences are not.
  # Rebuilding even one `stdenv.mkDerivation` needs the BUILD closure, which this
  # file deliberately does not ship (that is gcc + bootstrap + source tarballs,
  # gigabytes), so nix falls through to fetching sources and the install dies
  # offline on something like a CPAN tarball, miles from the actual cause.
  #
  # So bake both. Each variant costs three small paths on top of a closure they
  # otherwise share completely.
  installVariant =
    canTouchEfiVariables:
    target.extendModules {
      modules = [
        (
          { lib, ... }:
          {
            boot.loader.efi.canTouchEfiVariables = lib.mkVMOverride canTouchEfiVariables;
            boot.loader.grub.devices = lib.mkVMOverride grubDevices;
          }
        )
      ];
    };

  # `grubDevices` is empty for a guided ISO, where the disk is picked on the box —
  # so a GRUB (legacy-boot) guided install still diverges by one install-grub.sh.
  # Nothing to do about that from here: the value is the technician's answer to a
  # question the ISO exists to ask. UEFI guided installs, where grub.devices is
  # never read, are covered.
  installVariants = map installVariant [
    true
    false
  ];

  # disko-install builds one more thing on the box: `installSystem.pkgs.closureInfo
  # { rootPaths = [ installToplevel ]; }`, the manifest it copies the store from.
  # Same reasoning — bake it, or the ISO has to build it, and a `runCommand` needs
  # a stdenv that is not there.
  variantRoots = lib.concatMap (v: [
    v.config.system.build.toplevel
    (v.pkgs.closureInfo { rootPaths = [ v.config.system.build.toplevel ]; })
  ]) installVariants;

  installDeps = [
    target.config.system.build.toplevel
    target.config.system.build.diskoScript
    target.pkgs.perlPackages.ConfigIniFiles
    target.pkgs.perlPackages.FileSlurp
  ]
  ++ variantRoots
  ++ extraPaths
  ++ flakeOutPaths;

  # closureInfo's store-paths output references the full closure of every dep;
  # referencing it from the installer's /etc pulls them all onto the ISO store.
  closureInfo = pkgs.closureInfo { rootPaths = installDeps; };
in
{
  inherit flakeOutPaths installDeps closureInfo;
}
