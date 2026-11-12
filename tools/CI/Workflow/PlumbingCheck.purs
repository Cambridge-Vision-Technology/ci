module CI.Workflow.PlumbingCheck (main) where

import Prelude

import Build.Output as Build.Output
import Data.Array as Data.Array
import Data.DateTime.Instant as Data.DateTime.Instant
import Data.Either as Data.Either
import Data.Maybe as Data.Maybe
import Data.Nullable as Data.Nullable
import Data.String as Data.String
import Data.Time.Duration as Data.Time.Duration
import Effect as Effect
import Effect.Exception as Effect.Exception
import Effect.Now as Effect.Now
import Effect.Uncurried as Effect.Uncurried
import Node.Process as Node.Process
import Platform.Node.Build as Platform.Node.Build
import Platform.Node.Documents as Platform.Node.Documents
import Platform.Node.System as Platform.Node.System

ensure :: Boolean -> String -> Effect.Effect Unit
ensure condition message = unless condition (Effect.Exception.throw message)

execute :: String -> Effect.Effect Platform.Node.System.ProcessResult
execute script = do
  result <- Effect.Uncurried.runEffectFn3 Platform.Node.System.executeImpl "bash" [ script ]
    { encoding: "utf8", timeout: 30000, maxBuffer: 1048576, killSignal: "SIGKILL" }
  ensure (Data.Maybe.isNothing (Data.Nullable.toMaybe result.error) && Data.Maybe.isNothing (Data.Nullable.toMaybe result.signal)) "Workflow assertion process did not finish normally"
  pure result

run :: String -> String -> Effect.Effect Unit
run source output = do
  started <- Effect.Now.now
  temporary <- Platform.Node.Documents.temporaryRootImpl >>= \root -> Platform.Node.Documents.temporaryDirectoryImpl (root <> "/workflow-plumbing-TEST-")
  result <- Effect.Exception.try do
    Platform.Node.Build.executeImpl "cp" [ "-R", source <> "/.", temporary ] "."
    Platform.Node.Build.executeImpl "chmod" [ "-R", "u+w", temporary ] "."
    let
      validatePath = temporary <> "/.github/workflows/validate.yml"
      script = temporary <> "/tests/workflow-structure/test.sh"
      timeout = "    timeout-minutes: 10\n"
      padding = "    # " <> Data.String.joinWith "" (Data.Array.replicate 131072 "x") <> "\n"
    validate <- Platform.Node.Build.readImpl validatePath
    ensure (Data.String.contains (Data.String.Pattern timeout) validate) "Regression input lacks the probe timeout"
    let
      padded = Data.String.replaceAll (Data.String.Pattern timeout) (Data.String.Replacement (timeout <> padding)) validate
    Platform.Node.Build.writeImpl validatePath padded
    success <- execute script
    let
      successText = Data.Maybe.fromMaybe "" (Data.Nullable.toMaybe success.stdout)
      successErrors = Data.Maybe.fromMaybe "" (Data.Nullable.toMaybe success.stderr)
    ensure (Data.Nullable.toMaybe success.status == Data.Maybe.Just 0 && Data.String.contains (Data.String.Pattern "Results: 364 passed, 0 failed") successText) ("Large-input workflow assertions failed:\n" <> successErrors <> successText)
    Platform.Node.Build.writeImpl validatePath (Data.String.replaceAll (Data.String.Pattern timeout) (Data.String.Replacement "    timeout-minutes: 11\n") padded)
    rejected <- execute script
    let
      rejectedText = Data.Maybe.fromMaybe "" (Data.Nullable.toMaybe rejected.stdout)
    ensure (Data.Nullable.toMaybe rejected.status == Data.Maybe.Just 1 && Data.String.contains (Data.String.Pattern "FAIL: probe-setup-action-org-read is not bounded to ten minutes") rejectedText && Data.String.contains (Data.String.Pattern "Results: 360 passed, 4 failed") rejectedText) "Broken timeout was not rejected by its original assertion"
    pure successText
  Platform.Node.Documents.removeDirectoryImpl temporary
  successText <- Data.Either.either Effect.Exception.throwException pure result
  ended <- Effect.Now.now
  Platform.Node.Build.writeImpl output (successText <> "Large comment inputs passed; four incorrect timeouts rejected by the original assertions.\nelapsed-including-setup-cleanup=" <> show (Data.DateTime.Instant.diff ended started :: Data.Time.Duration.Milliseconds) <> "\n")

main :: Effect.Effect Unit
main = do
  args <- Data.Array.drop 2 <$> Node.Process.argv
  result <- Effect.Exception.try case args of
    [ source, output ] -> run source output
    _ -> Effect.Exception.throw "Expected workflow source and output path"
  case result of
    Data.Either.Left error -> Build.Output.writeLine Node.Process.stderr (Effect.Exception.message error) (Node.Process.exit' 1)
    Data.Either.Right _ -> pure unit
