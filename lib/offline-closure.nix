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
  # True when the target device is picked ON THE BOX rather than baked (a guided
  # ISO). Then `diskoScript` cannot be baked at all — see `trivialBuilderDeps`.
  deviceChosenOnTarget ? false,
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

  # ── The one thing a guided ISO cannot bake ─────────────────────────────────
  # disko writes the target device path INSIDE `diskoScript`. Bake it for the
  # template's device and you get a byte-identical path back on the box — but
  # only if the technician picks that same device, which on a guided ISO is
  # precisely what nobody knows in advance. There is no candidate set to bake
  # against: the answer is whatever is plugged into the machine.
  #
  # So ship what BUILDING one costs instead of guessing. `.inputDerivation` is
  # nixpkgs' name for exactly that question — a derivation whose output
  # REFERENCES every build input of the one it came from — so its closure is
  # "everything needed to build this and nothing else". Taken from disko's own
  # `system.build` outputs rather than reconstructed here, so it cannot drift
  # from the writer disko actually uses:
  #
  #   diskoScript  the `ln -s …/bin/disko $out` wrapper
  #   formatMount  the script package the wrapper points at — the one with the
  #                device path in it, and the one that must be rebuilt
  #
  # Measured on nixos-nano-desktop: 40 store paths, 335 MB uncompressed, on top
  # of a closure that already carries every tool the script's PATH names. Most
  # of it is a C compiler, and not because anything is compiled — nixpkgs'
  # script writer lists `makeBinaryWrapper` as a build input, and that hook
  # carries cc in its runtime closure whether or not a wrapper is written.
  #
  # It is a real cost and it is bounded: it does not scale with the project, and
  # it is the difference between a guided ISO that installs offline and one that
  # dies fetching a bison tarball from gnu.org with the disk already wiped.
  trivialBuilderDeps = lib.optionals deviceChosenOnTarget (
    map (d: d.inputDerivation) (
      lib.filter (d: d != null) [
        target.config.system.build.diskoScript
        target.config.system.build.formatMount or null
      ]
    )
  );

  installDeps = [
    target.config.system.build.toplevel
    target.config.system.build.diskoScript
    # `disko-install --mode mount` builds `-A mountScript` instead of
    # `-A diskoScript` — the same install against an existing layout, without
    # reformatting. It is a supported mode and the obvious way to re-run a
    # failed install or refresh a system in place, and without this the ISO can
    # only ever do the destructive one.
    target.config.system.build.mountScript
    target.pkgs.perlPackages.ConfigIniFiles
    target.pkgs.perlPackages.FileSlurp
  ]
  ++ trivialBuilderDeps
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
