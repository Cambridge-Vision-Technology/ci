{
  pkgs,
  purs-nix,
  platform,
  purescript-whine,
}:
let
  inventory = builtins.fromJSON (builtins.readFile ../tools/inputs.json);
  source =
    files:
    pkgs.lib.fileset.toSource {
      root = ../.;
      fileset = pkgs.lib.fileset.unions (map (file: ../. + "/${file}") files);
    };
  platformRoot = /. + builtins.unsafeDiscardStringContext platform.outPath;
  platformFiles = [
    "tools/Platform/Node/Build.purs"
    "tools/Platform/Node/Build.js"
    "tools/Platform/Node/Documents.purs"
    "tools/Platform/Node/Documents.js"
    "tools/Build/Output.purs"
    "node/Platform/Node/System.purs"
    "node/Platform/Node/System.js"
  ];
  primitivesFor =
    files:
    pkgs.lib.fileset.toSource {
      root = platformRoot;
      fileset = pkgs.lib.fileset.unions (map (file: platformRoot + "/${file}") files);
    };
  purs = purs-nix {
    inherit pkgs;
    system = pkgs.stdenv.hostPlatform.system;
    defaults.compile.codegen = "js,corefn";
  };
  compile =
    files: nativeFiles:
    (purs.purs {
      srcs =
        [
          "${source files}/tools"
          "${primitivesFor nativeFiles}/tools"
        ]
        ++ pkgs.lib.optional (builtins.elem "node/Platform/Node/System.purs" nativeFiles) "${primitivesFor nativeFiles}/node";
      dependencies =
        [
          "prelude"
          "effect"
          "arrays"
          "either"
          "maybe"
          "nullable"
          "numbers"
          "strings"
          "foldable-traversable"
          "exceptions"
          "argonaut-codecs"
          "foreign-object"
          "node-process"
          "node-path"
          "node-streams"
        ]
        ++
          pkgs.lib.optionals
            (
              builtins.elem "tools/CI/Docs/Test.purs" files
              || builtins.elem "tools/CI/Workflow/PlumbingCheck.purs" files
            )
            [
              "refs"
              "now"
              "datetime"
            ]
        ++ pkgs.lib.optionals (builtins.elem "tools/CI/Docs/TransportFixture.purs" files) [
          "refs"
          "node-event-emitter"
          "node-buffer"
        ];
    });
  compiler = compile inventory.docs platformFiles;
  cli = compiler.script { module = "CI.Docs.Main"; };
  detector = "${source [ "nix/docs-app-present.nix" ]}/nix/docs-app-present.nix";
  tool = pkgs.writeShellScriptBin "ci-docs" ''
    set -euo pipefail
    exec ${pkgs.coreutils}/bin/env PATH="${
      pkgs.lib.makeBinPath [
        pkgs.coreutils
        pkgs.curl
        pkgs.gh
      ]
    }:$PATH" ${cli} ${detector} "$@"
  '';
  fixtureFiles = [
    "tools/Platform/Node/Build.purs"
    "tools/Platform/Node/Build.js"
  ];
  workflowPrimitiveFiles = platformFiles;
  workflowCompiler = compile inventory.workflowPlumbing workflowPrimitiveFiles;
  workflowTests = workflowCompiler.script { module = "CI.Workflow.PlumbingCheck"; };
  fixtureCompiler = compile inventory.fixture fixtureFiles;
  fixture = fixtureCompiler.script { module = "CI.Docs.Fixture"; };
  transportFixtureCompiler = compile inventory.transportFixture platformFiles;
  transportFixture = transportFixtureCompiler.script { module = "CI.Docs.TransportFixture"; };
  fakeCurl = pkgs.writeShellScriptBin "curl" ''
    set -euo pipefail
    exec ${transportFixture} curl "$@"
  '';
  fakeGh = pkgs.writeShellScriptBin "gh" ''
    set -euo pipefail
    exec ${transportFixture} gh "$@"
  '';
  fixtureFor =
    mode:
    pkgs.writeShellScript "fixture-${mode}" ''
      set -euo pipefail
      exec ${fixture} ${mode}
    '';
  fixtureSuccess = pkgs.writeShellScriptBin "fixture-success" ''
    set -euo pipefail
    exec ${fixture} success
  '';
  testFiles =
    builtins.filter (file: file != "tools/CI/Docs/Main.purs") inventory.docs ++ inventory.tests;
  testCompiler = compile testFiles platformFiles;
  tests = testCompiler.script { module = "CI.Docs.Test"; };
  platformInventory = builtins.fromJSON (builtins.readFile (platformRoot + "/nix/inputs.json"));
  inventorySource = primitivesFor platformInventory.inventoryRunner;
  inventoryCompiler = purs.purs {
    srcs = [ "${inventorySource}/tools" ];
    dependencies = [
      "prelude"
      "effect"
      "arrays"
      "either"
      "maybe"
      "nullable"
      "exceptions"
      "argonaut-codecs"
      "foreign-object"
      "strings"
      "foldable-traversable"
      "ordered-collections"
      "node-path"
      "node-process"
    ];
  };
  inventoryTool = inventoryCompiler.script { module = "Build.Inventory"; };
  checkRunnerSource = primitivesFor platformInventory.checkRunner;
  checkRunner =
    (purs.purs {
      srcs = [ "${checkRunnerSource}/tools" ];
      dependencies = [
        "prelude"
        "effect"
        "arrays"
        "maybe"
        "exceptions"
        "node-process"
      ];
    }).script
      { module = "Build.CheckRunner"; };
  lintSource = source (
    inventory.docs
    ++ inventory.fixture
    ++ inventory.tests
    ++ inventory.transportFixture
    ++ inventory.workflowPlumbing
    ++ [ "whine.yaml" ]
  );
  inventoryCheck =
    name: compilation: files: nativeFiles: entry:
    pkgs.runCommand "${name}-source-inventory" { } ''
      set -euo pipefail
      exec ${inventoryTool} "$out" ${
        pkgs.writeText "${name}-inventory.json" (
          builtins.toJSON {
            inherit name;
            backend = "node";
            roots = [ entry ];
            compiler = "${purs.purescript}/bin/purs";
            compilation = compilation.output { };
            dependencies = map toString compilation.dependencies;
            groups = [
              {
                root = source files;
                inherit files;
              }
              {
                root = primitivesFor nativeFiles;
                files = nativeFiles;
              }
            ];
          }
        )
      }
    '';
  generationCases = [
    "absent"
    "stale-absent"
    "success"
    "failure"
    "missing"
    "empty"
    "invalid"
    "empty-index"
    "link"
    "hardlink"
    "special"
    "evaluation"
  ];
  publicationCases = [
    "transport"
    "progress"
    "retry-progress"
    "progress-failure"
    "unknown-status"
    "retry-exhausted"
    "mechanism"
    "denial-protocol"
    "pr"
    "repository"
    "revision"
    "run"
    "workflow"
    "digest"
    "missing-site"
    "public-site"
    "unavailable"
    "public-access"
    "spoof-access"
    "deployment-failure"
    "creation-failure"
    "verification-failure"
  ];
  generationChecks = pkgs.lib.genAttrs generationCases (
    mode:
    pkgs.runCommand "docs-generation-${mode}"
      {
        DOCS_TEST_SYSTEM = pkgs.stdenv.hostPlatform.system;
        nativeBuildInputs = [
          pkgs.nix
          pkgs.git
          pkgs.coreutils
        ];
      }
      ''
        set -euo pipefail
        exec ${pkgs.coreutils}/bin/timeout --kill-after=2s 60s ${tests} generation ${tool}/bin/ci-docs ${fixtureFor mode} ${mode} "$out"
      ''
  );
  publicationChecks = pkgs.lib.genAttrs publicationCases (
    mode:
    pkgs.runCommand "docs-publication-${mode}"
      {
        nativeBuildInputs =
          [
            pkgs.coreutils
            fixtureSuccess
          ]
          ++ pkgs.lib.optionals (mode == "transport") [
            fakeCurl
            fakeGh
          ];
      }
      ''
        set -euo pipefail
        exec ${pkgs.coreutils}/bin/timeout --kill-after=2s 60s ${tests} publication ${mode} "$out"
      ''
  );
  aggregate =
    name: checks:
    pkgs.linkFarm name (pkgs.lib.mapAttrsToList (name: path: { inherit name path; }) checks);
  workflowSource = source [
    ".github/workflows/workflow.yml"
    "tests/documentation/workflow.schema.json"
  ];
  workflowCheck =
    name: workflow:
    pkgs.runCommand name { nativeBuildInputs = [ pkgs.check-jsonschema ]; } ''
      set -euo pipefail
      exec check-jsonschema --schemafile ${workflowSource}/tests/documentation/workflow.schema.json ${workflow} > "$out"
    '';
  workflowText = builtins.readFile ../.github/workflows/workflow.yml;
  missingPreflight = pkgs.writeText "docs-missing-preflight.yml" (
    pkgs.lib.replaceStrings
      [ "run: nix run .#docs-tool -- preflight" ]
      [ "run: nix run .#docs-tool -- verify" ]
      workflowText
  );
in
{
  workflowPlumbing =
    workflowSource:
    pkgs.runCommand "workflow-plumbing-large-input"
      {
        nativeBuildInputs = [
          pkgs.bash
          pkgs.coreutils
          pkgs.gnugrep
          pkgs.gnused
          pkgs.gawk
        ];
      }
      ''
        set -euo pipefail
        exec ${pkgs.coreutils}/bin/timeout --kill-after=2s 60s ${workflowTests} ${workflowSource} "$out"
      '';
  packages.docs-tool = tool;
  packages.docs-fixture = fixtureSuccess;
  apps.docs-tool = {
    type = "app";
    program = "${tool}/bin/ci-docs";
  };
  checks =
    {
      docs-lint-whine = pkgs.runCommand "docs-lint-whine" { } ''
        set -euo pipefail
        exec ${checkRunner} "$out" ${lintSource} ${pkgs.coreutils}/bin/timeout --kill-after=2s 60s ${
          purescript-whine.packages.${pkgs.stdenv.hostPlatform.system}.default
        }/bin/whine
      '';
      docs-format = pkgs.runCommand "docs-format" { } ''
        set -euo pipefail
        exec ${pkgs.nodePackages.purs-tidy}/bin/purs-tidy check ${
          source (
            inventory.docs
            ++ inventory.fixture
            ++ inventory.tests
            ++ inventory.transportFixture
            ++ inventory.workflowPlumbing
          )
        }/tools > "$out"
      '';
      docs-workflow = workflowCheck "docs-workflow" "${workflowSource}/.github/workflows/workflow.yml";
      docs-workflow-controls = pkgs.testers.testBuildFailure (
        workflowCheck "reject-docs-without-preflight" missingPreflight
      );
      docs-source-inventory =
        inventoryCheck "ci-docs" compiler inventory.docs platformFiles
          "CI.Docs.Main";
      workflow-plumbing-source-inventory =
        inventoryCheck "workflow-plumbing" workflowCompiler inventory.workflowPlumbing
          workflowPrimitiveFiles
          "CI.Workflow.PlumbingCheck";
      docs-test-source-inventory =
        inventoryCheck "ci-docs-test" testCompiler testFiles platformFiles
          "CI.Docs.Test";
      docs-fixture-source-inventory =
        inventoryCheck "ci-docs-fixture" fixtureCompiler inventory.fixture fixtureFiles
          "CI.Docs.Fixture";
      docs-transport-fixture-source-inventory =
        inventoryCheck "ci-docs-transport-fixture" transportFixtureCompiler inventory.transportFixture
          platformFiles
          "CI.Docs.TransportFixture";
      docs-generation = aggregate "docs-generation" generationChecks;
      docs-publication = aggregate "docs-publication" publicationChecks;
    }
    // pkgs.lib.mapAttrs' (
      name: value: pkgs.lib.nameValuePair "docs-generation-${name}" value
    ) generationChecks
    // pkgs.lib.mapAttrs' (
      name: value: pkgs.lib.nameValuePair "docs-publication-${name}" value
    ) publicationChecks;
}
