{
  inputs.ci.url = "path:../..";
  outputs =
    { ci, ... }:
    {
      apps = builtins.mapAttrs (system: packages: {
        docs = {
          type = "app";
          program = "${packages.docs-fixture}/bin/fixture-success";
        };
      }) ci.packages;
    };
}
