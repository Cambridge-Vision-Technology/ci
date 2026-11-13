module CI.Docs.Publication where

import Prelude

import Build.Output as Build.Output
import CI.Docs.Access as CI.Docs.Access
import CI.Docs.Artifact as CI.Docs.Artifact
import CI.Docs.Json as CI.Docs.Json
import Data.Argonaut.Core as Data.Argonaut.Core
import Data.Argonaut.Encode as Data.Argonaut.Encode
import Data.Either as Data.Either
import Data.Nullable as Data.Nullable
import Data.Number as Data.Number
import Data.Array as Data.Array
import Data.Maybe as Data.Maybe
import Data.String as Data.String
import Data.String.CodeUnits as Data.String.CodeUnits
import Effect as Effect
import Effect.Exception as Effect.Exception
import Effect.Uncurried as Effect.Uncurried
import Node.Process as Node.Process
import Platform.Node.System as Platform.Node.System
import Platform.Node.Build as Platform.Node.Build

type Repository = { default_branch :: String }
type Site = { public :: Boolean, build_type :: String, html_url :: String }
type Deployment = { status :: String }
type Created = { id :: CI.Docs.Json.PagesDeploymentIdJson, status_url :: String, page_url :: String }
type Oidc = { value :: String }

validateDeploymentId :: String -> Effect.Effect String
validateDeploymentId value = do
  CI.Docs.Artifact.ensure (value /= "" && value /= "." && value /= ".." && Data.Array.all (\c -> (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || Data.Array.elem c [ '-', '_', '.', '~' ]) (Data.String.CodeUnits.toCharArray value)) "Invalid Pages deployment ID"
  pure value

returnedDeploymentId :: CI.Docs.Json.PagesDeploymentIdJson -> Effect.Effect String
returnedDeploymentId value = case value of
  CI.Docs.Json.StringPagesDeploymentIdJson text ->
    validateDeploymentId text
  CI.Docs.Json.NumberPagesDeploymentIdJson number -> do
    let
      text = Data.Argonaut.Core.stringify (Data.Argonaut.Core.fromNumber number)
    CI.Docs.Artifact.ensure (number > 0.0 && number <= 9007199254740991.0 && Data.Array.all (\c -> c >= '0' && c <= '9') (Data.String.CodeUnits.toCharArray text)) "Invalid Pages deployment ID"
    validateDeploymentId text

getApi :: String -> Effect.Effect String
getApi path = CI.Docs.Artifact.text "gh" [ "api", "--method", "GET", "-H", "Accept: application/vnd.github+json", "-H", "X-GitHub-Api-Version: 2022-11-28", path ]

required :: String -> Effect.Effect String
required name = Node.Process.lookupEnv name >>= Data.Maybe.maybe (Effect.Exception.throw ("Missing " <> name)) pure

privateSiteWith :: (String -> Effect.Effect String) -> CI.Docs.Json.Binding -> Effect.Effect CI.Docs.Access.HttpsTarget
privateSiteWith get identity = do
  observed <- Effect.Exception.try (get ("repos/" <> identity.repository <> "/pages") >>= CI.Docs.Artifact.parse :: Effect.Effect Site)
  site <- Data.Either.either (\_ -> Effect.Exception.throw "Private Pages setup blocker: cannot read or validate the associated site; check private hosting capability and repository-scoped Pages authority") pure observed
  CI.Docs.Artifact.ensure (not site.public && site.build_type == "workflow") "Private Pages setup blocker: require an existing workflow-built private site; never fall back to public Pages"
  Data.Either.either Effect.Exception.throw pure (CI.Docs.Access.fromPagesUrl site.html_url)

preflight :: String -> CI.Docs.Json.Binding -> Effect.Effect Unit
preflight bundle identity = do
  event <- required "GITHUB_EVENT_NAME"
  ref <- required "GITHUB_REF"
  void (preflightWith getApi probeAccess event ref bundle identity)

preflightWith :: (String -> Effect.Effect String) -> (String -> Effect.Effect String) -> String -> String -> String -> CI.Docs.Json.Binding -> Effect.Effect CI.Docs.Access.HttpsTarget
preflightWith get probe event ref bundle identity = do
  CI.Docs.Artifact.ensure (event == "push") "Documentation publication refused: only a default-branch push may deploy"
  CI.Docs.Artifact.verify bundle identity
  repository <- get ("repos/" <> identity.repository) >>= CI.Docs.Artifact.parse :: Effect.Effect Repository
  CI.Docs.Artifact.ensure (event == "push" && ref == "refs/heads/" <> repository.default_branch) "Documentation publication refused: only a default-branch push may deploy"
  target <- privateSiteWith get identity
  verifyAccess probe target
  pure target

deployed :: CI.Docs.Json.Binding -> String -> String -> Effect.Effect Unit
deployed identity deployment url = do
  deployedWith getApi probeAccess (\_ -> pure unit)
    identity
    deployment
    url

probeAccess :: String -> Effect.Effect String
probeAccess target = CI.Docs.Artifact.text "curl" [ "--disable", "--silent", "--show-error", "--proto", "=https", "--max-time", "30", "--dump-header", "-", "--output", "/dev/null", target ]

deployedWith :: (String -> Effect.Effect String) -> (String -> Effect.Effect String) -> (String -> Effect.Effect Unit) -> CI.Docs.Json.Binding -> String -> String -> Effect.Effect Unit
deployedWith get probe observe identity deployment url = do
  void (validateDeploymentId deployment)
  status <- get ("repos/" <> identity.repository <> "/pages/deployments/" <> deployment) >>= CI.Docs.Artifact.parse :: Effect.Effect Deployment
  observe status.status
  CI.Docs.Artifact.ensure (status.status == "succeed") "Pages deployment verification failed"
  site <- privateSiteWith get identity
  target <- Data.Either.either Effect.Exception.throw pure (CI.Docs.Access.fromPagesUrl url)
  CI.Docs.Artifact.ensure (target == site) "Pages deployment URL differs from associated private site"
  verifyAccess probe target

verifyAccess :: (String -> Effect.Effect String) -> CI.Docs.Access.HttpsTarget -> Effect.Effect Unit
verifyAccess probe target = do
  response <- probe (CI.Docs.Access.url target)
  CI.Docs.Artifact.ensure (accessDenied response) "Private access verification unavailable: expected recognizable GitHub authentication redirect, not public content or a network error"

accessDenied :: String -> Boolean
accessDenied response =
  let
    blocks = Data.Array.filter (not <<< Data.String.null <<< Data.String.trim) (Data.String.split (Data.String.Pattern "\n\n") (Data.String.replaceAll (Data.String.Pattern "\r") (Data.String.Replacement "") response))
    lines = Data.String.split (Data.String.Pattern "\n") (Data.Maybe.fromMaybe "" (Data.Array.last blocks))
    status = Data.Array.head lines >>= \line -> case Data.Array.take 2 (Data.String.split (Data.String.Pattern " ") (Data.String.trim line)) of
      [ version, code ] -> Data.Maybe.Just { version, code }
      _ -> Data.Maybe.Nothing
    redirects = Data.Array.mapMaybe (Data.String.stripPrefix (Data.String.Pattern "location:") <<< Data.String.toLower) lines
    privateMarkers = Data.Array.mapMaybe (Data.String.stripPrefix (Data.String.Pattern "x-pages-private:") <<< Data.String.toLower) lines
    privatePages = map Data.String.trim privateMarkers == [ "1" ]
    authentication = Data.Array.any
      ( \location ->
          let
            target = Data.String.trim location
          in
            target == "https://github.com/login"
              || Data.Maybe.isJust (Data.String.stripPrefix (Data.String.Pattern "https://github.com/login?") target)
              || (privatePages && Data.Maybe.isJust (Data.String.stripPrefix (Data.String.Pattern "https://github.com/pages/auth?") target))
              || ((Data.Maybe.isJust (Data.String.stripSuffix (Data.String.Pattern "/sso") target) || Data.String.contains (Data.String.Pattern "/sso?") target) && Data.Array.any (\prefix -> Data.Maybe.isJust (Data.String.stripPrefix (Data.String.Pattern prefix) target)) [ "https://github.com/orgs/", "https://github.com/enterprises/" ])
      )
      redirects
    redirected = Data.Maybe.maybe false (\value -> Data.Array.elem value.version [ "HTTP/1.0", "HTTP/1.1", "HTTP/2", "HTTP/2.0", "HTTP/3", "HTTP/3.0" ] && Data.Array.elem value.code [ "302", "303", "307" ]) status
  in
    redirected && Data.Array.length redirects == 1 && authentication

publish :: String -> String -> CI.Docs.Json.Binding -> Effect.Effect Unit
publish bundle artifact identity = do
  event <- required "GITHUB_EVENT_NAME"
  ref <- required "GITHUB_REF"
  publishWith { get: getApi, probe: probeAccess, create, record: record bundle artifact, observed, verified, wait: void (CI.Docs.Artifact.text "sleep" [ "5" ]) } event ref bundle artifact identity

type Client =
  { get :: String -> Effect.Effect String
  , probe :: String -> Effect.Effect String
  , create :: CI.Docs.Json.Binding -> Number -> Effect.Effect Created
  , record :: String -> String -> Effect.Effect Unit
  , verified :: Effect.Effect Unit
  , observed :: String -> Effect.Effect Unit
  , wait :: Effect.Effect Unit
  }

publishWith :: Client -> String -> String -> String -> String -> CI.Docs.Json.Binding -> Effect.Effect Unit
publishWith client event ref bundle artifact identity = do
  expectedTarget <- preflightWith client.get client.probe event ref bundle identity
  CI.Docs.Artifact.ensure (artifact /= "" && Data.Array.all (\c -> c >= '0' && c <= '9') (Data.String.CodeUnits.toCharArray artifact)) "Invalid Pages artifact ID"
  artifactId <- Data.Maybe.maybe (Effect.Exception.throw "Invalid Pages artifact ID") pure (Data.Number.fromString artifact)
  CI.Docs.Artifact.ensure (artifactId > 0.0 && artifactId <= 9007199254740991.0) "Pages artifact ID is outside exact numeric range"
  created <- client.create identity artifactId
  deployment <- returnedDeploymentId created.id
  Build.Output.writeLine Node.Process.stderr ("Pages deployment created: " <> deployment) (pure unit)
  client.record deployment created.page_url
  actualTarget <- Data.Either.either Effect.Exception.throw pure (CI.Docs.Access.fromPagesUrl created.page_url)
  CI.Docs.Artifact.ensure (actualTarget == expectedTarget) "Pages deployment URL differs from associated private site"
  poll 100 deployment
  deployedWith client.get client.probe client.observed identity deployment created.page_url
  client.verified
  where
  poll remaining deployment = do
    CI.Docs.Artifact.ensure (remaining > 0) "Pages deployment verification deadline reached; reconcile the recorded deployment before retrying"
    status <- client.get ("repos/" <> identity.repository <> "/pages/deployments/" <> deployment) >>= CI.Docs.Artifact.parse :: Effect.Effect Deployment
    client.observed status.status
    if status.status == "succeed" then pure unit
    else do
      CI.Docs.Artifact.ensure (Data.Array.elem status.status [ "deployment_in_progress", "syncing_files", "finished_file_sync", "updating_pages", "purging_cdn", "deployment_attempt_error" ]) ("Pages deployment failed or unknown: " <> status.status)
      client.wait
      poll (remaining - 1) deployment

create :: CI.Docs.Json.Binding -> Number -> Effect.Effect Created
create identity artifactId = do
  oidcUrl <- required "ACTIONS_ID_TOKEN_REQUEST_URL"
  oidcToken <- required "ACTIONS_ID_TOKEN_REQUEST_TOKEN"
  CI.Docs.Artifact.ensure (not (Data.String.contains (Data.String.Pattern "\n") oidcToken || Data.String.contains (Data.String.Pattern "\r") oidcToken)) "Invalid Pages OIDC request credential"
  environment <- Node.Process.getEnv
  fetched <- Effect.Uncurried.runEffectFn3 Platform.Node.System.executeWithImpl "curl"
    [ "--disable", "--fail", "--silent", "--show-error", "--proto", "=https", "--max-time", "30", "--header", "@-", oidcUrl ]
    { encoding: "utf8", timeout: 30000, maxBuffer: 1048576, killSignal: "SIGTERM", input: "Authorization: bearer " <> oidcToken <> "\n", cwd: ".", env: environment }
  CI.Docs.Artifact.ensure (Data.Nullable.toMaybe fetched.status == Data.Maybe.Just 0) "Pages OIDC acquisition failed"
  decodedToken <- Effect.Exception.try (CI.Docs.Artifact.parse (Data.Maybe.fromMaybe "" (Data.Nullable.toMaybe fetched.stdout)) :: Effect.Effect Oidc)
  token <- Data.Either.either (\_ -> Effect.Exception.throw "Pages OIDC response invalid") pure decodedToken
  let
    payload = Data.Argonaut.Core.stringify
      ( Data.Argonaut.Encode.encodeJson
          { artifact_id: artifactId, pages_build_version: identity.revision, oidc_token: token.value }
      )
  response <- Effect.Uncurried.runEffectFn3 Platform.Node.System.executeWithImpl "gh"
    [ "api", "--method", "POST", "-H", "Accept: application/vnd.github+json", "-H", "X-GitHub-Api-Version: 2022-11-28", "repos/" <> identity.repository <> "/pages/deployments", "--input", "-" ]
    { encoding: "utf8", timeout: 30000, maxBuffer: 1048576, killSignal: "SIGTERM", input: payload, cwd: ".", env: environment }
  CI.Docs.Artifact.ensure (Data.Nullable.toMaybe response.status == Data.Maybe.Just 0) "Pages deployment creation failed or uncertain; inspect deployment state before retrying"
  decoded <- Effect.Exception.try (CI.Docs.Artifact.parse (Data.Maybe.fromMaybe "" (Data.Nullable.toMaybe response.stdout)) :: Effect.Effect Created)
  Data.Either.either (\_ -> Effect.Exception.throw "Pages deployment response invalid or uncertain; reconcile the existing operation before retrying") pure decoded

record :: String -> String -> String -> String -> Effect.Effect Unit
record bundle pagesArtifact deployment url = do
  outputPath <- required "GITHUB_OUTPUT"
  old <- Platform.Node.Build.readImpl outputPath
  CI.Docs.Artifact.ensure (Data.String.contains (Data.String.Pattern "\n") url == false && Data.String.contains (Data.String.Pattern "\r") url == false) "Invalid Pages URL"
  target <- Data.Either.either Effect.Exception.throw pure (CI.Docs.Access.fromPagesUrl url)
  temporary <- required "RUNNER_TEMP"
  repository <- required "GITHUB_REPOSITORY"
  revision <- required "GITHUB_SHA"
  run <- required "GITHUB_RUN_ID"
  attempt <- required "GITHUB_RUN_ATTEMPT"
  producerArtifact <- required "DOCS_PRODUCER_ARTIFACT_ID"
  bindingHash <- CI.Docs.Artifact.text "sha256sum" [ bundle <> "/binding.json" ]
  let
    bindingDigest = Data.String.CodeUnits.take 64 bindingHash
    evidence = Data.Argonaut.Core.stringify (Data.Argonaut.Encode.encodeJson { repository, revision, run, attempt, deployment, url, producerArtifact, pagesArtifact, bindingDigest, status: "created-not-yet-verified", privateAccess: "not-yet-verified", lastStatus: "created" })
  Platform.Node.Build.writeImpl (temporary <> "/private-pages-deployment.json") evidence
  Build.Output.writeLine Node.Process.stdout evidence (pure unit)
  Platform.Node.Build.writeImpl outputPath (old <> "deployment_id=" <> deployment <> "\npage_url=" <> CI.Docs.Access.url target <> "\n")

observed :: String -> Effect.Effect Unit
observed status = do
  temporary <- required "RUNNER_TEMP"
  evidence <- Platform.Node.Build.readImpl (temporary <> "/private-pages-deployment.json") >>= CI.Docs.Artifact.parse :: Effect.Effect CI.Docs.Json.DeploymentEvidence
  Platform.Node.Build.writeImpl (temporary <> "/private-pages-deployment.json") (Data.Argonaut.Core.stringify (Data.Argonaut.Encode.encodeJson (evidence { lastStatus = status })))

verified :: Effect.Effect Unit
verified = do
  temporary <- required "RUNNER_TEMP"
  evidence <- Platform.Node.Build.readImpl (temporary <> "/private-pages-deployment.json") >>= CI.Docs.Artifact.parse :: Effect.Effect CI.Docs.Json.DeploymentEvidence
  let
    result = Data.Argonaut.Core.stringify (Data.Argonaut.Encode.encodeJson (evidence { status = "succeed", privateAccess = "denied", lastStatus = "succeed" }))
  Platform.Node.Build.writeImpl (temporary <> "/private-pages-deployment.json") result
  Build.Output.writeLine Node.Process.stdout result (pure unit)
