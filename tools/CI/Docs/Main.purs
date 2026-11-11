module CI.Docs.Main (main) where

import Prelude

import Build.Output as Build.Output
import CI.Docs.Artifact as CI.Docs.Artifact
import CI.Docs.Json as CI.Docs.Json
import CI.Docs.Publication as CI.Docs.Publication
import Data.Array as Data.Array
import Data.Either as Data.Either
import Data.Foldable as Data.Foldable
import Data.Maybe as Data.Maybe
import Data.Nullable as Data.Nullable
import Data.String as Data.String
import Effect as Effect
import Effect.Exception as Effect.Exception
import Effect.Uncurried as Effect.Uncurried
import Node.Path as Node.Path
import Node.Process as Node.Process
import Platform.Node.Build as Platform.Node.Build
import Platform.Node.Documents as Platform.Node.Documents
import Platform.Node.System as Platform.Node.System

required :: String -> Effect.Effect String
required name = Node.Process.lookupEnv name >>= Data.Maybe.maybe (Effect.Exception.throw ("Missing " <> name)) pure

binding :: Effect.Effect CI.Docs.Json.Binding
binding = do
  repository <- required "GITHUB_REPOSITORY"
  revision <- required "GITHUB_SHA"
  run <- required "GITHUB_RUN_ID"
  attempt <- required "GITHUB_RUN_ATTEMPT"
  workflowRepository <- required "DOCS_WORKFLOW_REPOSITORY"
  workflowRevision <- required "DOCS_WORKFLOW_SHA"
  system <- required "DOCS_SYSTEM"
  pure { repository, revision, run, attempt, workflowRepository, workflowRevision, system }

output :: String -> Effect.Effect Unit
output line = do
  path <- required "GITHUB_OUTPUT"
  old <- Platform.Node.Build.readImpl path
  Platform.Node.Build.writeImpl path (old <> line <> "\n")

generate :: String -> String -> Effect.Effect Unit
generate detector directory = do
  resolved <- Node.Path.resolve [ directory ] ""
  root <- Data.String.trim <$> CI.Docs.Artifact.text "realpath" [ "--", resolved ]
  workspacePath <- required "GITHUB_WORKSPACE"
  workspace <- Data.String.trim <$> CI.Docs.Artifact.text "realpath" [ "--", workspacePath ]
  CI.Docs.Artifact.ensure (root == workspace || Data.Maybe.isJust (Data.String.stripPrefix (Data.String.Pattern (workspace <> "/")) root)) "Flake directory escapes the caller workspace"
  Node.Process.chdir root
  Node.Process.setEnv "PWD" root
  Node.Process.setEnv "GITHUB_WORKSPACE" workspace
  identity <- binding
  present <-
    CI.Docs.Artifact.text "nix"
      [ "eval"
      , "--json"
      , "--no-write-lock-file"
      , "--impure"
      , "--file"
      , detector
      ] >>= CI.Docs.Artifact.parse
  if not present then output "present=false"
  else do
    output "present=false"
    exists <- Platform.Node.Build.existsImpl ".out"
    when exists (CI.Docs.Artifact.directory ".out")
    Platform.Node.Build.mkdirImpl ".out"
    old <- Platform.Node.Build.existsImpl ".out/docs"
    when old do
      CI.Docs.Artifact.directory ".out/docs"
      Platform.Node.Documents.removeDirectoryImpl ".out/docs"
    result <- Effect.Exception.try do
      environment <- Node.Process.getEnv
      generated <- Effect.Uncurried.runEffectFn3 Platform.Node.System.executeWithImpl "nix" [ "run", "--no-write-lock-file", "--system", identity.system, ".#docs" ]
        { encoding: "utf8", timeout: 3600000, maxBuffer: 16777216, killSignal: "SIGTERM", input: "", cwd: root, env: environment }
      Data.Foldable.for_ (Data.Nullable.toMaybe generated.stdout) (\text -> Build.Output.writeLine Node.Process.stdout text (pure unit))
      Data.Foldable.for_ (Data.Nullable.toMaybe generated.stderr) (\text -> Build.Output.writeLine Node.Process.stderr text (pure unit))
      CI.Docs.Artifact.ensure (Data.Nullable.toMaybe generated.status == Data.Maybe.Just 0) "Documentation app failed, timed out or exceeded its output limit"
      entries <- CI.Docs.Artifact.validate ".out/docs"
      temp <- required "RUNNER_TEMP"
      bundle <- Platform.Node.Documents.temporaryDirectoryImpl (temp <> "/ci-docs-")
      Platform.Node.Build.copyImpl ".out/docs" (bundle <> "/site")
      CI.Docs.Artifact.writeBinding (bundle <> "/binding.json") identity entries
      CI.Docs.Artifact.verify bundle identity
      output ("bundle=" <> bundle)
      output "present=true"
    case result of
      Data.Either.Left error -> do
        partial <- Platform.Node.Build.existsImpl ".out/docs"
        when partial (Platform.Node.Documents.removeDirectoryImpl ".out/docs")
        Effect.Exception.throwException error
      Data.Either.Right _ ->
        pure unit

runCommand :: String -> Array String -> Effect.Effect Unit
runCommand detector = case _ of
  [ "generate", directory ] ->
    generate detector directory
  [ "verify", bundle ] ->
    binding >>= CI.Docs.Artifact.verify bundle
  [ "preflight", bundle ] -> do
    identity <- binding
    CI.Docs.Publication.preflight bundle identity
  [ "deployed", deployment, url ] -> do
    identity <- binding
    CI.Docs.Publication.deployed identity deployment url
  [ "publish", bundle, artifact ] -> do
    identity <- binding
    CI.Docs.Publication.publish bundle artifact identity
  _ ->
    Effect.Exception.throw "Usage: ci-docs generate FLAKE_DIRECTORY | verify BUNDLE | preflight BUNDLE | publish BUNDLE PAGES_ARTIFACT_ID | deployed DEPLOYMENT_ID URL"

main :: Effect.Effect Unit
main = do
  args <- Data.Array.drop 2 <$> Node.Process.argv
  result <- Effect.Exception.try case Data.Array.uncons args of
    Data.Maybe.Just { head: detector, tail } -> runCommand detector tail
    Data.Maybe.Nothing -> Effect.Exception.throw "Missing packaged flake detector"
  case result of
    Data.Either.Left error -> Build.Output.writeLine Node.Process.stderr (Effect.Exception.message error) (Node.Process.exit' 1)
    Data.Either.Right _ -> pure unit
