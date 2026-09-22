# nixos-install-helper

A schema-driven, offline-capable installer framework for NixOS flakes. One
`mkProject` call turns a project's own NixOS options into a full installer:

- a `gum` questionnaire generated from your modules' options
- an **unattended** ISO that installs a specific, pre-baked host offline
- a **guided** ISO that installs a generic template and asks a technician for
  identity/disk/secrets on the box
- a **network** install via `nixos-anywhere`

Both ISOs embed the entire install closure (including flake inputs), so they
install with no network access. See [`lib/mk-offline-install-test.nix`](lib/mk-offline-install-test.nix)
for the VM test that proves a given ISO's closure is actually complete.

## Usage

Add the input:

```nix
inputs.nixos-install-helper.url = "github:Avunu/nixos-install-helper";
inputs.nixos-install-helper.inputs.nixpkgs.follows = "nixpkgs";
```

Call `mkProject` with your install modules and re-export its outputs:

```nix
outputs = inputs@{ self, nixpkgs, nixos-install-helper, ... }:
let
  system = "x86_64-linux";
  ih = nixos-install-helper.lib.mkProject {
    inherit nixpkgs system self;
    installModules = [ self.nixosModules.default ];
    flakeStyle = "local";
    upstream = "github:Owner/repo";
  };
in
{
  nixosConfigurations = ih.nixosConfigurations;
  packages.${system} = ih.packages.${system};
  apps.${system} = ih.apps.${system};
};
```

Then:

```sh
nix run                    # wizard: configure, then choose unattended/guided/network
nix run .#configure        # gum questionnaire → installer/settings.json
nix run .#install          # build/flash an ISO, or install now
nix run .#deploy -- root@<ip>   # nixos-anywhere straight to a reachable target
```

For the full option reference — settings files, secret assets, gum hints,
schema exclusions, guided vs. unattended tradeoffs — see
[`docs/integration.md`](docs/integration.md).

## Development

```sh
nix develop        # nixfmt, gum, jq, check-jsonschema, shellcheck
nix flake check    # module checks, example smoke-test, devShell/formatter builds
```

`examples/minimal` is a tiny consumer used to smoke-test `mkProject`'s schema
path without building a full ISO.
