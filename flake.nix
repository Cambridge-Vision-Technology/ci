{
  inputs = {
    nixpkgs.url = "https://flakehub.com/f/DeterminateSystems/nixpkgs-weekly/*";
    purs-nix = {
      url = "git+ssh://git@github.com/Cambridge-Vision-Technology/purs-nix?ref=main&lfs=1";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    platform = {
      url = "git+ssh://git@github.com/Cambridge-Vision-Technology/purescript-platform.git?ref=main&lfs=1";
      flake = false;
    };
    purescript-whine = {
      url = "git+ssh://git@github.com/Cambridge-Vision-Technology/purescript-whine?ref=main&lfs=1";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.purs-nix.follows = "purs-nix";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      purs-nix,
      platform,
      purescript-whine,
      ...
    }:
    let
      inherit (nixpkgs) lib;

      systems = [
        "aarch64-linux"
        "aarch64-darwin"
        "x86_64-darwin"
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
      documentation =
        pkgs:
        import ./nix/documentation.nix {
          inherit
            pkgs
            purs-nix
            platform
            purescript-whine
            ;
        };
    in
    {
      packages = forEachSystem ({ pkgs }: (documentation pkgs).packages);
      apps = forEachSystem ({ pkgs }: (documentation pkgs).apps);
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
              ./tests/job-scoped-caches.schema.json
              ./tests/documentation/workflow.schema.json
              ./tools/inputs.json
              ./whine.yaml
              ./tests/docs-smoke/flake.lock
            ];
          };
          formatNixSource = lib.fileset.toSource {
            root = ./.;
            fileset = lib.fileset.unions [
              ./flake.nix
              ./nix/documentation.nix
              ./nix/docs-app-present.nix
              ./tests/docs-smoke/flake.nix
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
          jobScopedCachesSource = lib.fileset.toSource {
            root = ./.;
            fileset = lib.fileset.unions [
              ./.github/workflows/workflow.yml
              ./tests/job-scoped-caches.schema.json
            ];
          };
          checkSuccessGate =
            name: workflow:
            pkgs.runCommand name { nativeBuildInputs = [ pkgs.check-jsonschema ]; } ''
              exec check-jsonschema --schemafile ${successGateSource}/tests/success-gate/schema.json ${workflow} > "$out"
            '';
          workflowText = builtins.readFile ./.github/workflows/workflow.yml;
          strictGate = "\${{ needs.inventory.result != 'success' || needs.build.result != 'success' || (needs.publish-docs.result != 'success' && needs.publish-docs.result != 'skipped') }}";
          missingInventory = pkgs.writeText "missing-inventory.yml" (
            lib.replaceStrings [ "needs: [inventory, build, publish-docs]" ] [ "needs: build" ] workflowText
          );
          skippedBuildAccepted = pkgs.writeText "skipped-build-accepted.yml" (
            lib.replaceStrings
              [ strictGate ]
              [ "\${{ contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled') }}" ]
              workflowText
          );
        in
        (documentation pkgs).checks
        // {
          docs-platform-exports =
            assert lib.all
              (
                system:
                builtins.hasAttr "docs-tool" self.packages.${system} && self.apps.${system}.docs-tool.type == "app"
              )
              [
                "x86_64-linux"
                "aarch64-linux"
                "aarch64-darwin"
                "x86_64-darwin"
              ];
            pkgs.runCommand "docs-platform-exports" { } ''
              set -euo pipefail
              exec ${pkgs.coreutils}/bin/touch "$out"
            '';
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
                exec prettier --check ${formatSelectedSource}/.github/workflows/workflow.yml ${formatSelectedSource}/.github/workflows/validate.yml ${formatSelectedSource}/tests/failure-diagnostics/fixture/flake.lock ${formatSelectedSource}/tests/failure-diagnostics/dev-shell-fixture/flake.lock ${formatSelectedSource}/tests/failure-diagnostics/single-build-job.schema.json ${formatSelectedSource}/tests/success-gate/schema.json ${formatSelectedSource}/tests/job-scoped-caches.schema.json ${formatSelectedSource}/tests/documentation/workflow.schema.json ${formatSelectedSource}/tools/inputs.json ${formatSelectedSource}/whine.yaml ${formatSelectedSource}/tests/docs-smoke/flake.lock > "$out"
              '';
          format-nix =
            pkgs.runCommand "format-nix"
              {
                nativeBuildInputs = [ pkgs.nixfmt-rfc-style ];
              }
              ''
                set -euo pipefail
                exec nixfmt --check ${formatNixSource}/flake.nix ${formatNixSource}/nix/documentation.nix ${formatNixSource}/nix/docs-app-present.nix ${formatNixSource}/tests/docs-smoke/flake.nix ${formatNixSource}/tests/failure-diagnostics/fixture/flake.nix ${formatNixSource}/tests/failure-diagnostics/dev-shell-fixture/flake.nix > "$out"
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
          workflow-plumbing-large-input = (documentation pkgs).workflowPlumbing workflowStructureSource;
          single-build-job-contract =
            pkgs.runCommand "single-build-job-contract"
              {
                nativeBuildInputs = [ pkgs.check-jsonschema ];
              }
              ''
                set -euo pipefail
                exec check-jsonschema --schemafile ${singleBuildJobContractSource}/tests/failure-diagnostics/single-build-job.schema.json ${singleBuildJobContractSource}/.github/workflows/workflow.yml ${singleBuildJobContractSource}/.github/workflows/validate.yml > "$out"
              '';
          job-scoped-caches-contract =
            pkgs.runCommand "job-scoped-caches-contract" { nativeBuildInputs = [ pkgs.check-jsonschema ]; }
              ''
                set -euo pipefail
                exec ${pkgs.coreutils}/bin/timeout 60s check-jsonschema --schemafile ${jobScopedCachesSource}/tests/job-scoped-caches.schema.json ${jobScopedCachesSource}/.github/workflows/workflow.yml > "$out"
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
            ];
          };
        }
      );
    };
}
