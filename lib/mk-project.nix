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
  # mksquashfs compression for the ISO store. The default trades ~18% image size
  # for a ~23x faster (and, since mksquashfs prints nothing to a non-tty,
  # ~23x shorter silent) build — see mk-installer-iso.nix. Raise to
  # "zstd -Xcompression-level 19" for a release image someone downloads.
  squashfsCompression ? "zstd -Xcompression-level 6",
  # The options a GUIDED install asks about on the target box, named by the project
  # as dotted paths under its primary option root ("hostName", "user.name", …).
  #
  # Named by the PROJECT, deliberately. The framework has no business knowing that
  # an option called `hostName` is a hostname: guessing from well-known key names
  # would silently do nothing for a project that spells it `machineName`, and would
  # be impossible to discover from the outside when it did. The project already
  # declares these options; it is the only party that knows which of them are
  # per-machine identity rather than configuration, so it says so here.
  #
  # Default empty: a guided ISO with no list asks for the disk and nothing else,
  # which is the honest behaviour for an image the framework knows nothing about.
  # Only string-typed options are eligible — the answers are seeded as JSON for the
  # first-boot reconcile, and a free-text prompt is the only widget the boot script
  # has. Keep the list to things that do not move the closure.
  guidedPrompts ? [ ],
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

  # ── Name of the upstream input in the synthesized flake ────────────────────
  # The REPO name rather than a generic `project`, so the seeded flake reads like
  # one a human wrote (`nixos-nano-desktop.nixosModules.nanoDesktop`) and
  # `nix flake metadata /etc/nixos` names what the machine actually tracks.
  #   github:Owner/repo[/ref]           → repo   (shorthand: repo is 2nd)
  #   git+https://host/a/b/repo.git     → repo   (URL/path: repo is last)
  upstreamRepoName =
    let
      # Drop #fragment then ?query (…?ref=main), then the scheme. `upstream` is
      # null for remote-style projects — that path falls through to "project".
      ref = if upstream == null then "" else upstream;
      bare = builtins.head (lib.splitString "?" (builtins.head (lib.splitString "#" ref)));
      scheme = builtins.head (lib.splitString ":" bare);
      rest = lib.removePrefix "${scheme}:" bare;
      parts = lib.filter (p: p != "") (lib.splitString "/" rest);
      shorthand = builtins.elem scheme [
        "github"
        "gitlab"
        "sourcehut"
      ];
      raw =
        if parts == [ ] then
          ""
        else if shorthand && builtins.length parts >= 2 then
          builtins.elemAt parts 1
        else
          lib.last parts;
    in
    lib.removeSuffix ".git" raw;

  # A Nix identifier is [A-Za-z_][A-Za-z0-9_'-]*; anything else (a leading digit,
  # the dot in "dotfiles.nix") would make the generated flake unparseable, and
  # `self`/`nixpkgs` are already taken in its outputs signature. Fall back to the
  # old generic name rather than emit something broken.
  upstreamInputName =
    let
      cleaned = lib.stringAsChars (
        c: if builtins.match "[A-Za-z0-9_'-]" c != null then c else "-"
      ) upstreamRepoName;
      valid = builtins.match "[A-Za-z_].*" cleaned != null;
    in
    if
      !valid
      || builtins.elem cleaned [
        "self"
        "nixpkgs"
      ]
    then
      "project"
    else
      cleaned;

  # Built lazily: null unless local style with an upstream, so it never evaluates
  # for remote projects (cocalico) or when there is nothing to reference.
  localFlakeNix =
    if flakeStyle == "local" && upstream != null then
      pkgs.writeText "flake.nix" ''
        {
          inputs = {
            nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
            ${upstreamInputName}.url = "${upstream}";
            ${upstreamInputName}.inputs.nixpkgs.follows = "nixpkgs";
          };
          outputs =
            {
              self,
              nixpkgs,
              ${upstreamInputName},
              ...
            }@inputs:
            let
              load =
                root:
                builtins.mapAttrs (_: nixpkgs.lib.mkDefault) (
                  builtins.fromJSON (builtins.readFile (./. + "/''${root}-settings.json"))
                );
              host = nixpkgs.lib.nixosSystem {
                system = "${system}";
                # ./local.nix reaches every input above as `inputs`, so pulling a
                # package out of an added flake needs no edit to this file.
                specialArgs = { inherit inputs; };
                modules = [
        ${lib.concatMapStringsSep "\n" (
          m: "          ${upstreamInputName}.nixosModules.${m}"
        ) localModuleNames}
        ${lib.concatMapStringsSep "\n" (r: "          { ${r} = load \"${r}\"; }") resolvedRoots}
                ]
                # Machine-local configuration (extra packages, per-host tweaks).
                # Optional, so a deleted local.nix can never break a rebuild.
                ++ nixpkgs.lib.optional (builtins.pathExists ./local.nix) ./local.nix;
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

  # ── Placeholder machine-local module ───────────────────────────────────────
  # Seeded next to the synthesized flake as /etc/nixos/local.nix. The JSON
  # settings can only carry that root's serializable options — a package is a Nix
  # value, not a string, so "install one more program" (by far the most common
  # customization) has nowhere to go in JSON. This file is that place: ordinary
  # NixOS config merged on top, owned by the machine, never rewritten by an
  # upgrade. Shipped empty-but-annotated so the shape is obvious without docs.
  localModuleNix =
    let
      settingsNote = lib.optionalString (resolvedRoots != [ ]) ''

        # and the settings the installer asked about live in
        #   ${lib.concatMapStringsSep ", " (r: "${r}-settings.json") resolvedRoots}
        # which is where anything listed there is changed.'';
    in
    if flakeStyle == "local" && upstream != null then
      pkgs.writeText "local.nix" ''
        # /etc/nixos/local.nix — configuration for THIS machine.
        #
        # The rest of /etc/nixos tracks upstream — flake.nix pulls the module(s)
        # from
        #   ${upstream}${settingsNote}
        # Apply a change from any of these files with
        # `nixos-rebuild switch --flake /etc/nixos`.
        #
        # This file is everything else — plain NixOS configuration, merged on
        # top, and yours: an upgrade never rewrites it.
        #
        # Extra software is the usual reason to be here. Package names cannot
        # live in the JSON settings (a package is a Nix value, not a string), so
        # they go below. Find names at https://search.nixos.org/packages.
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

          # Anything NixOS can configure belongs here too, for example:
          # services.tailscale.enable = true;
          # programs.steam.enable = true;
          #
          # A package from another flake: add the input to flake.nix, then reach
          # it here through `inputs`, e.g.
          # environment.systemPackages = [
          #   inputs.some-flake.packages.''${pkgs.stdenv.hostPlatform.system}.default
          # ];
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

  # The installer-ISO nixosSystem. Returned as a SYSTEM rather than an isoImage
  # so the offline-install VM test can extend it (with the test driver's
  # backdoor) and still be testing this exact image — see mk-offline-install-test.nix.
  mkIsoSystem =
    {
      target,
      mode,
      embed,
      device,
      settingsDir ? null,
      localFlakeNix ? null,
      localModuleNix ? null,
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
        localModuleNix
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
        primaryRoot = primaryRoot;
        prompts = guidedQuestions;
      };
      installScript =
        if mode == "guided" then
          "${frameworkSelf}/scripts/guided-install.sh"
        else
          "${frameworkSelf}/scripts/unattended-install.sh";
      embeddedAssets = embed;
      inherit dropZfs isoModules squashfsCompression;
    });

  primaryRoot = if resolvedRoots == [ ] then null else builtins.head resolvedRoots;

  # ── The questions a guided ISO asks on the box ─────────────────────────────
  # A guided ISO bakes the settings-free template and the technician answers for the
  # machine in front of them. WHICH questions is `guidedPrompts`, named by the
  # project; the prompt text and default are read off the derived schema, so the
  # option's own declaration stays the single source of truth and the boot script
  # hardcodes nothing.
  #
  # The description's FIRST LINE becomes the gum header — an option's description
  # can run to paragraphs (nano-desktop's do) and gum would render the lot.
  #
  # A path that names no option, or names one the schema dropped (non-serializable,
  # internal, or pruned by schemaExclude), is an error rather than a silent no-show:
  # the failure mode this replaced was a guided ISO that quietly stopped asking.
  guidedQuestions =
    let
      props = if primaryRoot == null then { } else (perRootSchema primaryRoot).properties or { };
      firstLine = s: builtins.head (lib.splitString "\n" s);
      lookup =
        path: node:
        let
          head = builtins.head path;
          rest = builtins.tail path;
          child = (node.properties or { }).${head} or null;
        in
        if child == null then
          null
        else if rest == [ ] then
          child
        else
          lookup rest child;
    in
    map (
      path:
      let
        p = lookup (lib.splitString "." path) { properties = props; };
      in
      if p == null then
        throw ''
          guidedPrompts names "${path}", which ${primaryRoot} does not declare as a
          settable option (or which schemaExclude removed). The guided ISO derives
          its prompt text and default from the schema, so it cannot ask for it.
        ''
      else if (p.type or null) != "string" then
        throw ''
          guidedPrompts names "${path}", which is not a string option. The guided
          installer only has a free-text prompt, and its answer is seeded as JSON
          for the first-boot reconcile — so enums, numbers and lists have to stay
          baked into the template.
        ''
      else
        {
          key = path;
          prompt = if (p.description or "") != "" then firstLine p.description else "${primaryRoot}.${path}";
          default = p.default or "";
        }
    ) guidedPrompts;

  # ── Guided ISO precondition: every option must have a default ──────────────
  # The guided ISO bakes `templateSystem` — the install modules evaluated with NO
  # settings at all, because the ISO is generic and identity is chosen on the box.
  # So an option the project declares WITHOUT a default has nothing to fall back
  # to, and evaluating the template's toplevel dies with the module system's
  # "The option `foo.bar' was accessed but has no value defined", buried under a
  # trace that names make-iso9660-image.nix and `environment.etc.install-closure`
  # — three layers away from the actual cause.
  #
  # The derived schema already knows exactly which options those are: treeToSchema
  # emits a `required` list for every option leaf it saw no `default` on. Collect
  # them as dotted paths and fail the guided ISO with that list instead.
  #
  # (Only options the schema can see are covered — a non-serializable option, e.g.
  # `types.package`, is dropped from the schema and so cannot be reported here.
  # Those still produce the raw module-system error.)
  requiredPaths =
    prefix: schema:
    (map (k: "${prefix}${k}") (schema.required or [ ]))
    ++ lib.concatLists (
      lib.mapAttrsToList (k: v: if v ? properties then requiredPaths "${prefix}${k}." v else [ ]) (
        schema.properties or { }
      )
    );
  guidedMissingDefaults = lib.concatMap (r: requiredPaths "${r}." (perRootSchema r)) resolvedRoots;

  # ── The two installer ISOs, as systems ─────────────────────────────────────
  unattendedIsoSystem = mkIsoSystem {
    target = installSystem;
    mode = "unattended";
    embed = embeddedAssets;
    device = resolvedDiskDevice;
    inherit settingsDir localFlakeNix localModuleNix;
  };

  guidedIsoSystem = mkIsoSystem {
    target = templateSystem;
    mode = "guided";
    embed = [ ];
    device = "";
    inherit settingsDir localFlakeNix localModuleNix;
  };

  # ── Offline-install VM checks ──────────────────────────────────────────────
  # `nix build .#checks.<system>.offline-install-guided` boots the ISO itself in
  # a network-less VM and installs to a blank disk. What it proves is the one
  # thing the flake cannot: that the baked closure covers the system
  # disko-install actually derives ON THE BOX, where the firmware mode and the
  # target device are inputs the image was built without. See
  # mk-offline-install-test.nix.
  mkOfflineTest =
    a:
    import ./mk-offline-install-test.nix (
      {
        inherit lib nixpkgs system;
      }
      // a
    );

  # The guided ISO asks; the test answers. Values are the schema defaults where
  # the project gave one, so the test seeds what a technician pressing Enter
  # would. They land in a JSON file for the first-boot reconcile and never move
  # the closure, so any string would do — these just read like a real install.
  guidedAnswers = lib.listToAttrs (
    map (q: {
      name = q.key;
      value = if q.default != "" then q.default else "ih-test";
    }) guidedQuestions
  );

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
  # `localFlakeNix` / `localModuleNix` (both null for remote) are exposed for
  # inspection/tests — they are the synthesized /etc/nixos flake and its
  # placeholder machine-local module, seeded onto the target by a local install.
  # `upstreamInputName` is what that flake calls the upstream input.
  inherit
    settingsSchema
    resolvedRoots
    localFlakeNix
    localModuleNix
    upstreamInputName
    ;

  nixosConfigurations = {
    install = installSystem;
    installTemplate = templateSystem;
  };

  packages.${system} = {
    # Nested union schema (back-compat).
    settingsSchema = schemaJson;
    installerIso = unattendedIsoSystem.config.system.build.isoImage;
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
    guidedIso =
      if guidedMissingDefaults != [ ] then
        throw ''
          The guided ISO cannot be built: these options have no default —

            ${lib.concatStringsSep "\n  " guidedMissingDefaults}

          The guided ISO is generic by design: it bakes the install modules
          evaluated with NO settings (identity is chosen on the target box and
          applied by the first-boot reconcile), so every option it evaluates must
          have a default to fall back on.

          Give each option above a placeholder default — the guided install
          overwrites it anyway — or pass `guided = false` to mkProject to build
          only the per-host unattended ISO and the network deploy.
        ''
      else
        guidedIsoSystem.config.system.build.isoImage;
  };

  # ── Checks ─────────────────────────────────────────────────────────────────
  # Heavy by nature: each one builds a real ISO and boots it. They are the only
  # place the offline claim is actually tested, so they are checks and not a
  # side package.
  checks.${system} = {
    offline-install-unattended = mkOfflineTest {
      name = "offline-install-unattended";
      isoSystem = unattendedIsoSystem;
      installScript = "${frameworkSelf}/scripts/unattended-install.sh";
      # The unattended ISO installs to the device baked into its manifest, so
      # the emulated disk has to BE that device — right down to the bus, since
      # /dev/sda and /dev/vda are different qemu hardware.
      diskDevice = if resolvedDiskDevice != "" then resolvedDiskDevice else "/dev/vda";
      # This script is already unattended; the flag only says there is nobody at
      # the debug shell it drops to on failure, so a failure ends the test
      # instead of waiting out its timeout.
      scriptEnv.IH_NONINTERACTIVE = "1";
    };
  }
  // lib.optionalAttrs (guided && guidedMissingDefaults == [ ]) {
    offline-install-guided = mkOfflineTest {
      name = "offline-install-guided";
      isoSystem = guidedIsoSystem;
      installScript = "${frameworkSelf}/scripts/guided-install.sh";
      diskDevice = "/dev/vda";
      answers = guidedAnswers;
      # disko writes the chosen device into `diskoScript`, and a guided ISO by
      # definition does not know it — so that one script is built on the box,
      # from the trivial-builder deps offline-closure.nix ships for exactly this.
      rebuildableOnTarget = [ "disko" ];
      scriptEnv = {
        IH_NONINTERACTIVE = "1";
        IH_DISK_DEVICE = "/dev/vda";
        IH_ANSWERS = "/tmp/ih-answers.json";
      };
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
