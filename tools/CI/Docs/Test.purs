module CI.Docs.Test (main) where

import Prelude hiding (identity)

import Build.Output as Build.Output
import CI.Docs.Artifact as CI.Docs.Artifact
import CI.Docs.Json as CI.Docs.Json
import CI.Docs.Publication as CI.Docs.Publication
import Data.Array as Data.Array
import Data.Either as Data.Either
import Data.DateTime.Instant as Data.DateTime.Instant
import Data.Time.Duration as Data.Time.Duration
import Data.Maybe as Data.Maybe
import Data.Nullable as Data.Nullable
import Data.String as Data.String
import Effect as Effect
import Effect.Exception as Effect.Exception
import Effect.Ref as Effect.Ref
import Effect.Now as Effect.Now
import Effect.Uncurried as Effect.Uncurried
import Node.Process as Node.Process
import Node.Path as Node.Path
import Platform.Node.Build as Platform.Node.Build
import Platform.Node.Documents as Platform.Node.Documents
import Platform.Node.System as Platform.Node.System

identityFor :: String -> CI.Docs.Json.Binding
identityFor system = { repository: "TEST/docs", revision: "test-revision", run: "1", attempt: "1", workflowRepository: "TEST/ci", workflowRevision: "ci-revision", system }

reject :: String -> Effect.Effect Unit -> Effect.Effect Unit
reject message action = do
  result <- Effect.Exception.try action
  case result of
    Data.Either.Right _ -> Effect.Exception.throw ("Expected rejection: " <> message)
    Data.Either.Left error -> CI.Docs.Artifact.ensure (Data.String.contains (Data.String.Pattern message) (Effect.Exception.message error)) ("Wrong rejection: " <> Effect.Exception.message error)

generation :: String -> String -> String -> String -> Effect.Effect Unit
generation root tool fixture mode = do
  system <- Node.Process.lookupEnv "DOCS_TEST_SYSTEM" >>= Data.Maybe.maybe (Effect.Exception.throw "Missing DOCS_TEST_SYSTEM") pure
  Platform.Node.Build.mkdirImpl root
  Node.Process.setEnv "NIX_REMOTE" "local"
  Node.Process.setEnv "NIX_STORE_DIR" (Node.Path.dirname root <> "/nix-store")
  Node.Process.setEnv "NIX_STATE_DIR" (Node.Path.dirname root <> "/nix-state")
  Node.Process.setEnv "NIX_LOG_DIR" (Node.Path.dirname root <> "/nix-log")
  Node.Process.setEnv "NIX_CONF_DIR" (Node.Path.dirname root <> "/nix-config")
  Node.Process.setEnv "XDG_CACHE_HOME" (Node.Path.dirname root <> "/cache")
  Node.Process.setEnv "NIX_CONFIG" "experimental-features = nix-command flakes\nbuild-users-group =\nsubstituters =\n"
  storedFixture <- Data.String.trim <$> CI.Docs.Artifact.text "nix-store" [ "--add", fixture ]
  let
    identity = identityFor system
    absent = Data.Array.elem mode [ "absent", "stale-absent" ]
    app = "{ apps." <> system <> ".docs = { type = \"app\"; program = \"" <> storedFixture <> "\"; }; }"
    flake =
      if mode == "evaluation" then "{ outputs = _: throw \"Deliberate flake evaluation failure\"; }"
      else "{ outputs = _: " <> (if mode == "stale-absent" then "if builtins.pathExists ./.out/docs then " <> app <> " else {}" else if absent then "{}" else app) <> "; }"
  Platform.Node.Build.writeImpl (root <> "/flake.nix") flake
  Platform.Node.Build.writeImpl (root <> "/output") ""
  when (mode /= "absent") do
    Platform.Node.Build.mkdirImpl (root <> "/.out/docs")
    Platform.Node.Build.writeImpl (root <> "/.out/docs/index.html") "<html>STALE</html>"
  Node.Process.setEnv "GITHUB_REPOSITORY" identity.repository
  Node.Process.setEnv "GITHUB_WORKSPACE" (Node.Path.dirname root)
  Node.Process.setEnv "GITHUB_SHA" identity.revision
  Node.Process.setEnv "GITHUB_RUN_ID" identity.run
  Node.Process.setEnv "GITHUB_RUN_ATTEMPT" identity.attempt
  Node.Process.setEnv "DOCS_WORKFLOW_REPOSITORY" identity.workflowRepository
  Node.Process.setEnv "DOCS_WORKFLOW_SHA" identity.workflowRevision
  Node.Process.setEnv "DOCS_SYSTEM" identity.system
  Node.Process.setEnv "RUNNER_TEMP" root
  Node.Process.setEnv "GITHUB_OUTPUT" (root <> "/output")
  Node.Process.setEnv "GIT_CONFIG_GLOBAL" "/dev/null"
  Node.Process.setEnv "GIT_CONFIG_SYSTEM" "/dev/null"
  Platform.Node.Build.executeImpl "git" [ "init", "--quiet", "--initial-branch=TEST" ] (Node.Path.dirname root)
  Platform.Node.Build.executeImpl "git" [ "add", "consumer/flake.nix" ] (Node.Path.dirname root)
  environment <- Node.Process.getEnv
  result <- Effect.Uncurried.runEffectFn3 Platform.Node.System.executeWithImpl tool [ "generate", root ]
    { encoding: "utf8", timeout: 50000, maxBuffer: 1048576, killSignal: "SIGTERM", input: "", cwd: root, env: environment }
  output <- Platform.Node.Build.readImpl (root <> "/output")
  let
    success = mode == "success" || absent
  CI.Docs.Artifact.ensure ((Data.Nullable.toMaybe result.status == Data.Maybe.Just 0) == success)
    ("Unexpected generator status for " <> mode <> ": " <> Data.Maybe.fromMaybe "" (Data.Nullable.toMaybe result.stderr))
  CI.Docs.Artifact.ensure (Data.String.contains (Data.String.Pattern ("present=" <> if mode == "success" then "true" else "false")) output || mode == "evaluation") ("Wrong eligibility output: " <> Data.Maybe.fromMaybe "" (Data.Nullable.toMaybe result.stderr))
  if mode == "success" then do
    html <- Platform.Node.Build.readImpl (root <> "/.out/docs/index.html")
    CI.Docs.Artifact.ensure (Data.String.contains (Data.String.Pattern "Current TEST developer journey") html && not (Data.String.contains (Data.String.Pattern "STALE") html)) "Generator did not replace stale content"
    case Data.Array.mapMaybe (Data.String.stripPrefix (Data.String.Pattern "bundle=")) (Data.String.split (Data.String.Pattern "\n") output) of
      [ bundle ] -> CI.Docs.Artifact.verify bundle identity
      _ -> Effect.Exception.throw "Successful generator did not retain exactly one bound artifact"
  else if absent then do
    CI.Docs.Artifact.ensure (not (Data.String.contains (Data.String.Pattern "bundle=") output)) "Absent app retained a publication artifact"
    if mode == "stale-absent" then do
      html <- Platform.Node.Build.readImpl (root <> "/.out/docs/index.html")
      CI.Docs.Artifact.ensure (html == "<html>STALE</html>") "Absent app ran generation or changed stale output"
    else do
      exists <- Platform.Node.Build.existsImpl (root <> "/.out/docs")
      CI.Docs.Artifact.ensure (not exists) "Absent app generated documentation"
  else unless absent do
    CI.Docs.Artifact.ensure (not (Data.String.contains (Data.String.Pattern "present=true") output)) "Failed generator authorized publication"
    let
      expected = case mode of
        "failure" -> "Deliberate generator failure"
        "missing" -> "ENOENT"
        "empty" -> "Documentation output is empty"
        "invalid" -> "not a usable HTML page"
        "empty-index" -> "not a usable HTML page"
        "link" -> "Unsafe artifact entry"
        "hardlink" -> "Hard links are not publishable"
        "special" -> "Unsafe artifact entry"
        "evaluation" -> "Deliberate flake evaluation failure"
        _ -> "Unknown case"
    CI.Docs.Artifact.ensure (Data.String.contains (Data.String.Pattern expected) (Data.Maybe.fromMaybe "" (Data.Nullable.toMaybe result.stderr))) ("Wrong failure for " <> mode <> ": " <> Data.Maybe.fromMaybe "" (Data.Nullable.toMaybe result.stderr))
    unless (mode == "evaluation") do
      exists <- Platform.Node.Build.existsImpl (root <> "/.out/docs")
      CI.Docs.Artifact.ensure (not exists) "Failed generation retained stale/partial output"

publication :: String -> String -> Effect.Effect Unit
publication root mode = do
  let
    identity = identityFor "synthetic-system"
  Platform.Node.Build.mkdirImpl (root <> "/site")
  Platform.Node.Build.executeImpl "fixture-success" [] root
  Platform.Node.Build.copyImpl (root <> "/.out/docs/index.html") (root <> "/site/index.html")
  entries <- CI.Docs.Artifact.validate (root <> "/site")
  CI.Docs.Artifact.writeBinding (root <> "/binding.json") identity entries
  calls <- Effect.Ref.new 0
  recorded <- Effect.Ref.new 0
  successful <- Effect.Ref.new 0
  let
    get path
      | path == "repos/TEST/docs" = pure "{\"default_branch\":\"main\"}"
      | path == "repos/TEST/docs/pages" =
          if mode == "missing-site" then Effect.Exception.throw "Injected HTTP 404 from Pages"
          else pure ("{\"public\":" <> (if mode == "public-site" then "true" else "false") <> ",\"build_type\":\"workflow\",\"html_url\":\"https://test.example/\"}")
      | path == "repos/TEST/docs/pages/deployments/returned-id" = pure ("{\"status\":\"" <> (if mode == "deployment-failure" then "deployment_failed" else "succeed") <> "\"}")
      | otherwise = Effect.Exception.throw ("Unexpected TEST request: " <> path)
    probe url = do
      CI.Docs.Artifact.ensure (url == "https://test.example/") "Wrong TEST access probe target"
      if mode == "unavailable" then Effect.Exception.throw "Unavailable private access"
      else pure (if mode == "public-access" then "HTTP/2 200\r\n" else if mode == "spoof-access" then "HTTP/2 302\r\nlocation: https://github.com/login.evil\r\n" else "HTTP/2 302\r\nlocation: https://github.com/login?return_to=TEST\r\n")
    client =
      { get
      , probe
      , create: \actual artifactId -> do
          CI.Docs.Artifact.ensure (actual == identity && artifactId == 9876543210.0) "Wrong Pages creation request identity/artifact"
          Effect.Ref.modify_ (_ + 1) calls
          if mode == "creation-failure" then Effect.Exception.throw "Injected Pages creation failure"
          else pure { status_url: "https://api.github.com/repos/TEST/docs/pages/deployments/returned-id", page_url: if mode == "verification-failure" then "https://wrong.example/" else "https://test.example/" }
      , record: \deployment _ -> do
          CI.Docs.Artifact.ensure (deployment == "returned-id") "Assumed deployment identity rather than returned identity"
          Effect.Ref.modify_ (_ + 1) recorded
      , wait: Effect.Exception.throw "Unexpected TEST polling delay"
      , verified: Effect.Ref.modify_ (_ + 1) successful
      }
    accepted = CI.Docs.Publication.publishWith client "push" "refs/heads/main" root "9876543210" identity
  case mode of
    "mechanism" ->
      accepted
    "denial-protocol" -> do
      CI.Docs.Artifact.ensure (CI.Docs.Publication.accessDenied "HTTP/2 302\r\nlocation: https://github.com/login?return_to=TEST\r\n\r\n") "CRLF authentication redirect was not recognized"
      CI.Docs.Artifact.ensure (CI.Docs.Publication.accessDenied "HTTP/1.1 200 Connection established\r\n\r\nHTTP/2 302\r\nlocation: https://github.com/login?return_to=TEST\r\n\r\n") "Proxy prelude hid the final authentication redirect"
      CI.Docs.Artifact.ensure (not (CI.Docs.Publication.accessDenied "HTTP/2 302\r\nlocation: https://github.com/login?return_to=TEST\r\n\r\nHTTP/2 200\r\n\r\n")) "An earlier redirect concealed a final public response"
      CI.Docs.Artifact.ensure (not (CI.Docs.Publication.accessDenied "HTTP/2 302\r\nlocation: https://github.com/login.evil\r\n\r\n")) "Lookalike authentication path was accepted"
    "pr" ->
      reject "only a default-branch" (CI.Docs.Publication.publishWith client "pull_request" "refs/pull/1/merge" root "9876543210" identity)
    "repository" ->
      reject "binding mismatch" (CI.Docs.Publication.publishWith client "push" "refs/heads/main" root "9876543210" (identity { repository = "TEST/other" }))
    "revision" ->
      reject "binding mismatch" (CI.Docs.Publication.publishWith client "push" "refs/heads/main" root "9876543210" (identity { revision = "wrong" }))
    "run" ->
      reject "binding mismatch" (CI.Docs.Publication.publishWith client "push" "refs/heads/main" root "9876543210" (identity { run = "2" }))
    "workflow" ->
      reject "binding mismatch" (CI.Docs.Publication.publishWith client "push" "refs/heads/main" root "9876543210" (identity { workflowRevision = "wrong" }))
    "digest" -> do
      Platform.Node.Build.writeImpl (root <> "/site/index.html") "<html><body>wrong artifact</body></html>"
      reject "digest mismatch" accepted
    "missing-site" ->
      reject "Private Pages setup blocker" accepted
    "public-site" ->
      reject "Private Pages setup blocker" accepted
    "creation-failure" ->
      reject "Injected Pages creation failure" accepted
    "unavailable" ->
      reject "Unavailable private access" accepted
    "public-access" ->
      reject "Private access verification unavailable" accepted
    "spoof-access" ->
      reject "Private access verification unavailable" accepted
    "deployment-failure" ->
      reject "deployment failed or unknown" accepted
    "verification-failure" ->
      reject "differs from associated" accepted
    _ ->
      Effect.Exception.throw "Unknown publication case"
  requests <- Effect.Ref.read calls
  records <- Effect.Ref.read recorded
  successes <- Effect.Ref.read successful
  let
    creationExpected = Data.Array.elem mode [ "mechanism", "creation-failure", "unavailable", "public-access", "spoof-access", "deployment-failure", "verification-failure" ]
  CI.Docs.Artifact.ensure (requests == (if creationExpected then 1 else 0)) "Rejected publication unexpectedly created a deployment or skipped its expected creation"
  CI.Docs.Artifact.ensure (records == (if creationExpected && mode /= "creation-failure" then 1 else 0)) "Wrong deployment evidence multiplicity"
  CI.Docs.Artifact.ensure (successes == (if mode == "mechanism" then 1 else 0)) "Wrong verified-deployment claim for the modeled state"

main :: Effect.Effect Unit
main = do
  started <- Effect.Now.now
  args <- Data.Array.drop 2 <$> Node.Process.argv
  root <- Platform.Node.Documents.temporaryRootImpl >>= \temp -> Platform.Node.Documents.temporaryDirectoryImpl (temp <> "/ci-docs-TEST-")
  result <- Effect.Exception.try case args of
    [ "generation", tool, fixture, mode, output ] -> generation (root <> "/consumer") tool fixture mode *> pure { output, label: mode <> " generation passed" }
    [ "publication", mode, output ] -> publication root mode *> pure { output, label: mode <> " synthetic component check passed; no provider-origin or hosted deployment evidence" }
    _ -> Effect.Exception.throw "Expected test case"
  Platform.Node.Build.executeImpl "chmod" [ "-R", "u+w", root ] "."
  Platform.Node.Documents.removeDirectoryImpl root
  ended <- Effect.Now.now
  case result of
    Data.Either.Left error -> Build.Output.writeLine Node.Process.stderr (Effect.Exception.message error) (Node.Process.exit' 1)
    Data.Either.Right value -> Platform.Node.Build.writeImpl value.output (value.label <> "\nexpanded-cases=1\nelapsed-including-setup-cleanup=" <> show (Data.DateTime.Instant.diff ended started :: Data.Time.Duration.Milliseconds) <> "\n")
