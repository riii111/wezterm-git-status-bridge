{
  description = "wezterm-git-status-bridge development and build environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    rust-overlay.url = "github:oxalica/rust-overlay";
  };

  outputs =
    {
      self,
      nixpkgs,
      rust-overlay,
    }:
    let
      systems = [
        "aarch64-darwin"
        "x86_64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];

      forAllSystems = nixpkgs.lib.genAttrs systems;

      rustVersion = "1.96.0";
      mkRustToolchain =
        pkgs:
        pkgs.rust-bin.stable.${rustVersion}.default.override {
          extensions = [
            "clippy"
            "rust-analyzer"
            "rust-src"
            "rustfmt"
          ];
        };
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
            overlays = [ rust-overlay.overlays.default ];
          };

          rustToolchain = mkRustToolchain pkgs;
          rustPlatform = pkgs.makeRustPlatform {
            cargo = rustToolchain;
            rustc = rustToolchain;
          };
        in
        {
          default = rustPlatform.buildRustPackage {
            pname = "wezterm-git-status-bridge";
            version = "0.1.0";

            src = self;
            cargoLock.lockFile = ./Cargo.lock;

            nativeCheckInputs = [
              pkgs.git
            ];

            meta = {
              description = "Bridge Git repository status into WezTerm status rendering";
              homepage = "https://github.com/riii111/wezterm-git-status-bridge";
              license = pkgs.lib.licenses.mit;
              mainProgram = "wezterm-git-status-bridge";
            };
          };
        }
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
            overlays = [ rust-overlay.overlays.default ];
          };

          rustToolchain = mkRustToolchain pkgs;
        in
        {
          default = pkgs.mkShell {
            packages = [
              rustToolchain
              pkgs.cargo-audit
              pkgs.cargo-machete
              pkgs.lefthook
              pkgs.lua5_4
            ];
          };
        }
      );

      formatter = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        pkgs.nixfmt
      );
    };
}
