{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell   #-}

module Pact.Analyze.Remote.Types where

import           Control.Lens       (makeLenses)
import qualified Data.Aeson         as A
import           Data.Text          (Text)

import           Pact.Types.Exp     (ModuleName)
import           Pact.Types.Term    (Module)

data Request
  = Request [Module] ModuleName -- ^ verify one of the modules, by name

instance A.FromJSON Request where
  parseJSON = A.withObject "Request" $ \o ->
    Request <$> o A..: "modules"
            <*> o A..: "verify"

instance A.ToJSON Request where
  toJSON (Request mods modName) = A.object
    [ "modules" A..= mods
    , "verify"  A..= modName
    ]

newtype Response
  = Response
    { _responseLines :: [Text] -- ^ REPL output from the server, whether
                               -- verification has failed or succeeded.
    }

instance A.FromJSON Response where
  parseJSON = A.withObject "Response" $ \o ->
    Response <$> o A..: "output"

instance A.ToJSON Response where
  toJSON (Response outputLines) = A.object
    [ "output" A..= outputLines
    ]

newtype ClientError
  = ClientError String
  deriving Show

instance A.FromJSON ClientError where
  parseJSON = A.withObject "ClientError" $ \o ->
    ClientError <$> o A..: "error"

instance A.ToJSON ClientError where
  toJSON (ClientError err) = A.object
    ["error" A..= err
    ]

makeLenses ''Response
