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
  };
in
{
  nixosConfigurations = ih.nixosConfigurations;   # install, installTemplate
  packages.${system}  = ih.packages.${system};    # settingsSchema, installerIso, guidedIso
  apps.${system}      = ih.apps.${system};         # configure, install, deploy
}
```

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

When the schema is non-empty, `configure` writes `installer/settings.json`; your
install system reads it as defaults (the framework applies
`{ <root> = lib.mkDefault settings; }`). Keep this file out of secrets — agenix
keys and the like flow through `assets`, never `settings.json`.

You do **not** need to commit `installer/settings.json`. The wizard injects it into
the unattended build by absolute path (`IH_SETTINGS_FILE`, building `--impure`), so
per-host identity stays a local working file. (A flake only copies git-*tracked*
files into `self`; an untracked `settings.json` would otherwise be invisible to
evaluation, and the ISO would silently bake option defaults.) If you build
`.#installerIso` directly (bypassing the wizard), either commit the file or set
`IH_SETTINGS_FILE=$PWD/installer/settings.json` and pass `--impure` yourself.

- **local** — the seeded `/etc/nixos` flake reconciles on first boot (this is how
  a *guided* install applies the host identity that wasn't baked into the offline
  template). Ongoing updates: `nixos-rebuild switch --flake /etc/nixos#install`.
- **remote** — first boot pulls `deployedConfiguration` and switches once, then
  `system.autoUpgrade` keeps it current. Use this for single-purpose, settled
  configs (no `settings.json`).

## Deployment paths

| Path            | Built from              | Offline | Per-host config | Secrets |
|-----------------|-------------------------|:-------:|:---------------:|---------|
| Unattended ISO  | `#installerIso`         | yes     | baked at build  | embedded on ISO |
| Guided ISO      | `#guidedIso`            | yes     | chosen on boot¹ | provided on boot |
| Network install | `#deploy` (nixos-anywhere) | no   | full            | `--extra-files` |

¹ Guided prompts are limited to identity/disk/network/secrets (closure-safe);
feature toggles are fixed in the baked template.
