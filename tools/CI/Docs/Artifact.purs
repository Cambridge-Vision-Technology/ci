module CI.Docs.Artifact where

import Prelude

import CI.Docs.Json as CI.Docs.Json
import Data.Argonaut.Core as Data.Argonaut.Core
import Data.Argonaut.Decode as Data.Argonaut.Decode
import Data.Argonaut.Encode as Data.Argonaut.Encode
import Data.Argonaut.Parser as Data.Argonaut.Parser
import Data.Array as Data.Array
import Data.Either as Data.Either
import Data.Foldable as Data.Foldable
import Data.Maybe as Data.Maybe
import Data.Nullable as Data.Nullable
import Data.String as Data.String
import Data.String.CodeUnits as Data.String.CodeUnits
import Data.String.Regex as Data.String.Regex
import Data.String.Regex.Flags as Data.String.Regex.Flags
import Data.Traversable as Data.Traversable
import Effect as Effect
import Effect.Exception as Effect.Exception
import Effect.Uncurried as Effect.Uncurried
import Platform.Node.Build as Platform.Node.Build
import Platform.Node.Documents as Platform.Node.Documents
import Platform.Node.System as Platform.Node.System

ensure :: Boolean -> String -> Effect.Effect Unit
ensure condition message = unless condition (Effect.Exception.throw message)

text :: String -> Array String -> Effect.Effect String
text = Effect.Uncurried.runEffectFn2 Platform.Node.Documents.executeTextImpl

parse :: forall a. Data.Argonaut.Decode.DecodeJson a => String -> Effect.Effect a
parse value = Data.Either.either Effect.Exception.throw pure (Data.Argonaut.Parser.jsonParser value)
  >>= Data.Either.either (Effect.Exception.throw <<< show) pure <<< Data.Argonaut.Decode.decodeJson

stat :: String -> Effect.Effect Platform.Node.System.Stat
stat path = do
  value <- Effect.Uncurried.runEffectFn2 Platform.Node.System.lstatImpl path { throwIfNoEntry: true }
  Data.Maybe.maybe (Effect.Exception.throw ("Missing path: " <> path)) pure (Data.Nullable.toMaybe value)

directory :: String -> Effect.Effect Unit
directory path = stat path >>= \value -> ensure (Platform.Node.System.directoryImpl value) ("Unsafe non-directory: " <> path)

safeName :: String -> Boolean
safeName value = value /= "" && value /= "." && value /= ".."
  && value /= ".git"
  && value /= ".github"
  && Data.Foldable.all (\c -> c >= ' ' && c /= '\\' && c /= ':' && c /= '\x7f') (Data.String.CodeUnits.toCharArray value)

files :: String -> String -> Effect.Effect (Array { path :: String, digest :: String })
files root prefix = do
  let
    current = root <> if prefix == "" then "" else "/" <> prefix
  directory current
  names <- Data.Array.sort <$> Platform.Node.Build.entriesImpl current
  groups <- Data.Traversable.traverse
    ( \name -> do
        ensure (safeName name) "Unsafe artifact filename"
        let
          relative = if prefix == "" then name else prefix <> "/" <> name
          path = root <> "/" <> relative
        value <- stat path
        if Platform.Node.System.directoryImpl value then files root relative
        else do
          ensure (Platform.Node.System.fileImpl value) ("Unsafe artifact entry: " <> relative)
          links <- Data.String.trim <$> text "stat" [ "--format=%h", path ]
          ensure (links == "1") ("Hard links are not publishable: " <> relative)
          digest <- Data.String.trim <$> text "sha256sum" [ path ]
          pure [ { path: relative, digest: Data.String.CodeUnits.take 64 digest } ]
    )
    names
  pure (Data.Array.concat groups)

validate :: String -> Effect.Effect (Array { path :: String, digest :: String })
validate root = do
  entries <- files root ""
  ensure (not (Data.Array.null entries)) "Documentation output is empty"
  ensure (Data.Array.any (\entry -> entry.path == "index.html") entries) "Documentation requires index.html"
  index <- Data.String.toLower <$> Platform.Node.Build.readImpl (root <> "/index.html")
  body <- Data.Either.either Effect.Exception.throw pure (Data.String.Regex.regex "<body[^>]*>\\s*(?!</body>)\\S[\\s\\S]*</body>" Data.String.Regex.Flags.noFlags)
  ensure (Data.String.contains (Data.String.Pattern "<html") index && Data.String.contains (Data.String.Pattern "</html>") index && Data.String.Regex.test body index) "Documentation index.html is not a usable HTML page"
  pure entries

writeBinding :: String -> CI.Docs.Json.Binding -> Array { path :: String, digest :: String } -> Effect.Effect Unit
writeBinding path binding entries = Platform.Node.Build.writeImpl path
  (Data.Argonaut.Core.stringify (Data.Argonaut.Encode.encodeJson (CI.Docs.Json.ArtifactJson { binding, files: entries })))

verify :: String -> CI.Docs.Json.Binding -> Effect.Effect Unit
verify bundle binding = do
  CI.Docs.Json.ArtifactJson artifact <- Platform.Node.Build.readImpl (bundle <> "/binding.json") >>= parse
  ensure (artifact.binding == binding) "Documentation repository/revision/run/workflow binding mismatch"
  entries <- validate (bundle <> "/site")
  ensure (entries == artifact.files) "Documentation artifact digest mismatch"
