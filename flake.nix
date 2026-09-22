{
  description = "Development environment for the Ursula Zig client library";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    zig-overlay = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, zig-overlay, rust-overlay, ... }:
    let
      systems = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-darwin"
        "x86_64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      pkgsFor = system: import nixpkgs {
        inherit system;
        overlays = [ rust-overlay.overlays.default ];
      };
      packagesFor = system:
        let
          pkgs = pkgsFor system;
          ursula = pkgs.callPackage ./nix/ursula.nix { };
        in
        {
          inherit ursula;
          ursulactl = pkgs.callPackage ./nix/ursulactl.nix { inherit ursula; };
        };
    in
    {
      packages = forAllSystems packagesFor;

      devShells = forAllSystems (system:
        let
          pkgs = pkgsFor system;
          packages = packagesFor system;
        in
        {
          default = pkgs.mkShell {
            packages = [
              zig-overlay.packages.${system}.master
              pkgs.just
              pkgs.python3
              packages.ursula
              packages.ursulactl
            ];
          };
        });
    };
}
