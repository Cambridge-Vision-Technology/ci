module CI.Docs.Json where

import Prelude

import Data.Argonaut.Decode as Data.Argonaut.Decode
import Data.Argonaut.Encode as Data.Argonaut.Encode

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
  }

newtype ArtifactJson = ArtifactJson Artifact

instance Data.Argonaut.Decode.DecodeJson ArtifactJson where
  decodeJson value = ArtifactJson <$> Data.Argonaut.Decode.decodeJson value

instance Data.Argonaut.Encode.EncodeJson ArtifactJson where
  encodeJson (ArtifactJson value) = Data.Argonaut.Encode.encodeJson value
