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
  # Technician-authored FLAT per-root settings files, keyed by option root:
  #   settingsFiles.router = ./local/router-settings.json
  # Each file holds that root's option VALUES at top level (no `<root>` wrapper) and
  # is applied as `{ <root> = mkDefault <flat> }`. Unset roots fall back to
  # `self + "/installer/<root>-settings.json"`. Absent files → option defaults.
  settingsFiles ? { },
  # Dotted sub-paths, relative to each option root, to DROP from the derived schema
  # (e.g. "cockpit" → router.cockpit.* stays Nix-locked, never in the JSON/UI).
  schemaExclude ? [ ],
  # When false, no guided (generic template) ISO is built and the wizard/install
  # menus hide the guided path. The per-host unattended ISO + network deploy remain.
  guided ? true,
  specialArgs ? { },
  # ISO lightening passthroughs.
  dropZfs ? false,
  # Extra NixOS modules merged into the installer ISO itself (e.g. a hardware
  # kernel the installer must boot with).
  isoModules ? [ ],
}:
let
  pkgs = nixpkgs.legacyPackages.${system};

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

  # Template (settings-free) system — evaluated FIRST so roots are known before we
  # read the per-root settings files.
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

  # ── Per-root settings (FLAT files) ─────────────────────────────────────────
  # Each root's file holds that root's option VALUES at top level. `IH_SETTINGS_DIR`
  # (a directory of `<root>-settings.json`, set by the wizard when building --impure)
  # wins over the tracked path — a flake only copies git-TRACKED files into `self`,
  # so an untracked working-tree file is invisible to a pure eval. Under a pure eval
  # getEnv returns "" and behaviour is unchanged (read the tracked path, or {}).
  settingsForRoot =
    root:
    let
      dir = builtins.getEnv "IH_SETTINGS_DIR";
      f =
        if dir != "" then
          "${dir}/${root}-settings.json"
        else
          settingsFiles.${root} or (self + "/installer/${root}-settings.json");
    in
    if f != null && builtins.pathExists f then builtins.fromJSON (builtins.readFile f) else { };

  # Nested { <root> = <flat values>; } used to build the baked install system.
  settings = lib.genAttrs resolvedRoots settingsForRoot;

  # Per-host (unattended) install system, with the technician's settings baked in.
  installSystem = mkInstallSystem settings;

  fullSchema = import ./options-to-schema.nix {
    inherit lib;
    options = projOptions;
    optionRoots = resolvedRoots;
  };

  # ── Per-root FLAT schema (+ schemaExclude) ─────────────────────────────────
  # Promote a root's sub-option tree to the document root and drop excluded dotted
  # sub-paths (relative to the root). Matches nixos-router's committed
  # <root>-settings.schema.json (no <root> wrapper, no cockpit).
  dropSchemaPath =
    schema: parts:
    if parts == [ ] then
      schema
    else
      let
        head = builtins.head parts;
        rest = builtins.tail parts;
        props = schema.properties or { };
      in
      if !(props ? ${head}) then
        schema
      else if rest == [ ] then
        schema // { properties = builtins.removeAttrs props [ head ]; }
      else
        schema
        // {
          properties = props // {
            ${head} = dropSchemaPath props.${head} rest;
          };
        };

  perRootSchema =
    root:
    let
      base =
        fullSchema.properties.${root} or {
          type = "object";
          additionalProperties = false;
          properties = { };
        };
      pruned = lib.foldl' (s: p: dropSchemaPath s (lib.splitString "." p)) base schemaExclude;
    in
    pruned // { "$schema" = "http://json-schema.org/draft-07/schema#"; };

  # Nested schema rebuilt from the pruned per-root schemas (back-compat export).
  settingsSchema = {
    "$schema" = "http://json-schema.org/draft-07/schema#";
    type = "object";
    additionalProperties = false;
    properties = lib.genAttrs resolvedRoots (r: builtins.removeAttrs (perRootSchema r) [ "$schema" ]);
  };
  schemaHasProps = (settingsSchema.properties or { }) != { } && resolvedRoots != [ ];

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

  # The EXACT per-root settings that produced the baked `installSystem`, as a DIR of
  # flat `<root>-settings.json` files. Shipped onto the unattended ISO so
  # disko-install's (impure) re-evaluation reads them back via IH_SETTINGS_DIR and
  # reproduces the baked toplevel — instead of seeing empty settings (untracked files
  # aren't in the shipped flake) and rebuilding a divergent system online. It is also
  # what the boot scripts seed into /etc/nixos. Kept in sync with `settings`.
  settingsDir = pkgs.runCommand "installer-settings" { } ''
    mkdir -p "$out"
    ${lib.concatMapStringsSep "\n" (
      r:
      ''cp ${pkgs.writeText "${r}-settings.json" (builtins.toJSON (settingsForRoot r))} "$out/${r}-settings.json"''
    ) resolvedRoots}
  '';

  # ── Synthesized local flake (flakeStyle == "local") ─────────────────────────
  # For local style, /etc/nixos gets a MINIMAL flake that imports the module(s) from
  # the upstream project (github) and reads FLAT per-root <root>-settings.json files —
  # NOT a copy of the whole project source. Each root's JSON is applied SCOPED under
  # `{ <root> = mkDefault <flat> }`, so a Cockpit user editing the file can only touch
  # that root's typed options (the security boundary), never arbitrary system config.
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
              load =
                root:
                builtins.mapAttrs (_: nixpkgs.lib.mkDefault) (
                  builtins.fromJSON (builtins.readFile (./. + "/''${root}-settings.json"))
                );
              host = nixpkgs.lib.nixosSystem {
                system = "${system}";
                modules = [
        ${lib.concatMapStringsSep "\n" (m: "          project.nixosModules.${m}") localModuleNames}
        ${lib.concatMapStringsSep "\n" (r: "          { ${r} = load \"${r}\"; }") resolvedRoots}
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
      settingsDir ? null,
      localFlakeNix ? null,
    }:
    (import ./mk-installer-iso.nix {
      inherit
        lib
        nixpkgs
        disko
        system
        target
        settingsDir
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
        roots = resolvedRoots;
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
  # `localFlakeNix` (null for remote) is exposed for inspection/tests — it is the
  # synthesized /etc/nixos flake the local-style installer seeds onto the target.
  inherit settingsSchema resolvedRoots localFlakeNix;

  nixosConfigurations = {
    install = installSystem;
    installTemplate = templateSystem;
  };

  packages.${system} = {
    # Nested union schema (back-compat).
    settingsSchema = schemaJson;
    installerIso = mkIso {
      target = installSystem;
      mode = "unattended";
      embed = embeddedAssets;
      device = resolvedDiskDevice;
      inherit settingsDir localFlakeNix;
    };
  }
  # Per-root FLAT schema packages: `settingsSchema-<root>` (e.g. what
  # nixos-router's Cockpit build diffs its committed router-settings.schema.json
  # against).
  // lib.listToAttrs (
    map (r: {
      name = "settingsSchema-${r}";
      value = pkgs.writeText "${r}-settings.schema.json" (builtins.toJSON (perRootSchema r));
    }) resolvedRoots
  )
  # Guided (generic template) ISO — omitted entirely when `guided = false`.
  // lib.optionalAttrs guided {
    guidedIso = mkIso {
      target = templateSystem;
      mode = "guided";
      embed = [ ];
      device = "";
      inherit settingsDir localFlakeNix;
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
