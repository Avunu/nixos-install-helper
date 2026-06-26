{
  description = "nixos-install-helper — schema-driven, offline-capable NixOS installer framework";

  # ── Inputs ───────────────────────────────────────────────────────────────────
  # nixpkgs:        package set + NixOS module system (unstable for current kernel
  #                 / installer media).
  # disko:          declarative partitioning; provides `disko` + `disko-install`,
  #                 the engine for both local and nixos-anywhere installs.
  # nixos-anywhere: SSH/kexec network installs for the "network" deployment path.
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixos-anywhere = {
      url = "github:nix-community/nixos-anywhere";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.disko.follows = "disko";
    };
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      disko,
      nixos-anywhere,
    }:
    let
      lib = nixpkgs.lib;
      forAllSystems = lib.genAttrs [
        "x86_64-linux"
        "aarch64-linux"
      ];
    in
    {
      # ── Public library ───────────────────────────────────────────────────────
      # The framework surface. A consuming flake calls `lib.mkProject {...}`; the
      # lower-level helpers are exposed for advanced/standalone use and tests.
      lib = {
        # The one entrypoint most projects use.
        mkProject = import ./lib/mk-project.nix {
          inherit lib disko;
          frameworkSelf = self;
          nixosAnywhere = nixos-anywhere;
        };

        # Evaluated-options → Draft-07 JSON Schema (attrset).
        optionsToJsonSchema = a: import ./lib/options-to-schema.nix ({ inherit lib; } // a);

        # Offline install closure collector (flakeOutPaths + closureInfo).
        offlineClosure = a: import ./lib/offline-closure.nix ({ inherit lib; } // a);

        # Build an installer-ISO nixosSystem directly.
        mkInstallerIso =
          a:
          import ./lib/mk-installer-iso.nix (
            {
              inherit lib nixpkgs disko;
            }
            // a
          );
      };

      # ── NixOS module ─────────────────────────────────────────────────────────
      # Imported automatically by mkProject into every install system; consumers
      # may also import it directly for the lifecycle options.
      nixosModules.installHelper = ./modules/install-helper.nix;
      nixosModules.default = self.nixosModules.installHelper;

      # ── Dev shell & formatter ────────────────────────────────────────────────
      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.mkShell {
            packages = [
              pkgs.nixfmt-rfc-style
              pkgs.gum
              pkgs.jq
              pkgs.check-jsonschema
              pkgs.shellcheck
            ];
          };
        }
      );

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixfmt-rfc-style);

      # ── Example consumer (also a smoke-test for evaluation) ──────────────────
      # `nix eval .#examples.<system>.minimal.settingsSchema` exercises the whole
      # mkProject path on a tiny options-bearing module.
      examples = forAllSystems (system: import ./examples/minimal { inherit self nixpkgs system; });
    };
}
