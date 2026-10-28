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
#     the one place the machine changes. lib.mkHost builds one.
#
# Independent of the lifecycle (and of `enable`), two pieces a host repo's
# machine needs and a project can switch on in its own module, so a local
# /etc/nixos install of the same project gets them too:
#
#   • githubTokenFile — a read-only GitHub token (an agenix secret) for
#     private repositories, handed to nix as `access-tokens` and to git as a
#     credential helper, without ever entering the store.
#   • agenixKey — the pre-provisioned agenix identity (/etc/agenix/key) the
#     installers place as an asset: agenix decrypts with it, and its mode is
#     kept root-only.
#
# Secret assets are placed by the installer via disko-install/nixos-anywhere
# --extra-files. agenix itself is the project's to import; nothing here needs
# it unless the project sets agenixKey.
{
  config,
  options,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.installHelper;
  stampDir = "/var/lib/install-helper";

  # Where the nix.conf line built from `githubTokenFile` lands. Root-only, under
  # /run so it never outlives the decrypted secret it was made from.
  accessTokensConf = "/run/install-helper/nix-access-tokens.conf";

  # Build the nix.conf `access-tokens` line from `githubTokenFile`, or remove a
  # stale one. Validated, because whatever lands in accessTokensConf is parsed
  # by EVERY nix invocation on the machine: a bare token !include'd as-is is a
  # syntax error that takes down nix-env, and with it nixos-rebuild and the
  # bootloader install. Anything that is not a token, or an `access-tokens`
  # line, is refused with a warning and nix carries on without credentials.
  renderAccessTokens = pkgs.writeShellScript "install-helper-access-tokens" ''
    set -u
    umask 077
    src=${lib.escapeShellArg (toString cfg.githubTokenFile)}
    dst=${accessTokensConf}
    mkdir -p "$(dirname "$dst")"
    if [ ! -r "$src" ]; then
      # Not decrypted (yet): agenix running as a later systemd unit, or a
      # machine without the secret. The service below retries after agenix.
      rm -f "$dst"
      exit 0
    fi
    line=$(${pkgs.gnugrep}/bin/grep -v '^[[:space:]]*\(#.*\)\?$' "$src" | ${pkgs.coreutils}/bin/head -n1 | ${pkgs.coreutils}/bin/tr -d '\r')
    case "$line" in
      access-tokens[[:space:]]*=*)
        out="$line" ;;
      *)
        token=$(printf '%s' "$line" | ${pkgs.coreutils}/bin/tr -d '[:space:]')
        if printf '%s' "$token" | ${pkgs.gnugrep}/bin/grep -qE '^[A-Za-z0-9_]+$'; then
          out="access-tokens = github.com=$token"
        else
          echo "install-helper: $src is neither a GitHub token nor an access-tokens line; ignoring it" >&2
          rm -f "$dst"
          exit 0
        fi ;;
    esac
    tmp=$(${pkgs.coreutils}/bin/mktemp "$dst.XXXXXX")
    printf '%s\n' "$out" > "$tmp"
    ${pkgs.coreutils}/bin/chmod 0400 "$tmp"
    ${pkgs.coreutils}/bin/mv -f "$tmp" "$dst"
  '';

  # git's half of the token, read from the rendered line above. A credential
  # helper rather than an `[include]` of a generated url.insteadOf file: git
  # dies outright on an include it cannot read, which would break git for
  # every user who is not root. A helper that cannot read the file answers
  # nothing, and git carries on as if it were not configured.
  githubCredentialHelper = pkgs.writeShellScript "git-credential-github-token" ''
    [ "''${1:-}" = get ] || exit 0
    ${pkgs.coreutils}/bin/cat >/dev/null
    [ -r ${accessTokensConf} ] || exit 0
    token=$(${pkgs.gnused}/bin/sed -n 's/.*github\.com=\([^[:space:]]*\).*/\1/p' ${accessTokensConf})
    [ -n "$token" ] || exit 0
    printf 'username=x-access-token\npassword=%s\n' "$token"
  '';
in
{
  imports = [
    (lib.mkRenamedOptionModule
      [ "installHelper" "repo" "accessTokensFile" ]
      [ "installHelper" "githubTokenFile" ]
    )
    (lib.mkRenamedOptionModule
      [ "installHelper" "repo" "tokenFile" ]
      [ "installHelper" "githubTokenFile" ]
    )
  ];

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
    githubTokenFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = lib.literalExpression "config.age.secrets.github-token.path";
      description = ''
        A root-only file holding a read-only GitHub token: the bare token
        (`github_pat_…`), or a full nix.conf line
        `access-tokens = github.com=<token>`. At activation it becomes an
        `access-tokens` line in a root-only file under /run, which nix.conf
        `!include`s, and git (as root) gets it through a credential helper;
        anything that is neither is refused with a warning rather than breaking
        every nix command. A path string, NOT a Nix path: the token must never
        be copied into the world-readable store. Works in every flake style;
        lib.mkHost sets it from a host repo's secrets/github-token.age.
      '';
    };
    agenixKey = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/etc/agenix/key";
      description = ''
        The machine's pre-provisioned agenix identity, as installed by the
        `agenix-key` asset lib.mkHost declares. Set, agenix decrypts with it
        (age.identityPaths, at normal priority: it replaces agenix's default of
        the SSH host keys) and its mode is kept root-only. Requires agenix's
        NixOS module. null leaves agenix alone.
      '';
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

  config = lib.mkMerge [
    # ── GitHub token: nix access-tokens + git credential helper ─────────────
    (lib.mkIf (cfg.githubTokenFile != null) {
      # `!` (don't error if absent): early boot, a VM without the secret.
      nix.extraOptions = ''
        !include ${accessTokensConf}
      '';

      programs.git.config.credential."https://github.com".helper = "${githubCredentialHelper}";

      # At activation, which is where `nixos-install` and every switch need it
      # (the bootloader install runs nix-env right after) — after agenix's own
      # activation-time decryption when it has one…
      system.activationScripts.installHelperAccessTokens = {
        text = "${renderAccessTokens}";
        deps = lib.optional (config.system.activationScripts ? agenixInstall) "agenixInstall";
      };

      # …and again once agenix's systemd unit has run, for systems where it
      # decrypts as a service (sysusers/userborn) rather than at activation.
      systemd.services.install-helper-access-tokens = {
        description = "Install-helper: nix access-tokens from the GitHub token secret";
        wantedBy = [ "multi-user.target" ];
        after = [ "agenix-install-secrets.service" ];
        before = [ "nix-daemon.service" ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = renderAccessTokens;
        };
      };
    })

    # ── agenix identity ─────────────────────────────────────────────────────
    (lib.mkIf (cfg.agenixKey != null) (
      {
        # The installers write the key 0400, but a hand-copied one arrives with
        # whatever mode it had; it is the one file that unlocks every secret.
        systemd.tmpfiles.rules = [
          "z ${dirOf cfg.agenixKey} 0700 root root -"
          "z ${cfg.agenixKey} 0400 root root -"
        ];
      }
      // lib.optionalAttrs (options ? age) {
        age.identityPaths = [ cfg.agenixKey ];
      }
    ))

    (lib.mkIf cfg.enable (
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
    ))
  ];
}
