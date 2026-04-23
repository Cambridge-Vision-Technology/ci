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

      # Default gitleaks config — extends built-in rules with path exclusions
      # common across our repos (test recording fixtures, snapshots, lockfiles).
      # Consumer repos override with a .gitleaks.toml at their own repo root.
      defaultGitleaksConfig =
        pkgs:
        pkgs.writeText "gitleaks.toml" ''
          title = "Cambridge-Vision-Technology default gitleaks config"
          [extend]
          useDefault = true

          [allowlist]
          description = "Common test fixture paths that contain recorded API responses, not real secrets."
          paths = [
            '(^|/)features/fixtures/',
            '(^|/)fixtures/',
            '(^|/)test/fixtures/',
            '(^|/)tests/fixtures/',
            '(^|/)__snapshots__/',
            '\.snap$',
            'package-lock\.json$',
            'yarn\.lock$',
            'flake\.lock$',
          ]
        '';

      securityScanScript =
        pkgs:
        pkgs.writeShellScript "ci-security-scan" ''
          # Security scan orchestrator. Runs gitleaks, trivy, semgrep, syft
          # against a target directory and emits SARIF (per-scanner) +
          # CycloneDX SBOM + markdown summary under ./out/security/.
          #
          # Exits non-zero if any scanner has un-suppressed findings or any
          # allowlist entry lacks a "rationale:" comment (rationale lint).
          set -uo pipefail
          target="''${1:-.}"
          mkdir -p out/security
          rm -f out/security/*.sarif out/security/*.json out/security/summary.md

          echo "🛡️  Security scan orchestrator" >&2
          echo "   Target: $target" >&2
          echo "" >&2

          # --- Step 1: rationale lint (fail fast on malformed allowlists) ---
          echo "→ Rationale lint..." >&2
          lint_missing=0
          for f in "$target/.gitleaksignore" "$target/.semgrepignore" "$target/.trivyignore"; do
            [ -f "$f" ] || continue
            line_num=0
            prev_has_rationale=0
            while IFS= read -r line || [ -n "$line" ]; do
              line_num=$((line_num + 1))
              trimmed="$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
              if [ -z "$trimmed" ]; then
                prev_has_rationale=0
                continue
              fi
              if [[ "$trimmed" == \#* || "$trimmed" == //* ]]; then
                if [[ "$trimmed" == *"rationale:"* ]]; then
                  prev_has_rationale=1
                else
                  prev_has_rationale=0
                fi
                continue
              fi
              if [ "$prev_has_rationale" != "1" ]; then
                echo "   ❌ $f:$line_num: allowlist entry without rationale comment" >&2
                echo "      $line" >&2
                lint_missing=$((lint_missing + 1))
              fi
              prev_has_rationale=0
            done < "$f"
          done
          if [ "$lint_missing" -gt 0 ]; then
            echo "" >&2
            echo "❌ Rationale lint failed: $lint_missing entry/entries missing rationale." >&2
            echo "   Each allowlist entry must be preceded by '# rationale: ...' or '// rationale: ...'" >&2
            exit 1
          fi

          # --- Step 2: scanners ---
          # NOTE: scanner exit codes are intentionally ignored here and
          # reduced to SARIF; the orchestrator decides pass/fail from SARIF
          # counts to keep allowlist handling uniform across scanners.

          echo "→ gitleaks (working tree only, with fixture allowlist)..." >&2
          gl_config="${defaultGitleaksConfig pkgs}"
          [ -f "$target/.gitleaks.toml" ] && gl_config="$target/.gitleaks.toml"
          ${pkgs.gitleaks}/bin/gitleaks detect \
            --source "$target" \
            --config "$gl_config" \
            --no-git \
            --report-format sarif \
            --report-path out/security/gitleaks.sarif \
            --no-banner --redact --exit-code 0 2>&1 | tail -3 >&2 || true

          echo "→ trivy..." >&2
          ${pkgs.trivy}/bin/trivy fs \
            --scanners vuln,secret,misconfig \
            --skip-dirs node_modules,features/fixtures,fixtures,test/fixtures,out,result,.claude,.direnv \
            --format sarif \
            --output out/security/trivy.sarif \
            --exit-code 0 \
            --quiet \
            "$target" 2>&1 | tail -3 >&2 || true

          echo "→ semgrep (p/default + p/owasp-top-ten)..." >&2
          # NOTE: p/* configs fetch from the semgrep registry on first run,
          # then cache. CI has network; local dev caches after first fetch.
          ${pkgs.semgrep}/bin/semgrep scan \
            --config p/default \
            --config p/owasp-top-ten \
            --exclude node_modules --exclude features/fixtures \
            --exclude fixtures --exclude test/fixtures \
            --exclude out --exclude result --exclude .claude --exclude .direnv \
            --sarif --output out/security/semgrep.sarif \
            --no-error --metrics=off --quiet \
            "$target" >&2 || true

          echo "→ syft (SBOM)..." >&2
          ${pkgs.syft}/bin/syft scan "dir:$target" \
            --exclude './node_modules' --exclude './features/fixtures' \
            --exclude './out' --exclude './result' \
            --output cyclonedx-json=out/security/sbom.cdx.json \
            --output spdx-json=out/security/sbom.spdx.json \
            --quiet 2>&1 | tail -3 >&2 || true

          # --- Step 3: count active findings (excludes SARIF-suppressed), summary ---
          # NOTE: SARIF results with .suppressions (e.g. inline `// nosemgrep`
          # or `// gitleaks:allow`) remain in the file so GitHub Code Scanning
          # can dismiss them, but are excluded from the failure count.
          count_sarif() {
            local f="$1"
            [ -f "$f" ] || { echo 0; return; }
            ${pkgs.jq}/bin/jq '[.runs[].results[]? | select(.suppressions == null or (.suppressions | length) == 0)] | length' "$f" 2>/dev/null || echo 0
          }
          g=$(count_sarif out/security/gitleaks.sarif)
          t=$(count_sarif out/security/trivy.sarif)
          s=$(count_sarif out/security/semgrep.sarif)
          total=$((g + t + s))

          {
            echo "## 🛡️ Security scan results"
            echo ""
            echo "| Scanner | Findings | Status |"
            echo "|---|---|---|"
            status_for() { [ "$1" -eq 0 ] && echo "✅" || echo "⚠️"; }
            echo "| gitleaks (secrets) | $g | $(status_for $g) |"
            echo "| trivy (vulns + secrets + misconfig) | $t | $(status_for $t) |"
            echo "| semgrep (SAST) | $s | $(status_for $s) |"
            echo ""
            if [ "$total" -eq 0 ]; then
              echo "All scanners clean. 🎉"
            else
              echo "**$total un-suppressed finding(s).** See the Code Scanning tab for details."
            fi
            echo ""
            if [ -f out/security/sbom.cdx.json ]; then
              pkg_count=$(${pkgs.jq}/bin/jq '.components | length' out/security/sbom.cdx.json 2>/dev/null || echo "?")
              echo "📦 SBOM: $pkg_count packages catalogued (uploaded to Dependency graph)."
            fi
          } > out/security/summary.md

          echo "" >&2
          echo "📄 Reports in out/security/:" >&2
          ls -1 out/security/ | sed 's/^/     /' >&2
          echo "" >&2
          cat out/security/summary.md >&2

          if [ "$total" -gt 0 ]; then
            exit 1
          fi
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
              agen.packages.${pkgs.system}.default
            ];

            shellHook = ''
              # Regenerate CLAUDE.md from agents.yaml and company guidance
              agen >&2
            '';
          };
        }
      );

      # Security scanner app. Invoked by the reusable workflow's optional
      # security-scan job, and runnable locally by developers from any repo:
      #   nix run github:Cambridge-Vision-Technology/ci#security-scan
      # Outputs SARIF + CycloneDX SBOM + markdown summary under ./out/security/.
      apps = forEachSystem (
        { pkgs }:
        {
          security-scan = {
            type = "app";
            program = toString (securityScanScript pkgs);
            meta.description = "Run gitleaks + trivy + semgrep + syft; emit SARIF + SBOM + summary.md";
          };
        }
      );
    };
}
