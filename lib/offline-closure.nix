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

  installDeps = [
    target.config.system.build.toplevel
    target.config.system.build.diskoScript
    target.pkgs.perlPackages.ConfigIniFiles
    target.pkgs.perlPackages.FileSlurp
  ]
  ++ extraPaths
  ++ flakeOutPaths;

  # closureInfo's store-paths output references the full closure of every dep;
  # referencing it from the installer's /etc pulls them all onto the ISO store.
  closureInfo = pkgs.closureInfo { rootPaths = installDeps; };
in
{
  inherit flakeOutPaths installDeps closureInfo;
}
