# mk-project.nix
# ─────────────────────────────────────────────────────────────────────────────
# The single entrypoint a consuming flake calls. From its install module set it
# derives the per-install JSON Schema, builds the install systems, and returns
# the packages / apps / nixosConfigurations the project re-exports.
#
# Framework context (frameworkSelf, disko, nixosAnywhere) is partially applied in
# the framework flake; the consuming project passes only the `args` below.
{
  lib,
  frameworkSelf,
  disko,
  nixosAnywhere,
}:
args@{
  nixpkgs,
  system,
  # The consuming flake's `self` (source shipped to the ISO, walked for the
  # offline closure, and used to auto-detect technician-facing option roots).
  self,
  # Modules laid down by the installer (e.g. cocalico's [LCServerCore internalDrive]).
  installModules,
  # Lifecycle: "local" seeds /etc/nixos referencing `upstream`; "remote" boots
  # minimal then autoUpgrades to `deployedConfiguration`.
  flakeStyle ? "local",
  upstream ? null, # github:Owner/repo  (local style)
  deployedConfiguration ? null, # github:Owner/repo#attr (remote style)
  # Schema root override; null → auto-detect namespaces declared by the project.
  optionRoots ? null,
  # disko --disk mapping. diskDevice "" → auto-read from the install system's
  # config.disko.devices.disk.<diskName>.device (or chosen interactively on a
  # guided ISO if the module leaves it unset).
  diskName ? "main",
  diskDevice ? "",
  # Import the framework lifecycle module (first-boot reconcile / autoUpgrade).
  # Set false when the project already manages its own post-install upgrade
  # (e.g. cocalico's LCServerCore initial-upgrade service).
  lifecycle ? true,
  # Secret/key assets: [{ name; target; mode?; required?; source = {env|file|prompt}; }]
  assets ? [ ],
  # gum widget hints keyed by dotted settings path: "diskDevice" = "disk-device".
  hints ? { },
  # Settings that change the closure → locked to template defaults on guided ISO.
  closureAffecting ? [ ],
  # Path to the technician-authored settings value file (when the schema is
  # non-empty). Absent → install systems use option defaults.
  settingsFile ? (self + "/installer/settings.json"),
  specialArgs ? { },
  # ISO lightening passthroughs.
  dropZfs ? false,
  # Extra NixOS modules merged into the installer ISO itself (e.g. a hardware
  # kernel the installer must boot with).
  isoModules ? [ ],
}:
let
  pkgs = nixpkgs.legacyPackages.${system};

  # Settings source. `IH_SETTINGS_FILE` (an absolute path, set by the wizard when
  # building --impure) wins over the tracked `settingsFile` — a flake only copies
  # git-TRACKED files into `self`, so an untracked working-tree settings.json is
  # invisible to a pure eval. Under a pure eval getEnv returns "" and behaviour is
  # unchanged (read the tracked path, or {} if absent).
  settingsFileResolved =
    let
      envFile = builtins.getEnv "IH_SETTINGS_FILE";
    in
    if envFile != "" then envFile else settingsFile;

  settings =
    if settingsFileResolved != null && builtins.pathExists settingsFileResolved then
      builtins.fromJSON (builtins.readFile settingsFileResolved)
    else
      { };

  # Apply a settings attrset (keyed by option root) as module defaults, mirroring
  # nixos-router's `{ router = mkDefault settings; }`.
  settingsModule =
    s:
    { lib, ... }:
    {
      config = builtins.mapAttrs (_: lib.mkDefault) s;
    };

  mkInstallSystem =
    s:
    nixpkgs.lib.nixosSystem {
      inherit system specialArgs;
      modules = installModules ++ [
        (settingsModule s)
        frameworkSelf.nixosModules.installHelper
        {
          installHelper = {
            inherit flakeStyle upstream deployedConfiguration;
            enable = lifecycle;
          };
        }
      ];
    };

  # Per-host (unattended) and template (guided) install systems.
  installSystem = mkInstallSystem settings;
  templateSystem = mkInstallSystem { };

  # ── Auto-detect technician-facing roots ────────────────────────────────────
  # Candidate roots = top-level option namespaces the install modules ADD beyond
  # base NixOS. Then keep only those whose subtree declares an option under the
  # project's own source (excludes disko.*/age.* pulled from inputs).
  baseOptionNames = builtins.attrNames (
    (nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [ { nixpkgs.hostPlatform = system; } ];
    }).options
  );
  projOptions = templateSystem.options;
  sourcePrefix = toString self.outPath or (toString self);
  isOption = x: builtins.isAttrs x && (x._type or null) == "option";
  declaredHere =
    depth: node:
    if depth < 0 then
      false
    else if isOption node then
      lib.any (d: lib.hasPrefix sourcePrefix (toString d)) (node.declarations or [ ])
    else if builtins.isAttrs node then
      lib.any (declaredHere (depth - 1)) (
        builtins.attrValues (lib.filterAttrs (n: _: !lib.hasPrefix "_" n) node)
      )
    else
      false;
  detectedRoots = lib.filter (
    n: !(builtins.elem n baseOptionNames) && declaredHere 4 projOptions.${n}
  ) (builtins.attrNames projOptions);
  resolvedRoots = if optionRoots != null then optionRoots else detectedRoots;

  settingsSchema = import ./options-to-schema.nix {
    inherit lib;
    options = projOptions;
    optionRoots = resolvedRoots;
  };
  schemaHasProps = (settingsSchema.properties or { }) != { };

  # ── Resolve assets embeddable at build time (env/file sources) ─────────────
  resolveAsset =
    a:
    let
      src = a.source or { };
      envVal = if src ? env then builtins.getEnv src.env else "";
      file =
        if src ? file && src.file != null then
          src.file
        else if src ? env && envVal != "" then
          builtins.toFile a.name envVal
        else
          null;
    in
    a // { resolvedSource = file; };
  resolvedAssets = map resolveAsset assets;
  embeddedAssets = map (a: {
    inherit (a) name;
    source = a.resolvedSource;
    mode = a.mode or "0400";
  }) (lib.filter (a: a.resolvedSource != null) resolvedAssets);

  schemaJson = pkgs.writeText "settings.schema.json" (builtins.toJSON settingsSchema);

  # The EXACT settings that produced the baked per-host `installSystem`. Shipped
  # onto the unattended ISO so disko-install's (impure) re-evaluation reads them
  # back via IH_SETTINGS_FILE and reproduces the baked toplevel — instead of
  # seeing an empty settings.json (untracked files aren't in the shipped flake)
  # and rebuilding a divergent system online. Kept in sync with `settings`.
  settingsValueJson = pkgs.writeText "installer-settings.json" (builtins.toJSON settings);

  # ── Synthesized local flake (flakeStyle == "local") ─────────────────────────
  # For local style, /etc/nixos gets a MINIMAL flake that imports the module(s)
  # from the upstream project (github) and reads the technician's settings.json —
  # NOT a copy of the whole project source (which is what the boot scripts used
  # to seed). The install scripts drop this file + settings.json onto the target.
  #
  # Module names are derived from the option roots the project also exports as
  # `nixosModules.<root>` (devWorkstation → nixosModules.devWorkstation). This
  # ignores inline installModules entries (e.g. router's `{ router.cockpit... }`).
  localModuleNames =
    let
      fromRoots = lib.filter (n: self.nixosModules ? ${n}) resolvedRoots;
    in
    if fromRoots != [ ] then fromRoots else [ "default" ];

  # Built lazily: null unless local style with an upstream, so it never evaluates
  # for remote projects (cocalico) or when there is nothing to reference.
  localFlakeNix =
    if flakeStyle == "local" && upstream != null then
      pkgs.writeText "flake.nix" ''
        {
          inputs = {
            nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
            project.url = "${upstream}";
            project.inputs.nixpkgs.follows = "nixpkgs";
          };
          outputs =
            { self, nixpkgs, project }:
            let
              settings = builtins.fromJSON (builtins.readFile ./settings.json);
              host = nixpkgs.lib.nixosSystem {
                system = "${system}";
                modules = [
        ${lib.concatMapStringsSep "\n" (m: "          project.nixosModules.${m}") localModuleNames}
                  { config = builtins.mapAttrs (_: nixpkgs.lib.mkDefault) settings; }
                ];
              };
            in
            {
              # Keyed by the EVALUATED hostname so a bare
              # `nixos-rebuild switch --flake /etc/nixos` matches the running host;
              # `default` is a stable alias the first-boot reconcile targets before
              # a guided-chosen hostname has taken effect.
              nixosConfigurations = {
                "''${host.config.networking.hostName}" = host;
                default = host;
              };
            };
        }
      ''
    else
      null;

  # The install disk device: explicit arg wins; otherwise read it from the
  # install system's disko config (so a module-fixed device — cocalico's PCI
  # path — needs no duplication). Empty is fine for the guided ISO.
  resolvedDiskDevice =
    if diskDevice != "" then
      diskDevice
    else
      (installSystem.config.disko.devices.disk.${diskName}.device or "");

  # Asset targets the boot scripts copy via --extra-files (no secret material).
  assetTargets = map (a: {
    inherit (a) name target;
    mode = a.mode or "0400";
    embedded = a.resolvedSource != null;
  }) resolvedAssets;

  mkIso =
    {
      target,
      mode,
      embed,
      device,
      settingsJson ? null,
      localFlakeNix ? null,
    }:
    (import ./mk-installer-iso.nix {
      inherit
        lib
        nixpkgs
        disko
        system
        target
        settingsJson
        localFlakeNix
        ;
      flakeSelf = self;
      manifest = {
        hostAttr = if mode == "guided" then "installTemplate" else "install";
        inherit
          mode
          flakeStyle
          upstream
          deployedConfiguration
          ;
        diskName = diskName;
        diskDevice = device;
        assets = assetTargets;
        primaryRoot = if resolvedRoots == [ ] then null else builtins.head resolvedRoots;
      };
      installScript =
        if mode == "guided" then
          "${frameworkSelf}/scripts/guided-install.sh"
        else
          "${frameworkSelf}/scripts/unattended-install.sh";
      embeddedAssets = embed;
      inherit dropZfs isoModules;
    }).config.system.build.isoImage;

  # ── Apps (gum-driven; run from the project working tree) ───────────────────
  mkApp = name: runtimeInputs: {
    type = "app";
    program = lib.getExe (
      pkgs.writeShellApplication {
        inherit name runtimeInputs;
        text = ''
          export IH_SCHEMA=${schemaJson}
          export IH_HINTS=${pkgs.writeText "hints.json" (builtins.toJSON hints)}
          export IH_ASSETS=${
            pkgs.writeText "assets.json" (
              builtins.toJSON (map (a: removeAttrs a [ "resolvedSource" ]) resolvedAssets)
            )
          }
          export IH_FLAKE_STYLE=${flakeStyle}
          export IH_DISK_NAME=${diskName}
          export IH_HAS_SETTINGS=${if schemaHasProps then "1" else "0"}
          # Invoke through bash explicitly: scripts copied into the store from git
          # keep mode 0644 (non-executable), so exec'ing them directly fails with
          # "Permission denied". bash <path> needs no executable bit.
          exec ${pkgs.bash}/bin/bash ${frameworkSelf}/scripts/${name}.sh "$@"
        '';
      }
    );
  };
in
{
  # `localFlakeNix` (null for remote) is exposed for inspection/tests — it is the
  # synthesized /etc/nixos flake the local-style installer seeds onto the target.
  inherit settingsSchema resolvedRoots localFlakeNix;

  nixosConfigurations = {
    install = installSystem;
    installTemplate = templateSystem;
  };

  packages.${system} = {
    settingsSchema = schemaJson;
    installerIso = mkIso {
      target = installSystem;
      mode = "unattended";
      embed = embeddedAssets;
      device = resolvedDiskDevice;
      settingsJson = settingsValueJson;
      inherit localFlakeNix;
    };
    guidedIso = mkIso {
      target = templateSystem;
      mode = "guided";
      embed = [ ];
      device = "";
      inherit localFlakeNix;
    };
  };

  apps.${system} = {
    # The single entrypoint: `nix run .#` / `nix run github:Owner/repo`.
    default = mkApp "wizard" [
      pkgs.gum
      pkgs.jq
      pkgs.nix
      pkgs.util-linux
      pkgs.iproute2
      nixosAnywhere.packages.${system}.default
    ];
    configure = mkApp "configure" [
      pkgs.gum
      pkgs.jq
      pkgs.util-linux
      pkgs.iproute2
    ];
    install = mkApp "install" [
      pkgs.gum
      pkgs.jq
      pkgs.nix
      pkgs.util-linux # lsblk for the USB-flash picker
    ];
    deploy = mkApp "deploy" [
      pkgs.gum
      pkgs.jq
      nixosAnywhere.packages.${system}.default
    ];
  };
}
