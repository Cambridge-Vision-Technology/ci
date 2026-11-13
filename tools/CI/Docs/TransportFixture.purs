module CI.Docs.TransportFixture (main) where

import Prelude

import Build.Output as Build.Output
import CI.Docs.Artifact as CI.Docs.Artifact
import Data.Argonaut.Core as Data.Argonaut.Core
import Data.Argonaut.Encode as Data.Argonaut.Encode
import Data.Argonaut.Parser as Data.Argonaut.Parser
import Data.Array as Data.Array
import Data.Either as Data.Either
import Data.Maybe as Data.Maybe
import Data.String as Data.String
import Effect as Effect
import Effect.Exception as Effect.Exception
import Effect.Ref as Effect.Ref
import Foreign.Object as Foreign.Object
import Node.Encoding as Node.Encoding
import Node.EventEmitter as Node.EventEmitter
import Node.Process as Node.Process
import Node.Stream as Node.Stream
import Platform.Node.Build as Platform.Node.Build

valueAfter :: String -> Array String -> Data.Maybe.Maybe String
valueAfter flag args = Data.Array.elemIndex flag args >>= \index -> Data.Array.index args (index + 1)

count :: String -> String -> Effect.Effect Unit
count root name = do
  let
    path = root <> "/" <> name <> ".calls"
  exists <- Platform.Node.Build.existsImpl path
  old <- if exists then Platform.Node.Build.readImpl path else pure ""
  Platform.Node.Build.writeImpl path (old <> "call\n")

run :: String -> Array String -> Effect.Effect Unit
run input arguments = do
  root <- Node.Process.lookupEnv "DOCS_TRANSPORT_TEST_ROOT" >>= Data.Maybe.maybe (Effect.Exception.throw "Missing TEST transport root") pure
  failure <- Data.Maybe.fromMaybe "" <$> Node.Process.lookupEnv "DOCS_TRANSPORT_FAILURE"
  case Data.Array.uncons arguments of
    Data.Maybe.Just { head: "curl", tail: args } | Data.Array.elem "--dump-header" args -> do
      CI.Docs.Artifact.ensure (args == [ "--disable", "--silent", "--show-error", "--proto", "=https", "--max-time", "30", "--dump-header", "-", "--output", "/dev/null", "https://test.pages.github.io/" ] && input == "") "Wrong anonymous HTTPS probe contract; credentials, insecure TLS and redirect following are forbidden"
      count root "probe"
      if failure == "probe" then Effect.Exception.throw "Injected TEST HTTPS failure"
      else do
        response <- Node.Process.lookupEnv "DOCS_TEST_PRIVATE_RESPONSE" >>= Data.Maybe.maybe (Effect.Exception.throw "Missing captured private response") Platform.Node.Build.readImpl
        Build.Output.writeLine Node.Process.stdout response (pure unit)
    Data.Maybe.Just { head: "curl", tail: args } -> do
      CI.Docs.Artifact.ensure (valueAfter "--header" args == Data.Maybe.Just "@-" && Data.Array.last args == Data.Maybe.Just "https://token.TEST.invalid/oidc") "Wrong OIDC transport request"
      CI.Docs.Artifact.ensure (not (Data.Array.any (Data.String.contains (Data.String.Pattern "TEST-REQUEST-CREDENTIAL")) args)) "OIDC request credential leaked to argv"
      CI.Docs.Artifact.ensure (input == "Authorization: bearer TEST-REQUEST-CREDENTIAL\n") "Wrong OIDC stdin credential contract"
      CI.Docs.Artifact.ensure (Data.Array.elem "--disable" args && valueAfter "--proto" args == Data.Maybe.Just "=https" && valueAfter "--max-time" args == Data.Maybe.Just "30") "OIDC transport omitted security/deadline settings"
      count root "curl"
      Build.Output.writeLine Node.Process.stdout (if failure == "oidc" then "{\"value\":{\"invalid\":\"TEST-OIDC-CREDENTIAL\"}}" else "{\"value\":\"TEST-OIDC-CREDENTIAL\"}") (pure unit)
    Data.Maybe.Just { head: "gh", tail: args } -> do
      CI.Docs.Artifact.ensure (Data.Array.head args == Data.Maybe.Just "api" && valueAfter "--method" args == Data.Maybe.Just "POST" && valueAfter "--input" args == Data.Maybe.Just "-") "Wrong Pages creation verb/input contract"
      CI.Docs.Artifact.ensure (Data.Array.elem "repos/TEST/docs/pages/deployments" args && Data.Array.elem "Accept: application/vnd.github+json" args && Data.Array.elem "X-GitHub-Api-Version: 2022-11-28" args) "Wrong Pages subject/API contract"
      CI.Docs.Artifact.ensure (not (Data.Array.any (Data.String.contains (Data.String.Pattern "CREDENTIAL")) args)) "Pages credential leaked to argv"
      payload <- CI.Docs.Artifact.parse input :: Effect.Effect { artifact_id :: Number, pages_build_version :: String, oidc_token :: String }
      CI.Docs.Artifact.ensure (payload.artifact_id == 9876543210.0 && payload.pages_build_version == "test-revision" && payload.oidc_token == "TEST-OIDC-CREDENTIAL") "Wrong Pages request body identity/credential"
      json <- Data.Either.either Effect.Exception.throw pure (Data.Argonaut.Parser.jsonParser input)
      fields <- Data.Maybe.maybe (Effect.Exception.throw "Missing Pages request object") pure (Data.Argonaut.Core.toObject json)
      CI.Docs.Artifact.ensure (Data.Maybe.isNothing (Foreign.Object.lookup "artifact_url" fields)) "Unexpected artifact routing override"
      CI.Docs.Artifact.ensure (Data.Maybe.maybe true (\value -> Data.Argonaut.Core.toString value == Data.Maybe.Just "github-pages") (Foreign.Object.lookup "environment" fields)) "Wrong Pages environment"
      count root "post"
      if failure == "post" then Effect.Exception.throw "Injected TEST POST failure"
      else if failure == "raw-rounded-max" || failure == "raw-rounded-small" then
        Build.Output.writeLine Node.Process.stdout ("{\"id\":" <> (if failure == "raw-rounded-max" then "9007199254740991.1" else "1.0000000000000001") <> ",\"status_url\":\"https://unused.TEST.invalid/hint\",\"page_url\":\"https://test.example/\"}") (pure unit)
      else do
        let
          id = if failure == "numeric-id" then Data.Argonaut.Core.fromNumber 9876543210.0 else if failure == "invalid-id" then Data.Argonaut.Core.fromBoolean true else Data.Argonaut.Core.fromString "returned-id"
          response =
            if failure == "missing-id" then
              Data.Argonaut.Encode.encodeJson { status_url: "https://api.github.com/repositories/123/pages/deployment_status/not-the-id", page_url: "https://test.example/" }
            else
              Data.Argonaut.Encode.encodeJson { id, status_url: "https://api.github.com/repositories/123/pages/deployment_status/not-the-id", page_url: "https://test.example/" }
        Build.Output.writeLine Node.Process.stdout (Data.Argonaut.Core.stringify response) (pure unit)
    _ ->
      Effect.Exception.throw "Unexpected TEST transport executable"

report :: Data.Either.Either Effect.Exception.Error Unit -> Effect.Effect Unit
report result = do
  case result of
    Data.Either.Left error -> do
      root <- Node.Process.lookupEnv "DOCS_TRANSPORT_TEST_ROOT" >>= Data.Maybe.maybe (Effect.Exception.throw "Missing TEST transport root") pure
      Platform.Node.Build.writeImpl (root <> "/transport.error") (Effect.Exception.message error)
      Build.Output.writeLine Node.Process.stderr (Effect.Exception.message error) (Node.Process.exit' 1)
    Data.Either.Right _ ->
      pure unit

main :: Effect.Effect Unit
main = do
  args <- Data.Array.drop 2 <$> Node.Process.argv
  input <- Effect.Ref.new ""
  Node.Stream.setEncoding Node.Process.stdin Node.Encoding.UTF8
  Node.EventEmitter.on_ Node.Stream.dataHStr (\chunk -> Effect.Ref.modify_ (_ <> chunk) input) Node.Process.stdin
  Node.EventEmitter.once_ Node.Stream.errorH (report <<< Data.Either.Left) Node.Process.stdin
  Node.EventEmitter.once_ Node.Stream.endH
    ( do
        value <- Effect.Ref.read input
        result <- Effect.Exception.try (run value args)
        report result
    )
    Node.Process.stdin
  Node.Stream.resume Node.Process.stdin
