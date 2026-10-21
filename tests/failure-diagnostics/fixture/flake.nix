{
  inputs.nixpkgs.url = "https://api.flakehub.com/f/pinned/DeterminateSystems/nixpkgs-weekly/0.1.785333%2Brev-ebe4301cbd8f81c4f8d3244b3632338bbeb6d49c/01965c00-a987-7897-9240-abc0268d7590/source.tar.gz";

  outputs =
    { nixpkgs, ... }:
    {
      checks = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-darwin" ] (system: {
        controlled-failure = builtins.derivation {
          name = "controlled-flake-failure";
          inherit system;
          builder = "${nixpkgs.legacyPackages.${system}.coreutils}/bin/false";
        };
      });
    };
}
