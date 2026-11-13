module CI.Docs.Json where

import Prelude

import Data.Argonaut.Core as Data.Argonaut.Core
import Data.Argonaut.Decode as Data.Argonaut.Decode
import Data.Argonaut.Decode.Error as Data.Argonaut.Decode.Error
import Data.Argonaut.Encode as Data.Argonaut.Encode
import Data.Either as Data.Either
import Data.Maybe as Data.Maybe

data PagesDeploymentIdJson
  = StringPagesDeploymentIdJson String
  | NumberPagesDeploymentIdJson Number

derive instance eqPagesDeploymentIdJson :: Eq PagesDeploymentIdJson

instance Data.Argonaut.Decode.DecodeJson PagesDeploymentIdJson where
  decodeJson value = case Data.Argonaut.Core.toString value of
    Data.Maybe.Just text ->
      Data.Either.Right (StringPagesDeploymentIdJson text)
    Data.Maybe.Nothing ->
      case Data.Argonaut.Core.toNumber value of
        Data.Maybe.Just number ->
          Data.Either.Right (NumberPagesDeploymentIdJson number)
        Data.Maybe.Nothing ->
          Data.Either.Left (Data.Argonaut.Decode.Error.TypeMismatch "Pages deployment ID must be a string or integer")

type Binding =
  { repository :: String
  , revision :: String
  , run :: String
  , attempt :: String
  , workflowRepository :: String
  , workflowRevision :: String
  , system :: String
  }

type Artifact = { binding :: Binding, files :: Array { path :: String, digest :: String } }

type DeploymentEvidence =
  { repository :: String
  , revision :: String
  , run :: String
  , attempt :: String
  , deployment :: String
  , url :: String
  , status :: String
  , privateAccess :: String
  , producerArtifact :: String
  , pagesArtifact :: String
  , bindingDigest :: String
  , lastStatus :: String
  }

newtype ArtifactJson = ArtifactJson Artifact

instance Data.Argonaut.Decode.DecodeJson ArtifactJson where
  decodeJson value = ArtifactJson <$> Data.Argonaut.Decode.decodeJson value

instance Data.Argonaut.Encode.EncodeJson ArtifactJson where
  encodeJson (ArtifactJson value) = Data.Argonaut.Encode.encodeJson value
