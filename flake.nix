{
  description = "Development environment for the Ursula Zig client library";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    zig-overlay = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    ursula-overlay = {
      url = "github:rupurt/ursula-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, zig-overlay, ursula-overlay, ... }:
    let
      systems = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-darwin"
        "x86_64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      packagesFor = system: {
        inherit (ursula-overlay.packages.${system}) ursula ursulactl;
      };
    in
    {
      packages = forAllSystems packagesFor;

      devShells = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
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
