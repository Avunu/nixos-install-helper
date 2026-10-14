# modules/install-helper.nix
# ─────────────────────────────────────────────────────────────────────────────
# The small NixOS module both flake styles import. It owns the post-install
# lifecycle:
#
#   • remote  — boot the minimal install system, then a ONE-SHOT initial upgrade
#     pulls the production config from `deployedConfiguration` and switches once;
#     thereafter system.autoUpgrade keeps it current. (Generalizes the
#     initial-upgrade service of a client's server config.)
#   • local   — a first-boot reconcile applies the technician's seeded
#     /etc/nixos config (this is how a GUIDED install applies the host identity
#     that wasn't baked into the offline template closure).
#   • repo    — the machine's own configuration lives in a (usually private)
#     repository, `repo.url`, and the machine keeps switching to whatever that
#     repository publishes. Nothing is seeded into /etc/nixos: the repository is
#     the one place the machine changes. A private GitHub repository is read
#     with the token in `repo.accessTokensFile`.
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
        "repo"
      ];
      default = "local";
      description = ''
        "local": ongoing updates via a seeded /etc/nixos flake (downstream).
        "remote": boot minimal, then track an upstream production flake.
        "repo": track this machine's own configuration repository (`repo`).
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
    repo = {
      url = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "github:Owner/host-name";
        description = ''
          The flake (without `#attr`) holding THIS machine's configuration, for
          repo style. Use the `github:` scheme for a private GitHub repository:
          nix's `access-tokens` authenticate the github fetcher, not git+https.
        '';
      };
      attr = lib.mkOption {
        type = lib.types.str;
        default = "default";
        description = "nixosConfigurations attribute of `url` this machine runs.";
      };
      flakeRef = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        readOnly = true;
        default = if cfg.repo.url == null then null else "${cfg.repo.url}#${cfg.repo.attr}";
        defaultText = lib.literalExpression ''"''${url}#''${attr}"'';
        description = ''
          `url#attr`, for a module that runs its own upgrade timer (and so sets
          `autoUpgrade = false`) to point that timer at.
        '';
      };
      accessTokensFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = lib.literalExpression "config.age.secrets.github-token.path";
        description = ''
          A root-only file whose contents are nix.conf lines, typically
          `access-tokens = github.com=<read-only token>`, pulled into nix.conf
          with `!include` at runtime. A path string, NOT a Nix path: the token
          must never be copied into the world-readable store. The leading `!`
          makes a missing file harmless (early boot, a VM without the secret).
        '';
      };
      autoUpgrade = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Keep the machine current with `system.autoUpgrade` pointed at
          `flakeRef`. Turn off when the project already runs an upgrade timer of
          its own, and point that at `flakeRef` instead.
        '';
      };
    };
    reconcile = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Opt-in first-boot reconcile (local style): rebuild the seeded
        /etc/nixos flake once on first boot. Default off — for a normal local
        install the baked system is already complete and agenix secrets activate
        at boot without a rebuild. Turn on for a STAGED local install (a minimal
        `installModules` baked offline, the full module imported by the
        synthesized /etc/nixos flake). A guided install triggers the same
        reconcile via an `/etc/nixos/.first-boot-reconcile` marker regardless of
        this option, to apply the identity chosen on the box.
      '';
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

      # ── repo: authenticate, then keep switching to the published config ────
      (lib.mkIf (cfg.flakeStyle == "repo") {
        assertions = [
          {
            assertion = cfg.repo.url != null;
            message = "installHelper.flakeStyle = \"repo\" needs installHelper.repo.url.";
          }
          {
            assertion = cfg.repo.url == null || !lib.hasPrefix "git+https://github.com" cfg.repo.url;
            message = ''
              installHelper.repo.url is ${toString cfg.repo.url}; nix's access-tokens
              only authenticate the github: fetcher. Use github:Owner/repo instead.
            '';
          }
        ];

        nix.extraOptions = lib.mkIf (cfg.repo.accessTokensFile != null) ''
          !include ${cfg.repo.accessTokensFile}
        '';

        system.autoUpgrade = lib.mkIf (cfg.repo.autoUpgrade && cfg.repo.flakeRef != null) {
          enable = lib.mkDefault true;
          flake = cfg.repo.flakeRef;
          # Without --refresh nix trusts a fetched tarball for tarball-ttl (an
          # hour), so a push could sit unapplied past the next run.
          flags = [ "--refresh" ];
          dates = lib.mkDefault "03:00";
          randomizedDelaySec = lib.mkDefault "30min";
        };
      })

      # ── local: opt-in / guided first-boot reconcile of seeded /etc/nixos ────
      # The service ships on every local install but is a no-op unless it is opted
      # in at build time (`reconcile = true`, for staged-local) OR a guided install
      # dropped the /etc/nixos/.first-boot-reconcile marker (to apply the chosen
      # identity). It rebuilds the synthesized flake's stable `#default` attr.
      (lib.mkIf (cfg.flakeStyle == "local") {
        systemd.services.install-helper-reconcile = {
          description = "Install-helper: first-boot reconcile of the seeded /etc/nixos config";
          wantedBy = [ "multi-user.target" ];
          after = [ "network-online.target" ];
          wants = [ "network-online.target" ];
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
            # Only reconcile when opted in at build time, or when a guided install
            # asked for it via the marker. Otherwise the baked system is final.
            if [ "${lib.boolToString cfg.reconcile}" != "true" ] \
                && [ ! -e /etc/nixos/.first-boot-reconcile ]; then
              echo ":: install-helper: reconcile not requested; baked system is final"
              touch ${stampDir}/reconcile.done
              exit 0
            fi
            echo ":: install-helper: reconciling /etc/nixos#default"
            if nixos-rebuild switch --flake "/etc/nixos#default"; then
              rm -f /etc/nixos/.first-boot-reconcile
              touch ${stampDir}/reconcile.done
              echo ":: install-helper: reconcile complete"
            else
              echo "!! install-helper: reconcile failed; leaving baked system active" >&2
              exit 1
            fi
          '';
        };
      })
    ]
  );
}
