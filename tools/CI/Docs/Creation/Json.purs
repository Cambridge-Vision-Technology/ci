module CI.Docs.Creation.Json (IdJson(..), CreatedJson, parse, integerToken) where

import Prelude

import Control.Alt as Control.Alt
import Control.Lazy as Control.Lazy
import Data.Argonaut.Decode as Data.Argonaut.Decode
import Data.Argonaut.Decode.Error as Data.Argonaut.Decode.Error
import Data.Argonaut.Parser as Data.Argonaut.Parser
import Data.Array as Data.Array
import Data.Either as Data.Either
import Data.String as Data.String
import Data.String.CodeUnits as Data.String.CodeUnits
import Data.Traversable as Data.Traversable
import Data.Tuple as Data.Tuple
import Parsing as Parsing
import Parsing.Combinators as Parsing.Combinators
import Parsing.String as Parsing.String

data IdJson = StringIdJson String | IntegerIdJson String

derive instance eqIdJson :: Eq IdJson

type CreatedJson = { id :: IdJson, status_url :: String, page_url :: String }

integerToken :: String -> Data.Either.Either String String
integerToken value =
  if
    value /= "" && Data.String.CodeUnits.take 1 value /= "0"
      && Data.Array.all (\c -> c >= '0' && c <= '9') (Data.String.CodeUnits.toCharArray value)
      && (Data.String.CodeUnits.length value < 16 || (Data.String.CodeUnits.length value == 16 && value <= "9007199254740991")) then
    Data.Either.Right value
  else
    Data.Either.Left "Invalid Pages deployment ID; reconcile the existing operation before retrying"

whitespace :: Parsing.Parser String Unit
whitespace = Parsing.Combinators.skipMany (Parsing.String.satisfy (\c -> Data.Array.elem c [ ' ', '\n', '\r', '\t' ]))

creationString :: Parsing.Parser String Unit
creationString = do
  void (Parsing.String.char '"')
  Parsing.Combinators.skipMany
    ( Control.Alt.alt
        (void (Parsing.String.char '\\') *> void Parsing.String.anyCodePoint)
        (Parsing.Combinators.notFollowedBy (Control.Alt.alt (Parsing.String.char '"') (Parsing.String.char '\\')) *> void Parsing.String.anyCodePoint)
    )
  void (Parsing.String.char '"')

creationValue :: Parsing.Parser String Unit
creationValue = Control.Lazy.defer \_ -> do
  Control.Alt.alt creationString
    ( Control.Alt.alt (void creationObject)
        ( Control.Alt.alt
            ( Parsing.Combinators.between (Parsing.String.char '[' *> whitespace) (Parsing.String.char ']')
                (void (Parsing.Combinators.sepBy creationValue (Parsing.String.char ',' *> whitespace)))
            )
            (Parsing.Combinators.skipMany1 (Parsing.String.satisfy (\c -> not (Data.Array.elem c [ ' ', '\n', '\r', '\t', ',', '}', ']', '{', '[', '"' ]))))
        )
    )
  whitespace

creationObject :: Parsing.Parser String (Array { key :: String, token :: String })
creationObject = Parsing.Combinators.between (Parsing.String.char '{' *> whitespace) (Parsing.String.char '}')
  (Data.Array.fromFoldable <$> Parsing.Combinators.sepBy member (Parsing.String.char ',' *> whitespace))
  where
  member = do
    Data.Tuple.Tuple key _ <- Parsing.String.match creationString
    whitespace
    void (Parsing.String.char ':')
    whitespace
    Data.Tuple.Tuple token _ <- Parsing.String.match creationValue
    pure { key, token: Data.String.trim token }

response :: forall a b. Data.Either.Either a b -> Data.Either.Either String b
response = Data.Either.either (const (Data.Either.Left "Invalid or ambiguous Pages deployment response")) Data.Either.Right

decodeString :: String -> Data.Either.Either String String
decodeString value = do
  json <- response (Data.Argonaut.Parser.jsonParser value)
  response (Data.Argonaut.Decode.decodeJson json)

parse :: String -> Data.Either.Either String CreatedJson
parse source = do
  raw <- response (Parsing.runParser source (whitespace *> creationObject <* whitespace <* Parsing.String.eof))
  members <- Data.Traversable.traverse
    ( \member -> do
        key <- decodeString member.key
        pure { key, token: member.token }
    )
    raw
  let
    keys = map _.key members
  if Data.Array.length (Data.Array.nub keys) /= Data.Array.length keys then Data.Either.Left "Ambiguous Pages deployment response keys"
  else do
    id <- case Data.Array.filter (\member -> member.key == "id") members of
      [ member ] ->
        if Data.String.CodeUnits.take 1 member.token == "\"" then StringIdJson <$> decodeString member.token
        else IntegerIdJson <$> integerToken member.token
      _ ->
        Data.Either.Left "Missing Pages deployment ID"
    json <- response (Data.Argonaut.Parser.jsonParser source)
    metadata <- response (Data.Argonaut.Decode.decodeJson json :: Data.Either.Either Data.Argonaut.Decode.Error.JsonDecodeError { status_url :: String, page_url :: String })
    pure { id, status_url: metadata.status_url, page_url: metadata.page_url }
