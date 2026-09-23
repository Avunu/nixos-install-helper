# Integrating a project with nixos-install-helper

`nixos-install-helper` turns a project's **module set** into a complete installer:
a derived JSON-Schema-driven [gum](https://github.com/charmbracelet/gum) menu, an
offline unattended ISO, a generic guided ISO, and a `nixos-anywhere` network
install — all from one `mkProject` call.

The configurable surface you expose is *whatever options your install modules
declare*. Declare none and you get a reliable no-prompt installer; declare
`router.*`/`microDesktop.*`/… and they become the menu automatically.

## 1. Add the input

```nix
inputs.nixos-install-helper.url = "github:Avunu/nixos-install-helper";
inputs.nixos-install-helper.inputs.nixpkgs.follows = "nixpkgs";
```

## 2. Call `mkProject` and re-export its outputs

```nix
outputs = inputs@{ self, nixpkgs, nixos-install-helper, ... }:
let
  system = "x86_64-linux";
  ih = nixos-install-helper.lib.mkProject {
    inherit nixpkgs system self;

    # Modules the installer lays down via disko.
    installModules = [ self.nixosModules.default ];

    # "local"  → seed /etc/nixos referencing `upstream`, ongoing nixos-rebuild.
    # "remote" → boot minimal, then autoUpgrade to `deployedConfiguration`.
    flakeStyle = "local";
    upstream   = "github:Owner/repo";

    # Optional: secret/key assets injected via --extra-files at install time.
    assets = [ {
      name = "agenix-key"; target = "/etc/agenix/key"; mode = "0400";
      required = true; source = { env = "agenix__key"; prompt = "paste"; };
    } ];

    # Optional: richer gum widgets for specific settings paths.
    hints = { "diskDevice" = "disk-device"; "wan.interface" = "net-iface"; };

    # Optional: FLAT per-root settings files (keyed by option root). Defaults to
    # installer/<root>-settings.json. Each file holds that root's option VALUES at
    # top level (no <root> wrapper) and is applied as `{ <root> = mkDefault … }`.
    settingsFiles.router = ./local/router-settings.json;

    # Optional: drop sub-paths (relative to each root) from the derived schema —
    # e.g. keep router.cockpit.* Nix-locked, out of the JSON/UI.
    schemaExclude = [ "cockpit" ];

    # Optional: set false to skip the guided (generic template) ISO entirely.
    guided = true;
  };
in
{
  nixosConfigurations = ih.nixosConfigurations;   # install, installTemplate
  packages.${system}  = ih.packages.${system};    # settingsSchema, settingsSchema-<root>, installerIso, guidedIso
  apps.${system}      = ih.apps.${system};         # configure, install, deploy
}
```

## Settings: flat per-root JSON

For each technician-facing option root, the framework reads a **flat** JSON file —
`installer/<root>-settings.json` by default, or the path you give in
`settingsFiles.<root>` — whose keys are that root's options directly (no `<root>`
wrapper), and applies it as `{ <root> = lib.mkDefault <flat> }`. `nix run .#configure`
writes these files; the derived per-root schema is exposed as the package
`settingsSchema-<root>` (a flat Draft-07 schema, minus any `schemaExclude` sub-paths)
— use it as the single source of truth for a Cockpit-style editor.

This scoping is a **security boundary**: because the local install seeds these same
flat files into `/etc/nixos/<root>-settings.json` and the synthesized flake applies
each **only** under its root, a live editor (e.g. Cockpit writing that file) can only
affect that root's typed options — never arbitrary system config.

### Upgrading settings across releases: `lib.settingsModules.<root>`

An installed machine keeps its settings file across upgrades, so it can still hold
a shape an older release wrote after an option was renamed or reshaped. Imported
as plain defaults, that fails the machine's next rebuild on an option that no
longer exists.

A project whose options change shape can export a loader per root from its flake:

```nix
# In the project's flake outputs:
lib.settingsModules.<root> = path: { lib, ... }: {
  <root> = lib.mkDefault (upgrade (builtins.fromJSON (builtins.readFile path)));
};
```

It takes the settings-file path and returns a NixOS module. The synthesized
`/etc/nixos/flake.nix` uses it for that root whenever the upstream exports one, and
falls back to plain `mkDefault` otherwise. The check happens when the machine
evaluates its flake, not when the ISO is built. So a machine installed before
the project added a loader starts using it on its next upgrade; the seeded
`flake.nix` itself is never rewritten.

The loader is upstream code, so the security boundary above is now its job: it
must apply the JSON only under its own root. nixos-router's
`lib/settings.nix` is a complete example. It upgrades old shapes, and has the
module rewrite the file on disk so the settings editor only ever sees the
current format.

## 3. Use it

A single entrypoint drives everything — collect settings (if the project has any),
then choose a deployment path:

```sh
nix run                       # from a checkout: launches the wizard (.#default)
nix run github:Owner/repo     # or straight from the published flake, no clone
nix run . -- root@<ip>        # pre-seed the network-install target
```

Individual steps are also exposed if you want them directly:

```sh
nix run .#configure           # gum questionnaire → installer/settings.json (no-op if no options)
nix run .#install             # choose: unattended ISO | guided ISO | network
nix run .#deploy -- root@<ip> # nixos-anywhere straight to a reachable target
```

For an unattended ISO that embeds an env-sourced secret, export it first and the
wizard builds `--impure` automatically:

```sh
export agenix__key="$(cat ~/.config/agenix/key)"
nix run        # → Unattended ISO
```

## What makes an option technician-facing?

The schema is derived from the **options your install modules declare**, filtered to:

- a top-level namespace **your project introduces** (auto-detected by declaration
  source; override with `optionRoots = [ "router" ]`). List **only** the roots you
  actually want asked about. In particular, if your module re-declares an upstream
  module's options and passes them through (`config.microDesktop.hostName =
  cfg.hostName; …`), list only *your* root (`optionRoots = [ "devWorkstation" ]`) —
  listing both (`[ "devWorkstation" "microDesktop" ]`) prompts every shared option
  twice and writes downstream values your passthrough then overrides. Name an
  upstream root only for options that root declares and you do **not** re-expose;
- options that are **not** `internal` / `visible = false` (use these to hide
  derived/`_internal` values);
- options of a **serializable** type. `package`, `functionTo`, etc. are dropped
  automatically and keep their Nix-side defaults — declare anything that should
  *not* be asked at install as one of these (or mark it `internal`).

## Flake styles & the value file

When the schema is non-empty, `configure` writes flat `installer/<root>-settings.json`
files; your install system reads them as defaults (the framework applies
`{ <root> = lib.mkDefault <flat>; }`). Keep these out of secrets — agenix keys and the
like flow through `assets`, never the settings JSON.

You do **not** need to commit the settings files. The wizard injects the `installer/`
directory into the unattended build by absolute path (`IH_SETTINGS_DIR`, building
`--impure`), so per-host identity stays local. (A flake only copies git-*tracked*
files into `self`; untracked files would otherwise be invisible to evaluation, and the
ISO would silently bake option defaults.) If you build `.#installerIso` directly
(bypassing the wizard), either commit the files or set `IH_SETTINGS_DIR=$PWD/installer`
and pass `--impure` yourself.

- **local** — the installer seeds `/etc/nixos` with a **synthesized minimal flake**
  (`flake.nix` + one flat `<root>-settings.json` per root + a placeholder
  `local.nix`), *not* a copy of your project. The flake pulls the module(s) from
  `upstream` (github) and applies each root's flat JSON **scoped under that root**:

  ```nix
  inputs.nixos-nano-desktop.url = "github:Owner/nixos-nano-desktop";   # = your `upstream`
  # nixosConfigurations."${host.config.networking.hostName}" = host;  (+ `default` alias)
  # specialArgs = { inherit inputs; };
  # modules = [ nixos-nano-desktop.nixosModules.<root>
  #             (nixos-nano-desktop.lib.settingsModules.<root> ./<root>-settings.json)
  #             # …or, without a project loader:
  #             # { <root> = mapAttrs mkDefault (fromJSON ./<root>-settings.json); }
  #           ] ++ lib.optional (builtins.pathExists ./local.nix) ./local.nix;
  ```

  The input is named after the **repo** in your `upstream` ref (`github:Owner/repo`
  and `git+https://host/a/repo.git` both → `repo`), so the seeded flake reads like
  one a human wrote and `nix flake metadata /etc/nixos` names what the machine
  actually tracks. A name that isn't a valid Nix identifier (leading digit, a dot)
  is sanitized, and `nixpkgs`/`self` fall back to the generic `project`.

  The imported module names are derived from your `optionRoots` (each root that the
  project also exports as `nixosModules.<root>`). Ongoing updates just track
  upstream: `nixos-rebuild switch --flake /etc/nixos` (bare — resolves by hostname).

  **`local.nix`** is the machine's own escape hatch, seeded empty-but-annotated and
  never rewritten by an upgrade. The typed JSON settings can only carry that root's
  *serializable* options, so the most common customization of all — "install one
  more program" — has nowhere to go in JSON (a package is a Nix value, not a
  string). `local.nix` is a plain NixOS module merged on top, shipped with an
  `environment.systemPackages` block ready to fill in; the flake imports it under
  `pathExists`, so deleting it is also fine. Every flake input reaches it as
  `inputs` (via `specialArgs`), so a package from an added input needs no edit to
  the generated `flake.nix` beyond the input itself.

  For a normal local install the **baked system is already complete**, so there is
  **no first-boot rebuild** (agenix secrets activate at boot). Two cases do rebuild
  once on first boot against the seeded flake's `#default`:
  - **guided** — always, to apply the identity chosen on the box (via an
    `/etc/nixos/.first-boot-reconcile` marker the guided installer drops);
  - **staged local** — when you set `installHelper.reconcile = true`: bake a minimal
    `installModules` offline, let the synthesized flake import the full module, and
    the reconcile applies the full config (with live secrets) on first boot.
- **remote** — first boot pulls `deployedConfiguration` and switches once, then
  `system.autoUpgrade` keeps it current. This is the path for **staged
  module-separation** (install a minimal `installModules` offline, then switch to the
  full production config with live secrets/disks) — e.g. cocalico, which sets
  `lifecycle = false` and owns the first-boot switch itself. No `settings.json`.

## Deployment paths

| Path            | Built from              | Offline | Per-host config | Secrets |
|-----------------|-------------------------|:-------:|:---------------:|---------|
| Unattended ISO  | `#installerIso`         | yes     | baked at build  | embedded on ISO |
| Guided ISO      | `#guidedIso`            | yes     | chosen on boot¹ | provided on boot |
| Network install | `#deploy` (nixos-anywhere) | no   | full            | `--extra-files` |

¹ Guided prompts are limited to identity/disk/network/secrets (closure-safe);
feature toggles are fixed in the baked template.

### Leaving something off the guided ISO: `templateSettings`

A guided ISO carries the template's whole closure, and a full desktop closure
lands near GitHub's 2 GiB release-asset cap. `templateSettings` bakes a lighter
value into the template **and** seeds it into the installed machine's settings
file, so the system the ISO installs is the system the ISO carries and the
first-boot reconcile has nothing to fetch:

```nix
templateSettings.nanoDesktop.officeSuite = "none";
```

Root-keyed and flat, like `settingsFiles`; merged *under* the prompt answers, so
an answer always wins. The guided installer lists these in its confirmation
summary as "not on this media". The owner turns them back on later, online,
through whatever edits `<root>-settings.json` — the project's settings UI should
say that a network is needed, since this framework cannot know which values are
heavy.
