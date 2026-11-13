module CI.Docs.Access (HttpsTarget, fromPagesUrl, url) where

import Prelude

import Data.Array as Data.Array
import Data.Either as Data.Either
import Data.Maybe as Data.Maybe
import Data.String as Data.String
import Data.String.CodeUnits as Data.String.CodeUnits

newtype HttpsTarget = HttpsTarget String

derive instance eqHttpsTarget :: Eq HttpsTarget

url :: HttpsTarget -> String
url (HttpsTarget value) = value

fromPagesUrl :: String -> Data.Either.Either String HttpsTarget
fromPagesUrl value = do
  source <- case Data.String.stripPrefix (Data.String.Pattern "https://") value of
    Data.Maybe.Just address ->
      Data.Either.Right { address, bootstrap: false }
    Data.Maybe.Nothing ->
      case Data.String.stripPrefix (Data.String.Pattern "http://") value of
        Data.Maybe.Just address ->
          Data.Either.Right { address, bootstrap: true }
        Data.Maybe.Nothing ->
          invalid
  case Data.Array.uncons (Data.String.split (Data.String.Pattern "/") source.address) of
    Data.Maybe.Nothing ->
      invalid
    Data.Maybe.Just { head: authority, tail: path } -> do
      let
        host = Data.String.toLower authority
        labels = Data.String.split (Data.String.Pattern ".") host
        alphanumeric c = (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')
        label text = not (Data.String.null text)
          && Data.Array.all (\c -> alphanumeric c || c == '-') (Data.String.CodeUnits.toCharArray text)
          && Data.Maybe.maybe false alphanumeric (Data.Array.head (Data.String.CodeUnits.toCharArray text))
          && Data.Maybe.maybe false alphanumeric (Data.Array.last (Data.String.CodeUnits.toCharArray text))
        safeAddress = Data.Array.all (\c -> c >= '!' && c <= '~' && c /= '\\' && c /= '?' && c /= '#') (Data.String.CodeUnits.toCharArray source.address)
        privateHost = Data.Maybe.isJust (Data.String.stripSuffix (Data.String.Pattern ".pages.github.io") host)
      if Data.Array.length labels >= 2 && Data.Array.all label labels && safeAddress && (not source.bootstrap || privateHost) then
        Data.Either.Right (HttpsTarget ("https://" <> host <> "/" <> Data.String.joinWith "/" path))
      else invalid
  where
  invalid :: forall a. Data.Either.Either String a
  invalid = Data.Either.Left "Private Pages setup blocker: invalid site URL; HTTP metadata is supported only for a private pages.github.io host, and access must use HTTPS"
