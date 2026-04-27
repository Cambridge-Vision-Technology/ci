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

      repoSource = lib.fileset.toSource {
        root = ./.;
        fileset = lib.fileset.unions [
          ./.github
          ./tests
        ];
      };

      mkShellTest =
        pkgs: name:
        pkgs.runCommand "test-${name}"
          {
            nativeBuildInputs = [
              pkgs.bash
              pkgs.jq
              pkgs.yq-go
              pkgs.gnugrep
              pkgs.gnused
              pkgs.coreutils
            ];
          }
          ''
            set -e
            cp -r ${repoSource} repo
            chmod -R u+w repo
            cd repo
            bash tests/${name}/test.sh
            touch $out
          '';
    in
    {

      devShells = forEachSystem (
        { pkgs }:
        {
          default = pkgs.mkShellNoCC {
            buildInputs = [
              pkgs.nodePackages.prettier
              pkgs.actionlint
              pkgs.jq
              pkgs.yq-go
              agen.packages.${pkgs.system}.default
            ];

            shellHook = ''
              # Regenerate CLAUDE.md from agents.yaml and company guidance
              agen >&2
            '';
          };
        }
      );

      checks = forEachSystem (
        { pkgs }:
        {
          workflow-structure = mkShellTest pkgs "workflow-structure";
          runner-map-transform = mkShellTest pkgs "runner-map-transform";
        }
      );

      apps = forEachSystem (
        { pkgs }:
        {
          format-fix = {
            type = "app";
            program =
              let
                script = pkgs.writeShellApplication {
                  name = "format-fix";
                  runtimeInputs = [ pkgs.nodePackages.prettier ];
                  text = ''
                    set -euo pipefail
                    prettier --write \
                      --ignore-path .gitignore \
                      --no-error-on-unmatched-pattern \
                      "**/*.yml" \
                      "**/*.yaml" \
                      "**/*.json" \
                      "**/*.md"
                  '';
                };
              in
              "${script}/bin/format-fix";
          };
        }
      );
    };
}
