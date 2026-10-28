# mk-host.nix
# ─────────────────────────────────────────────────────────────────────────────
# lib.mkHost — mkProject for a project whose machines each live in their own
# GitHub repository, and that repository's one call.
#
# A project re-exports it with its own defaults filled in:
#
#   lib.mkHost = args: nixos-install-helper.lib.mkHost ({
#     module = self.nixosModules.devHost;
#     optionRoot = "devHost";
#   } // args);
#
# and calls it twice over:
#
#   upstream = "github:Owner/project";                    (local)
#     The project's own installer: a generic machine whose identity is chosen
#     at install time, living on as a small /etc/nixos flake. Started in an
#     empty directory, its wizard instead offers to BOOTSTRAP a repository for
#     one machine (templates/host-repo, filled in by scripts/bootstrap-host.sh)
#     and continues from that repository's own `nix run`.
#
#   repo = "github:Owner/host-name";                      (repo)
#     What that repository's flake.nix calls. The machine's configuration is
#     the repository: it installs from it and keeps switching to whatever its
#     default branch publishes (`installHelper.repo.flakeRef`, through
#     system.autoUpgrade or the project's own timer), and its flake.lock
#     decides every version. Nothing lives in /etc/nixos.
#
# The identity. A host repo keeps a freshly generated agenix key as
# secrets/key.age, encrypted to the operators only (never to the machine).
# Every install path decrypts it with the operator's SSH key — the wizard and
# deploy through the asset's ageFile, the devShell into $agenix__key — and
# writes it to /etc/agenix/key, where `installHelper.agenixKey` has agenix look
# for it. The SSH host key never enters into it, so a reinstall (new disk, new
# host key) decrypts the same secrets without a re-key.
#
# A host repo's other secret is secrets/github-token.age, a read-only token for
# the (private) repository, encrypted to the operators and the identity above.
# It reaches nix and git through `installHelper.githubTokenFile`.
#
# The project's module must import agenix's NixOS module (secrets are declared
# through it) and should set `installHelper.agenixKey` itself, importing
# nixosModules.installHelper, so a local /etc/nixos install of it gets the same
# identity; mkHost sets it too, for a project that does not.
{
  lib,
  mkProject,
  frameworkSelf,
}:
{
  # The flake calling this: the project (local) or the host repo (repo).
  self,
  nixpkgs,
  system ? "x86_64-linux",
  # The project's NixOS module; every machine imports it.
  module,
  # Its option namespace ("devHost"): what the installer asks about, and the
  # name of the settings file a host repo keeps, <optionRoot>-settings.json.
  optionRoot,
  # Exactly one of these (see above).
  upstream ? null,
  repo ? null,
  # Machine modules, layered over `module`.
  modules ? [ ],
  specialArgs ? { },
  # Identities the devShell tries for secrets/key.age, in order; unreadable
  # ones and public halves are skipped. Shell words, expanded (globs too) when
  # the devShell starts. The default matches the wizard's: every ~/.ssh/id_*.
  identityPaths ? [
    "\${AGENIX_IDENTITY:-}"
    "$HOME/.ssh/id_*"
  ],
  devShellPackages ? [ ],
  # ── Bootstrap (local only): what a new host repository starts as ──────────
  # SSH public keys every new repository's secrets are also encrypted to,
  # beside the machine's own `sshKeys` setting.
  adminKeys ? [ ],
  # The GitHub owner suggested for the repository (default: the gh login).
  defaultOwner ? null,
  # GitHub topic given to a published repository.
  topic ? "nixos-host",
  # A `nixConfig` for the new repository's flake.nix (substituters its
  # inputs need, say). Written as Nix; {} writes none.
  nixConfig ? { },
  # Anything else for mkProject (guidedPrompts, hints, schemaExclude, …); wins
  # over what is derived here.
  installer ? { },
}:
let
  pkgs = nixpkgs.legacyPackages.${system};
  isRepo = repo != null;
  agenixKeyPath = import ./agenix-key-path.nix;

  # Host-repo files, relative to the repository root (templates/host-repo).
  keyAgeName = "secrets/key.age";
  keyAge = self + "/${keyAgeName}";
  tokenAge = self + "/secrets/github-token.age";
  settingsFile = self + "/${optionRoot}-settings.json";
  haveKey = isRepo && builtins.pathExists keyAge;
  haveToken = isRepo && builtins.pathExists tokenAge;

  hostModule =
    { config, ... }:
    {
      imports = [
        module
        frameworkSelf.nixosModules.installHelper
      ]
      ++ modules;
      config = lib.mkMerge [
        {
          # What a project's upgrade timer can compare against the repository's
          # HEAD, and what `nixos-version --configuration-revision` reports.
          system.configurationRevision = self.rev or self.dirtyRev or null;
          installHelper.agenixKey = lib.mkDefault agenixKeyPath;
        }
        # Conditional so the repository still evaluates without it, which is
        # the case for a public one.
        (lib.mkIf haveToken {
          age.secrets.github-token.file = tokenAge;
          installHelper.githubTokenFile = config.age.secrets.github-token.path;
        })
      ];
    };

  # ── The new-repository program (local only) ───────────────────────────────
  upstreamRepoName = lib.last (lib.splitString "/" (lib.head (lib.splitString "?" upstream)));
  # The new repository's name for the upstream input: the upstream repository's
  # name, made a valid identifier.
  upstreamInput =
    let
      cleaned = lib.stringAsChars (
        c: if builtins.match "[A-Za-z0-9_'-]" c != null then c else "-"
      ) upstreamRepoName;
    in
    if
      builtins.match "[A-Za-z_].*" cleaned == null
      || builtins.elem cleaned [
        "self"
        "nixpkgs"
      ]
    then
      "upstream"
    else
      cleaned;

  nixConfigText = lib.optionalString (nixConfig != { }) ''
    # From ${upstreamRepoName}: what building this flake needs from nix.
    nixConfig = ${lib.generators.toPretty { } nixConfig};
  '';

  # templates/host-repo with everything but the per-machine placeholders
  # (@OWNER@ @REPO@ @HOST@ @UPSTREAM@, filled in by the bootstrap) resolved.
  hostRepoTemplate = pkgs.runCommand "host-repo-template" { } ''
    cp -r ${frameworkSelf}/templates/host-repo "$out"
    chmod -R u+w "$out"
    for f in $(find "$out" -type f); do
      substituteInPlace "$f" \
        --replace-quiet @UPSTREAM_INPUT@ ${lib.escapeShellArg upstreamInput} \
        --replace-quiet @ROOT@ ${lib.escapeShellArg optionRoot} \
        --replace-quiet @NIX_CONFIG@ ${lib.escapeShellArg nixConfigText}
    done
  '';

  bootstrapProgram = pkgs.writeShellApplication {
    name = "bootstrap-host";
    runtimeInputs = [
      pkgs.age
      pkgs.coreutils
      pkgs.findutils
      pkgs.gawk
      pkgs.gh
      pkgs.git
      pkgs.gnused
      pkgs.gum
      pkgs.jq
      pkgs.nix
      pkgs.nixfmt
      pkgs.openssh
    ];
    text = ''
      export IH_HOST_TEMPLATE=${hostRepoTemplate}
      # Overridable, to point a trial run at a checkout (path:/…) instead of GitHub.
      export IH_UPSTREAM="''${IH_UPSTREAM:-${upstream}}"
      export IH_HOST_ROOT=${lib.escapeShellArg optionRoot}
      export IH_ADMIN_KEYS=${pkgs.writeText "admin-keys.json" (builtins.toJSON adminKeys)}
      export IH_DEFAULT_OWNER=${lib.escapeShellArg (toString defaultOwner)}
      export IH_HOST_TOPIC=${lib.escapeShellArg topic}
      ${builtins.readFile ../scripts/bootstrap-host.sh}
    '';
  };

  projectArgs = {
    inherit
      nixpkgs
      system
      self
      specialArgs
      ;
    installModules = [ hostModule ];
    diskName = "main";
    optionRoots = [ optionRoot ];
    assets = [
      {
        name = "agenix-key";
        target = agenixKeyPath;
        mode = "0400";
        required = haveKey;
        # The variable the devShell below exports.
        source = {
          env = "agenix__key";
          prompt = "paste";
        }
        // lib.optionalAttrs haveKey { ageFile = keyAgeName; };
      }
    ];
  }
  // (
    if isRepo then
      {
        flakeStyle = "repo";
        inherit repo;
        settingsFiles.${optionRoot} = settingsFile;
      }
    else
      {
        flakeStyle = "local";
        inherit upstream;
        bootstrap = bootstrapProgram;
      }
  )
  // installer;

  ih = mkProject projectArgs;
  installSystem = ih.nixosConfigurations.install;
  guided = projectArgs.guided or (!isRepo);

  identityWords = lib.concatStringsSep " " identityPaths;
in
assert lib.assertMsg (isRepo != (upstream != null))
  "lib.mkHost: set exactly one of repo (a host repository) or upstream (the project's own installer).";
{
  nixosModules.default = hostModule;

  # `install` is what every installer lays down; the same system under the
  # machine's name (and, for a host repo, as `default`, which the machine
  # tracks) is what it rebuilds, so the two cannot drift.
  nixosConfigurations =
    removeAttrs ih.nixosConfigurations (lib.optional (!guided) "installTemplate")
    // lib.optionalAttrs isRepo { default = installSystem; }
    // {
      ${installSystem.config.networking.hostName} = installSystem;
    };

  inherit (ih) packages apps checks;

  devShells.${system}.default = pkgs.mkShell {
    packages = [
      pkgs.age
      # agenix-compatible: `agenix -e secrets/<name>.age`, against secrets.nix.
      pkgs.ragenix
    ]
    ++ devShellPackages;
    shellHook = lib.optionalString haveKey ''
      agenix__key=""
      for id in ${identityWords}; do
        case "$id" in *.pub) continue ;; esac
        [ -n "$id" ] && [ -r "$id" ] || continue
        if agenix__key=$(${lib.getExe pkgs.age} -d -i "$id" ${keyAge} 2>/dev/null); then
          break
        fi
        agenix__key=""
      done
      export agenix__key
      if [ -n "$agenix__key" ]; then
        echo "host identity exported as \$agenix__key — installs will carry it to ${agenixKeyPath}"
      else
        echo "could not decrypt ${keyAgeName} (no matching key in: ${toString identityPaths})" >&2
        echo "installs will decrypt it with your SSH key, or stop and ask for it" >&2
      fi
    '';
  };

  # For inspection and tests.
  inherit hostRepoTemplate;
}
