# local.nix — configuration for THIS machine beyond its settings file.
#
# flake.nix pulls the shared module(s) from upstream, and the values the
# installer asked about live in the *-settings.json file next to this one.
# This file is everything else: plain NixOS configuration, merged on top.
#
# Changes reach the machine by being pushed: its daily upgrade switches to
# whatever the default branch holds. To apply one sooner, on the machine:
#   sudo systemctl start system-upgrade    (or nixos-upgrade, per project)
#
# Extra software is the usual reason to be here. Package names cannot live in
# the JSON settings (a package is a Nix value, not a string), so they go below.
# Find names at https://search.nixos.org/packages.
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
{
  environment.systemPackages = with pkgs; [
    # gimp
    # vlc
  ];

  # A package from another flake: add the input to flake.nix, then reach it
  # here through `inputs`, e.g.
  # environment.systemPackages = [
  #   inputs.some-flake.packages.${pkgs.stdenv.hostPlatform.system}.default
  # ];
}
