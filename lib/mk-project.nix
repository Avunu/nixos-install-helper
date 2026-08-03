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
  # Top-level keys (within each root) to DROP from the derived schema — for
  # Nix-locked option groups that are serializable but must not be technician- or
  # UI-editable (e.g. router's `cockpit`). Matched against each root's top level.
  schemaExclude ? [ ],
  # Path to the technician-authored settings value file (when the schema is
  # non-empty). Per-root FLAT settings files: each technician-facing namespace
  # round-trips through its own flat JSON (contents = that root's options),
  # applied as `<root> = mkDefault (fromJSON file)` — exactly nixos-router's
  # router-settings.json pattern. Defaults to self + "/installer/<root>.json";
  # override per root, e.g. { router = ./local/router-settings.json; }.
  settingsFiles ? { },
  specialArgs ? { },
  # ISO lightening passthroughs.
  dropZfs ? false,
  # Extra NixOS modules merged into the installer ISO itself (e.g. a hardware
  # kernel the installer must boot with).
  isoModules ? [ ],
  # Offer the generic guided ISO? Set false for appliances whose config can't be
  # picked offline on a generic image (e.g. a router's full topology), so the
  # template need not build from bare option defaults.
  guided ? true,
}:
let
  pkgs = nixpkgs.legacyPackages.${system};

  mkInstallSystem =
    extraModules:
    nixpkgs.lib.nixosSystem {
      inherit system specialArgs;
      modules =
        installModules
        ++ extraModules
        ++ [
          frameworkSelf.nixosModules.installHelper
          {
            installHelper = {
              inherit flakeStyle upstream deployedConfiguration;
              enable = lifecycle;
            };
          }
        ];
    };

  # Template (no settings) — drives root auto-detection and the guided-ISO
  # closure. installSystem (with the per-root settings files) is built below,
  # once resolvedRoots is known.
  templateSystem = mkInstallSystem [ ];

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

  # ── Per-root FLAT settings files (the nixos-router pattern, generalized) ────
  settingsFileFor = root: settingsFiles.${root} or (self + "/installer/${root}.json");
  # Path of a root's settings file RELATIVE to the flake source (e.g.
  # "local/router-settings.json"), used both for the workstation configure step
  # and for guided-ISO seeding into the installed /etc/nixos.
  relSettingsPath =
    root:
    let
      prefix = toString (self.outPath or self);
    in
    lib.removePrefix "${prefix}/" (toString (settingsFileFor root));

  # Apply each present per-root flat file as `<root> = mkDefault (fromJSON file)`.
  fileSettingsModule =
    { lib, ... }:
    {
      config = lib.mkMerge (
        map (
          root:
          let
            f = settingsFileFor root;
          in
          lib.optionalAttrs (builtins.pathExists f) {
            ${root} = lib.mkDefault (builtins.fromJSON (builtins.readFile f));
          }
        ) resolvedRoots
      );
    };

  installSystem = mkInstallSystem [ fileSettingsModule ];

  rawSchema = import ./options-to-schema.nix {
    inherit lib;
    options = projOptions;
    optionRoots = resolvedRoots;
  };
  # Drop Nix-locked keys (schemaExclude) from each root's top level.
  dropExcluded = s: s // { properties = removeAttrs (s.properties or { }) schemaExclude; };
  settingsSchema = rawSchema // {
    properties = lib.mapAttrs (_: dropExcluded) (rawSchema.properties or { });
  };
  schemaHasProps = lib.any (s: (s.properties or { }) != { }) (
    lib.attrValues (settingsSchema.properties or { })
  );

  # Per-root FLAT schemas: the subtree under each root as a standalone Draft-07
  # (properties = that root's options). This is what Cockpit-style UIs and the
  # gum walker consume — flat, matching the per-root settings file.
  settingsSchemas = lib.genAttrs resolvedRoots (
    root:
    dropExcluded (
      settingsSchema.properties.${root} or {
        type = "object";
        additionalProperties = false;
        properties = { };
      }
    )
    // {
      "$schema" = "http://json-schema.org/draft-07/schema#";
    }
  );
  settingsSchemaFiles = lib.genAttrs resolvedRoots (
    root: pkgs.writeText "settings.schema-${root}.json" (builtins.toJSON settingsSchemas.${root})
  );

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
        # Relative path of the primary root's FLAT settings file within the flake;
        # guided-install writes the chosen identity here (seeded into /etc/nixos).
        primarySettingsPath =
          if resolvedRoots == [ ] then null else relSettingsPath (builtins.head resolvedRoots);
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
          # Per-root FLAT settings: [{ root, file (relative to project), schema }].
          export IH_ROOTS=${
            pkgs.writeText "roots.json" (
              builtins.toJSON (
                map (root: {
                  inherit root;
                  file = relSettingsPath root;
                  schema = "${settingsSchemaFiles.${root}}";
                }) resolvedRoots
              )
            )
          }
          export IH_ASSETS=${
            pkgs.writeText "assets.json" (
              builtins.toJSON (map (a: removeAttrs a [ "resolvedSource" ]) resolvedAssets)
            )
          }
          export IH_FLAKE_STYLE=${flakeStyle}
          export IH_DISK_NAME=${diskName}
          export IH_HAS_SETTINGS=${if schemaHasProps then "1" else "0"}
          export IH_GUIDED=${if guided then "1" else "0"}
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
  inherit settingsSchema settingsSchemas resolvedRoots;

  nixosConfigurations = {
    install = installSystem;
    installTemplate = templateSystem;
  };

  packages.${system} = {
    settingsSchema = schemaJson;
  }
  # Per-root FLAT schema files: packages."settingsSchema-<root>" (e.g. for the
  # router Cockpit build to consume as its single source).
  // lib.mapAttrs' (root: f: lib.nameValuePair "settingsSchema-${root}" f) settingsSchemaFiles
  // {
    installerIso = mkIso {
      target = installSystem;
      mode = "unattended";
      embed = embeddedAssets;
      device = resolvedDiskDevice;
    };
  }
  // lib.optionalAttrs guided {
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
