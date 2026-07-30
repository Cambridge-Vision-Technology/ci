{
  description = "Manual organization-read probe fixture. Not a contract suite: it exists so the reusable-workflow probe in validate.yml has a flake whose inputs can only resolve when the App token path is working.";

  inputs = {
    nixpkgs.url = "https://flakehub.com/f/NixOS/nixpkgs/0.1.tar.gz";

    # Private, fetched over plain HTTPS. Resolving this proves the git
    # credential helper the auth script installs reaches Nix's git fetcher.
    infra-base = {
      url = "git+https://github.com/Cambridge-Vision-Technology/infra-base";
      flake = false;
    };

    # Private, addressed by its git+ssh:// flake URL. Nix strips the git+
    # prefix and hands git a plain ssh://git@github.com/… URL, so this input
    # can only resolve when the insteadOf rewrite is installed. No SSH key is
    # present in the probe job.
    nix-shared = {
      url = "git+ssh://git@github.com/Cambridge-Vision-Technology/nix-shared";
      flake = false;
    };

    # Private and Git-LFS bearing (71 tracked *.zstd fixtures, ~9 MB of
    # objects). Chosen over oz (295 MB) and blackbriar (312 MB) so the probe
    # finishes inside its budget. Nix implements the LFS protocol itself and
    # reads the remote through libgit2, which applies insteadOf, so this fetch
    # takes the HTTPS branch and authenticates from netrc-file.
    purescript-dedup = {
      url = "git+ssh://git@github.com/Cambridge-Vision-Technology/purescript-dedup?lfs=1";
      flake = false;
    };
  };

  # Every input is flake = false on purpose: the fetcher, and therefore the
  # credential and rewrite path under test, is identical, while none of the
  # transitive input graphs are downloaded.
  outputs =
    {
      nixpkgs,
      infra-base,
      nix-shared,
      purescript-dedup,
      ...
    }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in
    {
      checks.${system}.org-read-probe = pkgs.runCommand "org-read-probe" { } ''
        set -euo pipefail

        test -f ${infra-base}/flake.nix
        test -d ${nix-shared}/modules

        find ${purescript-dedup} -type f -name '*.zstd' | sort > lfs-files
        test -s lfs-files
        head -c 100 "$(head -n 1 lfs-files)" > lfs-header
        if grep -q 'git-lfs.github.com/spec/v1' lfs-header; then
          echo "Git-LFS object is an unsmudged pointer: LFS objects were not fetched" >&2
          exit 1
        fi

        touch $out
      '';
    };
}
