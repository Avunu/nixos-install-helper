# This machine's configuration beyond its settings file.
#
# @ROOT@-settings.json holds the @ROOT@.* values the installer asked about
# (host name, user, disk, SSH keys, …); the flake applies it, along with this
# machine's agenix identity and GitHub token. This file is everything else:
# plain NixOS configuration, merged on top.
#
# Changes reach the machine by being pushed: its next upgrade switches to
# whatever the default branch holds.
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
    # htop
  ];

  # A secret for this machine: declare it in secrets.nix (encrypted to
  # `admins ++ [ host ]`), create it with `agenix -e secrets/<name>.age`, then
  #   age.secrets.<name>.file = ./secrets/<name>.age;

  # A package from another flake: add the input to flake.nix, then reach it
  # here through `inputs`, e.g.
  # environment.systemPackages = [
  #   inputs.some-flake.packages.${pkgs.stdenv.hostPlatform.system}.default
  # ];
}
