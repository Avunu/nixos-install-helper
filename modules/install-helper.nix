# modules/install-helper.nix
# ─────────────────────────────────────────────────────────────────────────────
# The small NixOS module both flake styles import. It owns the post-install
# lifecycle:
#
#   • remote  — boot the minimal install system, then a ONE-SHOT initial upgrade
#     pulls the production config from `deployedConfiguration` and switches once;
#     thereafter system.autoUpgrade keeps it current. (Generalizes cocalico's
#     initial-upgrade service.)
#   • local   — a first-boot reconcile applies the technician's seeded
#     /etc/nixos config (this is how a GUIDED install applies the host identity
#     that wasn't baked into the offline template closure).
#
# Secret assets (e.g. the agenix key) are placed by the installer via
# disko-install/nixos-anywhere --extra-files; wiring agenix to read them is the
# consuming project's concern (this module stays agnostic).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.installHelper;
  stampDir = "/var/lib/install-helper";
in
{
  options.installHelper = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable the install-helper post-install lifecycle.";
    };
    flakeStyle = lib.mkOption {
      type = lib.types.enum [
        "local"
        "remote"
      ];
      default = "local";
      description = ''
        "local": ongoing updates via a seeded /etc/nixos flake (downstream).
        "remote": boot minimal, then track an upstream production flake.
      '';
    };
    upstream = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Upstream flake (github:Owner/repo) seeded into /etc/nixos for local style.";
    };
    deployedConfiguration = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Production flake ref with attr (github:Owner/repo#attr) for remote style.";
    };
    reconcile = lib.mkOption {
      type = lib.types.bool;
      default = cfg.flakeStyle == "local";
      description = "Run a first-boot reconcile against the seeded /etc/nixos flake.";
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      # ── remote: one-shot initial upgrade + ongoing autoUpgrade ──────────────
      (lib.mkIf (cfg.flakeStyle == "remote" && cfg.deployedConfiguration != null) {
        system.autoUpgrade = {
          enable = lib.mkDefault true;
          flake = cfg.deployedConfiguration;
          dates = lib.mkDefault "03:00";
          randomizedDelaySec = lib.mkDefault "30min";
        };

        systemd.services.install-helper-initial-upgrade = {
          description = "Install-helper: first-boot upgrade to the production flake";
          wantedBy = [ "multi-user.target" ];
          after = [ "network-online.target" ];
          wants = [ "network-online.target" ];
          unitConfig.ConditionPathExists = "!${stampDir}/initial-upgrade.done";
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          path = [
            pkgs.nixos-rebuild
            pkgs.nix
            pkgs.systemd
          ];
          script = ''
            set -euo pipefail
            mkdir -p ${stampDir}
            echo ":: install-helper: switching to ${cfg.deployedConfiguration}"
            if nixos-rebuild boot --flake "${cfg.deployedConfiguration}"; then
              touch ${stampDir}/initial-upgrade.done
              echo ":: install-helper: production config staged; rebooting"
              systemctl reboot
            else
              echo "!! install-helper: initial upgrade failed; will retry next boot" >&2
              exit 1
            fi
          '';
        };
      })

      # ── local: first-boot reconcile against seeded /etc/nixos ───────────────
      (lib.mkIf (cfg.flakeStyle == "local" && cfg.reconcile) {
        systemd.services.install-helper-reconcile = {
          description = "Install-helper: first-boot reconcile of the seeded /etc/nixos config";
          wantedBy = [ "multi-user.target" ];
          after = [ "network.target" ];
          unitConfig.ConditionPathExists = [
            "!${stampDir}/reconcile.done"
            "/etc/nixos/flake.nix"
          ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          path = [
            pkgs.nixos-rebuild
            pkgs.nix
            pkgs.git
          ];
          script = ''
            set -euo pipefail
            mkdir -p ${stampDir}
            echo ":: install-helper: reconciling /etc/nixos#install"
            # Trivial identity diffs (hostname/users/network) build offline from
            # the baked closure; falls back to substituters only if reachable.
            if nixos-rebuild switch --flake "/etc/nixos#install"; then
              touch ${stampDir}/reconcile.done
              echo ":: install-helper: reconcile complete"
            else
              echo "!! install-helper: reconcile failed; leaving template active" >&2
              exit 1
            fi
          '';
        };
      })
    ]
  );
}
