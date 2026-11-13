module CI.Docs.Test (main) where

import Prelude hiding (identity)

import Build.Output as Build.Output
import CI.Docs.Access as CI.Docs.Access
import CI.Docs.Artifact as CI.Docs.Artifact
import CI.Docs.Json as CI.Docs.Json
import CI.Docs.Publication as CI.Docs.Publication
import Data.Array as Data.Array
import Data.Either as Data.Either
import Data.Foldable as Data.Foldable
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
    Data.Either.Right _ ->
      Effect.Exception.throw ("Expected rejection: " <> message)
    Data.Either.Left error -> do
      CI.Docs.Artifact.ensure (not (Data.String.contains (Data.String.Pattern "CREDENTIAL") (Effect.Exception.message error))) "Credential leaked through an error"
      CI.Docs.Artifact.ensure (Data.String.contains (Data.String.Pattern message) (Effect.Exception.message error)) ("Wrong rejection: " <> Effect.Exception.message error)

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
  waits <- Effect.Ref.new 0
  observations <- Effect.Ref.new []
  probes <- Effect.Ref.new 0
  siteReads <- Effect.Ref.new 0
  states <- Effect.Ref.new
    ( case mode of
        "progress" -> [ "deployment_in_progress", "syncing_files", "finished_file_sync", "updating_pages", "purging_cdn", "succeed" ]
        "retry-progress" -> [ "deployment_attempt_error", "syncing_files", "succeed" ]
        "progress-failure" -> [ "syncing_files", "deployment_content_failed" ]
        "unknown-status" -> [ "unknown-provider-state" ]
        "retry-exhausted" -> [ "deployment_attempt_error" ]
        "deployment-failure" -> [ "deployment_failed" ]
        _ -> [ "succeed" ]
    )
  let
    bootstrap = Data.Array.elem mode [ "bootstrap", "bootstrap-unavailable", "bootstrap-public-access", "bootstrap-host-mismatch" ]
    expectedTarget = if bootstrap then "https://test.pages.github.io/" else "https://test.example/"
    siteUrl = if bootstrap then "http://test.pages.github.io/" else expectedTarget
    get path
      | path == "repos/TEST/docs" = pure "{\"default_branch\":\"main\"}"
      | path == "repos/TEST/docs/pages" =
          if mode == "missing-site" then Effect.Exception.throw "Injected HTTP 404 from Pages"
          else do
            reads <- Effect.Ref.read siteReads
            Effect.Ref.modify_ (_ + 1) siteReads
            pure ("{\"public\":" <> (if mode == "public-site" || (mode == "site-changed" && reads > 0) then "true" else "false") <> ",\"build_type\":\"workflow\",\"html_url\":\"" <> (if mode == "site-url-changed" && reads > 0 then "https://other.example/" else siteUrl) <> "\"}")
      | path == "repos/TEST/docs/pages/deployments/returned-id" = do
          remaining <- Effect.Ref.read states
          case Data.Array.uncons remaining of
            Data.Maybe.Just { head, tail } -> do
              Effect.Ref.write (if Data.Array.null tail then [ head ] else tail) states
              pure ("{\"status\":\"" <> head <> "\"}")
            Data.Maybe.Nothing ->
              Effect.Exception.throw "Unexpected status read"
      | otherwise = Effect.Exception.throw ("Unexpected TEST request: " <> path)
    probe url = do
      CI.Docs.Artifact.ensure (url == expectedTarget) "Wrong TEST access probe target; HTTP or a different site must never be probed"
      count <- Effect.Ref.read probes
      Effect.Ref.modify_ (_ + 1) probes
      if mode == "unavailable" || mode == "bootstrap-unavailable" then Effect.Exception.throw "Unavailable private access"
      else if mode == "bootstrap" || mode == "auth-handoff" then
        Node.Process.lookupEnv "DOCS_TEST_PRIVATE_RESPONSE" >>= Data.Maybe.maybe (Effect.Exception.throw "Missing captured private response") Platform.Node.Build.readImpl
      else pure (if Data.Array.elem mode [ "public-access", "bootstrap-public-access" ] || (mode == "post-public-access" && count > 0) then "HTTP/2 200\r\n" else if mode == "spoof-access" then "HTTP/2 302\r\nlocation: https://github.com/login.evil\r\n" else "HTTP/2 302\r\nlocation: https://github.com/login?return_to=TEST\r\n")
    client =
      { get
      , probe
      , create: \actual artifactId -> do
          CI.Docs.Artifact.ensure (actual == identity && artifactId == 9876543210.0) "Wrong Pages creation request identity/artifact"
          Effect.Ref.modify_ (_ + 1) calls
          if mode == "creation-failure" then Effect.Exception.throw "Injected Pages creation failure"
          else pure { status_url: "https://api.github.com/repos/TEST/docs/pages/deployments/returned-id", page_url: if mode == "verification-failure" then "https://wrong.example/" else if mode == "bootstrap-host-mismatch" then "http://other.pages.github.io/" else siteUrl }
      , record: \deployment _ -> do
          CI.Docs.Artifact.ensure (deployment == "returned-id") "Assumed deployment identity rather than returned identity"
          Effect.Ref.modify_ (_ + 1) recorded
          when (mode == "recording-failure") (Effect.Exception.throw "Injected evidence recording failure")
      , wait: Effect.Ref.modify_ (_ + 1) waits
      , observed: \status -> Effect.Ref.modify_ (_ <> [ status ]) observations
      , verified: Effect.Ref.modify_ (_ + 1) successful
      }
    accepted = CI.Docs.Publication.publishWith client "push" "refs/heads/main" root "9876543210" identity
  case mode of
    "bootstrap" ->
      accepted
    "auth-handoff" ->
      accepted
    "bootstrap-unavailable" ->
      reject "Unavailable private access" accepted
    "bootstrap-public-access" ->
      reject "Private access verification unavailable" accepted
    "post-public-access" ->
      reject "Private access verification unavailable" accepted
    "site-changed" ->
      reject "Private Pages setup blocker" accepted
    "site-url-changed" ->
      reject "differs from associated" accepted
    "recording-failure" ->
      reject "Injected evidence recording failure" accepted
    "bootstrap-host-mismatch" ->
      reject "differs from associated" accepted
    "mechanism" ->
      accepted
    "progress" ->
      accepted
    "retry-progress" ->
      accepted
    "progress-failure" ->
      reject "deployment failed or unknown" accepted
    "unknown-status" ->
      reject "deployment failed or unknown" accepted
    "retry-exhausted" ->
      reject "verification deadline reached" accepted
    "denial-protocol" -> do
      CI.Docs.Artifact.ensure (CI.Docs.Publication.accessDenied "HTTP/2 302\r\nlocation: https://github.com/login?return_to=TEST\r\n\r\n") "CRLF authentication redirect was not recognized"
      CI.Docs.Artifact.ensure (CI.Docs.Publication.accessDenied "HTTP/1.1 200 Connection established\r\n\r\nHTTP/2 302\r\nlocation: https://github.com/login?return_to=TEST\r\n\r\n") "Proxy prelude hid the final authentication redirect"
      CI.Docs.Artifact.ensure (not (CI.Docs.Publication.accessDenied "HTTP/2 302\r\nlocation: https://github.com/login?return_to=TEST\r\n\r\nHTTP/2 200\r\n\r\n")) "An earlier redirect concealed a final public response"
      CI.Docs.Artifact.ensure (not (CI.Docs.Publication.accessDenied "HTTP/2 302\r\nlocation: https://github.com/login.evil\r\n\r\n")) "Lookalike authentication path was accepted"
      captured <- Node.Process.lookupEnv "DOCS_TEST_PRIVATE_RESPONSE" >>= Data.Maybe.maybe (Effect.Exception.throw "Missing captured private response") Platform.Node.Build.readImpl
      CI.Docs.Artifact.ensure (CI.Docs.Publication.accessDenied captured) "Captured private Pages authentication handoff was not recognized"
      Data.Foldable.for_
        [ Data.String.replaceAll (Data.String.Pattern "HTTP/2 302") (Data.String.Replacement "HTTP/2 200") captured
        , Data.String.replaceAll (Data.String.Pattern "https://github.com/") (Data.String.Replacement "https://github.com.evil/") captured
        , Data.String.replaceAll (Data.String.Pattern "/pages/auth?") (Data.String.Replacement "/pages/auth/evil?") captured
        , Data.String.replaceAll (Data.String.Pattern "x-pages-private: 1\n") (Data.String.Replacement "") captured
        , Data.String.replaceAll (Data.String.Pattern "x-pages-private: 1") (Data.String.Replacement "x-pages-private: 0") captured
        , Data.String.replaceAll (Data.String.Pattern "x-pages-private: 1") (Data.String.Replacement "x-pages-private: 1\nx-pages-private: 1") captured
        , captured <> "location: https://github.com/login?return_to=TEST\n"
        ]
        (\response -> CI.Docs.Artifact.ensure (not (CI.Docs.Publication.accessDenied response)) "Synthetic public/spoofed/ambiguous private-auth response was accepted")
    "url-protocol" -> do
      Data.Foldable.for_
        [ "http://test.pages.github.io/", "https://test.pages.github.io/", "https://TEST.pages.github.io" ]
        ( \input -> do
            target <- Data.Either.either Effect.Exception.throw pure (CI.Docs.Access.fromPagesUrl input)
            CI.Docs.Artifact.ensure (CI.Docs.Access.url target == "https://test.pages.github.io/") "Unexpected HTTPS target normalization"
        )
      Data.Foldable.for_
        [ "http://test.example/"
        , "http://pages.github.io/"
        , "http://test.pages.github.io.evil/"
        , "http://test.pages.github.io@evil.example/"
        , "https://user:password@test.pages.github.io/"
        , "https://test.pages.github.io:80/"
        , "https://test.pages.github.io\\@evil.example/"
        , "https://test.pages.github.io/?override=evil"
        , "https://test.pages.github.io/#fragment"
        , "https://test.pages.github.io/\n"
        , "https:///"
        , "https://.pages.github.io/"
        , "//test.pages.github.io/"
        , "ftp://test.pages.github.io/"
        ]
        (\input -> CI.Docs.Artifact.ensure (Data.Either.isLeft (CI.Docs.Access.fromPagesUrl input)) "Unsafe or unrelated Pages metadata URL was accepted")
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
  pauses <- Effect.Ref.read waits
  seen <- Effect.Ref.read observations
  let
    creationExpected = Data.Array.elem mode [ "bootstrap", "auth-handoff", "post-public-access", "site-changed", "site-url-changed", "recording-failure", "bootstrap-host-mismatch", "mechanism", "progress", "retry-progress", "progress-failure", "unknown-status", "retry-exhausted", "creation-failure", "deployment-failure", "verification-failure" ]
    expectedWaits = case mode of
      "progress" -> 5
      "retry-progress" -> 2
      "progress-failure" -> 1
      "retry-exhausted" -> 100
      _ -> 0
  CI.Docs.Artifact.ensure (requests == (if creationExpected then 1 else 0)) "Rejected publication unexpectedly created a deployment or skipped its expected creation"
  CI.Docs.Artifact.ensure (records == (if creationExpected && mode /= "creation-failure" then 1 else 0)) "Wrong deployment evidence multiplicity"
  CI.Docs.Artifact.ensure (successes == (if Data.Array.elem mode [ "bootstrap", "auth-handoff", "mechanism", "progress", "retry-progress" ] then 1 else 0)) "Wrong verified-deployment claim for the modeled state"
  probeCount <- Effect.Ref.read probes
  when (Data.Array.elem mode [ "bootstrap", "auth-handoff", "post-public-access", "mechanism", "progress", "retry-progress" ]) (CI.Docs.Artifact.ensure (probeCount == 2) "HTTPS access must be verified before creation and after completion")
  when (Data.Array.elem mode [ "bootstrap-unavailable", "bootstrap-public-access", "public-access", "unavailable", "spoof-access", "site-changed", "site-url-changed", "bootstrap-host-mismatch", "verification-failure" ]) (CI.Docs.Artifact.ensure (probeCount == 1) "Unsafe access or changed site did not stop at its expected boundary")
  CI.Docs.Artifact.ensure (pauses == expectedWaits) "Wrong polling multiplicity"
  when (mode == "progress") (CI.Docs.Artifact.ensure (seen == [ "deployment_in_progress", "syncing_files", "finished_file_sync", "updating_pages", "purging_cdn", "succeed", "succeed" ]) "Incomplete documented progress lifecycle")
  when (mode == "retry-progress") (CI.Docs.Artifact.ensure (seen == [ "deployment_attempt_error", "syncing_files", "succeed", "succeed" ]) "Retryable status did not recover without recreating")
  when (mode == "progress-failure") (CI.Docs.Artifact.ensure (seen == [ "syncing_files", "deployment_content_failed" ]) "Terminal failure after progress was not observed")
  when (mode == "unknown-status") (CI.Docs.Artifact.ensure (seen == [ "unknown-provider-state" ]) "Unknown status was retried or lost")
  when (mode == "retry-exhausted") (CI.Docs.Artifact.ensure (Data.Array.length seen == 100 && Data.Array.last seen == Data.Maybe.Just "deployment_attempt_error") "Bounded retry did not retain its last observed state")

transport :: String -> Effect.Effect Unit
transport root = do
  Node.Process.setEnv "DOCS_TRANSPORT_TEST_ROOT" root
  Node.Process.setEnv "DOCS_TRANSPORT_FAILURE" ""
  Node.Process.setEnv "ACTIONS_ID_TOKEN_REQUEST_URL" "https://token.TEST.invalid/oidc"
  Node.Process.setEnv "ACTIONS_ID_TOKEN_REQUEST_TOKEN" "TEST-REQUEST-CREDENTIAL"
  Node.Process.setEnv "RUNNER_TEMP" root
  Node.Process.setEnv "GITHUB_OUTPUT" (root <> "/output")
  Node.Process.setEnv "GITHUB_REPOSITORY" "TEST/docs"
  Node.Process.setEnv "GITHUB_SHA" "test-revision"
  Node.Process.setEnv "GITHUB_RUN_ID" "1"
  Node.Process.setEnv "GITHUB_RUN_ATTEMPT" "1"
  Node.Process.setEnv "DOCS_PRODUCER_ARTIFACT_ID" "12345"
  Platform.Node.Build.writeImpl (root <> "/binding.json") ""
  Platform.Node.Build.writeImpl (root <> "/output") ""
  response <- CI.Docs.Publication.probeAccess "https://test.pages.github.io/"
  CI.Docs.Artifact.ensure (CI.Docs.Publication.accessDenied response) "Production TLS probe did not preserve captured private authentication response"
  Node.Process.setEnv "DOCS_TRANSPORT_FAILURE" "probe"
  reject "Command failed" (void (CI.Docs.Publication.probeAccess "https://test.pages.github.io/"))
  Node.Process.setEnv "DOCS_TRANSPORT_FAILURE" ""
  creation <- Effect.Exception.try (CI.Docs.Publication.create (identityFor "synthetic-system") 9876543210.0)
  created <- case creation of
    Data.Either.Left error -> do
      diagnostic <- Platform.Node.Build.existsImpl (root <> "/transport.error")
      if diagnostic then Platform.Node.Build.readImpl (root <> "/transport.error") >>= Effect.Exception.throw
      else Effect.Exception.throwException error
    Data.Either.Right value ->
      pure value
  CI.Docs.Artifact.ensure (created.status_url == "https://api.github.com/repos/TEST/docs/pages/deployments/returned-id" && created.page_url == "https://test.example/") "Production adapter did not decode the returned deployment identity"
  CI.Docs.Publication.record root "9876543210" "returned-id" created.page_url
  initial <- Platform.Node.Build.readImpl (root <> "/private-pages-deployment.json") >>= CI.Docs.Artifact.parse :: Effect.Effect CI.Docs.Json.DeploymentEvidence
  CI.Docs.Artifact.ensure (initial.deployment == "returned-id" && initial.producerArtifact == "12345" && initial.pagesArtifact == "9876543210" && initial.bindingDigest == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" && initial.lastStatus == "created") "Incomplete retained deployment provenance"
  CI.Docs.Publication.observed "deployment_content_failed"
  failed <- Platform.Node.Build.readImpl (root <> "/private-pages-deployment.json") >>= CI.Docs.Artifact.parse :: Effect.Effect CI.Docs.Json.DeploymentEvidence
  CI.Docs.Artifact.ensure (failed.lastStatus == "deployment_content_failed" && failed.status == "created-not-yet-verified") "Failed status was not retained without a success claim"
  CI.Docs.Publication.observed "succeed"
  CI.Docs.Publication.verified
  finalText <- Platform.Node.Build.readImpl (root <> "/private-pages-deployment.json")
  final <- CI.Docs.Artifact.parse finalText :: Effect.Effect CI.Docs.Json.DeploymentEvidence
  CI.Docs.Artifact.ensure (final.status == "succeed" && final.lastStatus == "succeed" && final.privateAccess == "denied") "Verified adapter did not update retained evidence"
  output <- Platform.Node.Build.readImpl (root <> "/output")
  CI.Docs.Artifact.ensure (output == "deployment_id=returned-id\npage_url=https://test.example/\n" && not (Data.String.contains (Data.String.Pattern "CREDENTIAL") (output <> finalText))) "Unsafe or incorrect production evidence/output adapter"
  Platform.Node.Build.writeImpl (root <> "/output") ""
  CI.Docs.Publication.record root "9876543210" "returned-id" "http://test.pages.github.io/"
  bootstrapEvidence <- Platform.Node.Build.readImpl (root <> "/private-pages-deployment.json") >>= CI.Docs.Artifact.parse :: Effect.Effect CI.Docs.Json.DeploymentEvidence
  bootstrapOutput <- Platform.Node.Build.readImpl (root <> "/output")
  CI.Docs.Artifact.ensure (bootstrapEvidence.url == "http://test.pages.github.io/" && bootstrapOutput == "deployment_id=returned-id\npage_url=https://test.pages.github.io/\n") "Raw returned URL was lost or the environment link was not HTTPS"
  probeCalls <- Platform.Node.Build.readImpl (root <> "/probe.calls")
  CI.Docs.Artifact.ensure (probeCalls == "call\ncall\n") "Production HTTPS probe multiplicity changed"
  Node.Process.setEnv "DOCS_TRANSPORT_FAILURE" "oidc"
  reject "Pages OIDC response invalid" (void (CI.Docs.Publication.create (identityFor "synthetic-system") 9876543210.0))
  postsBeforeFailure <- Platform.Node.Build.readImpl (root <> "/post.calls")
  CI.Docs.Artifact.ensure (postsBeforeFailure == "call\n") "Invalid OIDC response reached creation"
  Node.Process.setEnv "DOCS_TRANSPORT_FAILURE" "post"
  reject "creation failed or uncertain" (void (CI.Docs.Publication.create (identityFor "synthetic-system") 9876543210.0))
  posts <- Platform.Node.Build.readImpl (root <> "/post.calls")
  requests <- Platform.Node.Build.readImpl (root <> "/curl.calls")
  CI.Docs.Artifact.ensure (posts == "call\ncall\n" && requests == "call\ncall\ncall\n") "Production transport repeated or omitted a request"

main :: Effect.Effect Unit
main = do
  started <- Effect.Now.now
  args <- Data.Array.drop 2 <$> Node.Process.argv
  root <- Platform.Node.Documents.temporaryRootImpl >>= \temp -> Platform.Node.Documents.temporaryDirectoryImpl (temp <> "/ci-docs-TEST-")
  result <- Effect.Exception.try case args of
    [ "generation", tool, fixture, mode, output ] -> generation (root <> "/consumer") tool fixture mode *> pure { output, label: mode <> " generation passed" }
    [ "publication", "transport", output ] -> transport root *> pure { output, label: "Synthetic local production transport/evidence adapter check passed; no provider-origin or hosted evidence" }
    [ "publication", mode, output ] -> publication root mode *> pure { output, label: mode <> " synthetic component check passed; no provider-origin or hosted deployment evidence" }
    _ -> Effect.Exception.throw "Expected test case"
  Platform.Node.Build.executeImpl "chmod" [ "-R", "u+w", root ] "."
  Platform.Node.Documents.removeDirectoryImpl root
  ended <- Effect.Now.now
  case result of
    Data.Either.Left error -> Build.Output.writeLine Node.Process.stderr (Effect.Exception.message error) (Node.Process.exit' 1)
    Data.Either.Right value -> Platform.Node.Build.writeImpl value.output (value.label <> "\nexpanded-cases=1\nelapsed-including-setup-cleanup=" <> show (Data.DateTime.Instant.diff ended started :: Data.Time.Duration.Milliseconds) <> "\n")
