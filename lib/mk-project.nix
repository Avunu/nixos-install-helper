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
  # disko --disk mapping. device "" → chosen interactively on a guided ISO.
  diskName ? "main",
  diskDevice ? "",
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
}:
let
  pkgs = nixpkgs.legacyPackages.${system};

  settings =
    if settingsFile != null && builtins.pathExists settingsFile then
      builtins.fromJSON (builtins.readFile settingsFile)
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
    }:
    (import ./mk-installer-iso.nix {
      inherit
        lib
        nixpkgs
        disko
        system
        target
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
      inherit dropZfs;
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
          exec ${frameworkSelf}/scripts/${name}.sh "$@"
        '';
      }
    );
  };
in
{
  inherit settingsSchema resolvedRoots;

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
      device = diskDevice;
    };
    guidedIso = mkIso {
      target = templateSystem;
      mode = "guided";
      embed = [ ];
      device = "";
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
    ];
    deploy = mkApp "deploy" [
      pkgs.gum
      pkgs.jq
      nixosAnywhere.packages.${system}.default
    ];
  };
}
