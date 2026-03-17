{
  inputs = {
    nixpkgs.url = "https://flakehub.com/f/DeterminateSystems/nixpkgs-weekly/*";

    agen = {
      url = "git+ssh://git@github.com/Cambridge-Vision-Technology/agen";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { nixpkgs, agen, ... }:
    let
      inherit (nixpkgs) lib;

      systems = [
        "aarch64-linux"
        "aarch64-darwin"
        "x86_64-linux"
      ];

      forEachSystem =
        f:
        lib.genAttrs systems (
          system:
          let
            pkgs = nixpkgs.legacyPackages.${system};
          in
          f { inherit pkgs; }
        );
    in
    {

      devShells = forEachSystem (
        { pkgs }:
        {
          default = pkgs.mkShellNoCC {
            buildInputs = [
              pkgs.nodePackages.prettier
              pkgs.actionlint
              agen.packages.${pkgs.system}.default
            ];

            shellHook = ''
              # Regenerate CLAUDE.md from agents.yaml and company guidance
              agen >&2
            '';
          };
        }
      );
    };
}
