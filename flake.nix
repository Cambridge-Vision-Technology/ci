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
      checks = forEachSystem (
        { pkgs }:
        let
          actionlintSource = lib.fileset.toSource {
            root = ./.;
            fileset = lib.fileset.unions [
              ./.github/actionlint.yaml
              ./.github/workflows/workflow.yml
              ./.github/workflows/validate.yml
            ];
          };
          formatSelectedSource = lib.fileset.toSource {
            root = ./.;
            fileset = lib.fileset.unions [
              ./.github/workflows/workflow.yml
              ./.github/workflows/validate.yml
              ./tests/failure-diagnostics/fixture/flake.lock
              ./tests/failure-diagnostics/dev-shell-fixture/flake.lock
              ./tests/failure-diagnostics/single-build-job.schema.json
              ./tests/success-gate/schema.json
            ];
          };
          formatNixSource = lib.fileset.toSource {
            root = ./.;
            fileset = lib.fileset.unions [
              ./flake.nix
              ./tests/failure-diagnostics/fixture/flake.nix
              ./tests/failure-diagnostics/dev-shell-fixture/flake.nix
            ];
          };
          runnerMapTransformSource = lib.fileset.toSource {
            root = ./.;
            fileset = lib.fileset.unions [
              ./tests/runner-map-transform/test.sh
              ./.github/workflows/workflow.yml
            ];
          };
          setupActionStructureSource = lib.fileset.toSource {
            root = ./.;
            fileset = lib.fileset.unions [
              ./tests/setup-action-structure/test.sh
              ./auth
              ./setup
              ./.github
            ];
          };
          workflowStructureSource = lib.fileset.toSource {
            root = ./.;
            fileset = lib.fileset.unions [
              ./tests/workflow-structure/test.sh
              ./.github/workflows/workflow.yml
              ./.github/workflows/validate.yml
              ./.github/actionlint.yaml
              ./setup/action.yml
              ./auth/action.yml
              ./auth/authenticate.sh
              ./tests/org-read-probe/flake.nix
            ];
          };
          singleBuildJobContractSource = lib.fileset.toSource {
            root = ./.;
            fileset = lib.fileset.unions [
              ./.github/workflows/workflow.yml
              ./.github/workflows/validate.yml
              ./tests/failure-diagnostics/single-build-job.schema.json
            ];
          };
          successGateSource = lib.fileset.toSource {
            root = ./.;
            fileset = lib.fileset.unions [
              ./.github/workflows/workflow.yml
              ./tests/success-gate/schema.json
            ];
          };
          checkSuccessGate =
            name: workflow:
            pkgs.runCommand name { nativeBuildInputs = [ pkgs.check-jsonschema ]; } ''
              exec check-jsonschema --schemafile ${successGateSource}/tests/success-gate/schema.json ${workflow} > "$out"
            '';
          workflowText = builtins.readFile ./.github/workflows/workflow.yml;
          strictGate = "\${{ needs.inventory.result != 'success' || needs.build.result != 'success' }}";
          missingInventory = pkgs.writeText "missing-inventory.yml" (
            lib.replaceStrings [ "needs: [inventory, build]" ] [ "needs: build" ] workflowText
          );
          skippedBuildAccepted = pkgs.writeText "skipped-build-accepted.yml" (
            lib.replaceStrings
              [ strictGate ]
              [ "\${{ contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled') }}" ]
              workflowText
          );
        in
        {
          actionlint =
            pkgs.runCommand "actionlint"
              {
                nativeBuildInputs = [ pkgs.actionlint ];
              }
              ''
                set -euo pipefail
                exec actionlint -config-file ${actionlintSource}/.github/actionlint.yaml ${actionlintSource}/.github/workflows/workflow.yml ${actionlintSource}/.github/workflows/validate.yml > "$out"
              '';
          format-selected =
            pkgs.runCommand "format-selected"
              {
                nativeBuildInputs = [ pkgs.nodePackages.prettier ];
              }
              ''
                set -euo pipefail
                exec prettier --check ${formatSelectedSource}/.github/workflows/workflow.yml ${formatSelectedSource}/.github/workflows/validate.yml ${formatSelectedSource}/tests/failure-diagnostics/fixture/flake.lock ${formatSelectedSource}/tests/failure-diagnostics/dev-shell-fixture/flake.lock ${formatSelectedSource}/tests/failure-diagnostics/single-build-job.schema.json ${formatSelectedSource}/tests/success-gate/schema.json > "$out"
              '';
          format-nix =
            pkgs.runCommand "format-nix"
              {
                nativeBuildInputs = [ pkgs.nixfmt-rfc-style ];
              }
              ''
                set -euo pipefail
                exec nixfmt --check ${formatNixSource}/flake.nix ${formatNixSource}/tests/failure-diagnostics/fixture/flake.nix ${formatNixSource}/tests/failure-diagnostics/dev-shell-fixture/flake.nix > "$out"
              '';
          runner-map-transform =
            pkgs.runCommand "runner-map-transform"
              {
                nativeBuildInputs = [
                  pkgs.bash
                  pkgs.coreutils
                  pkgs.jq
                  pkgs.yq-go
                ];
              }
              ''
                set -euo pipefail
                exec bash ${runnerMapTransformSource}/tests/runner-map-transform/test.sh > "$out"
              '';
          setup-action-structure =
            pkgs.runCommand "setup-action-structure"
              {
                nativeBuildInputs = [
                  pkgs.bash
                  pkgs.coreutils
                  pkgs.findutils
                  pkgs.gawk
                  pkgs.gnugrep
                  pkgs.gnused
                  pkgs.yq-go
                ];
              }
              ''
                set -euo pipefail
                exec bash ${setupActionStructureSource}/tests/setup-action-structure/test.sh > "$out"
              '';
          workflow-structure =
            pkgs.runCommand "workflow-structure"
              {
                nativeBuildInputs = [
                  pkgs.bash
                  pkgs.coreutils
                  pkgs.gawk
                  pkgs.gnugrep
                  pkgs.gnused
                ];
              }
              ''
                set -euo pipefail
                exec bash ${workflowStructureSource}/tests/workflow-structure/test.sh > "$out"
              '';
          single-build-job-contract =
            pkgs.runCommand "single-build-job-contract"
              {
                nativeBuildInputs = [ pkgs.check-jsonschema ];
              }
              ''
                set -euo pipefail
                exec check-jsonschema --schemafile ${singleBuildJobContractSource}/tests/failure-diagnostics/single-build-job.schema.json ${singleBuildJobContractSource}/.github/workflows/workflow.yml ${singleBuildJobContractSource}/.github/workflows/validate.yml > "$out"
              '';
          success-gate = checkSuccessGate "success-gate" "${successGateSource}/.github/workflows/workflow.yml";
          success-gate-controls = pkgs.linkFarm "success-gate-controls" [
            {
              name = "missing-inventory";
              path = pkgs.testers.testBuildFailure (checkSuccessGate "reject-missing-inventory" missingInventory);
            }
            {
              name = "skipped-build";
              path = pkgs.testers.testBuildFailure (checkSuccessGate "reject-skipped-build" skippedBuildAccepted);
            }
          ];
        }
      );

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
