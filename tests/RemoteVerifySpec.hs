{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes       #-}

-- | Tests remote verification on the server side (i.e. no GHCJS involvement)
module RemoteVerifySpec (spec) where

import Control.Concurrent
import Control.Exception (finally)
import Control.Lens
import Control.Monad.State.Strict
import Data.Aeson
import qualified Data.HashMap.Strict as HM
import Data.Maybe
import qualified Data.Text as T
import Snap.Http.Server.Config
import Test.Hspec
import NeatInterpolation (text)
import Network.Wreq

import qualified Pact.Analyze.Remote.Types as Remote
import Pact.Analyze.Remote.Server (runServer)
import Pact.Repl
import Pact.Repl.Types
import Pact.Types.Runtime

spec :: Spec
spec = do
  describe "single module"                       testSingleModule
  describe "multiple modules, sent out of order" testUnsortedModules

data TestFailure
  = ReplError String
  deriving Show

loadCode :: Text -> IO (Either TestFailure ReplState)
loadCode code = do
  replState0 <- initReplState StringEval
  (eTerm, replState) <- runStateT (evalRepl' $ T.unpack code) replState0
  pure $ case eTerm of
    Left err -> Left $ ReplError err
    Right _t -> Right replState

stateModuleData :: ModuleName -> ReplState -> Maybe (Module, HM.HashMap Text Ref)
stateModuleData nm replState = replState ^. rEnv . eeRefStore . rsModules . at nm

serve :: Int -> IO ThreadId
serve port = forkIO $ runServer config
  where
    config = mempty
           & setVerbose False
           & setPort port
           & setAccessLog ConfigNoLog
           & setErrorLog ConfigNoLog

serveAndRequest :: Int -> Remote.Request -> IO (Response (Remote.Response))
serveAndRequest port body = do
  let url = "http://localhost:" ++ show port ++ "/verify"
  tid <- serve port
  finally
    (asJSON =<< post url (toJSON body) :: IO (Response Remote.Response))
    (killThread tid)

testSingleModule :: Spec
testSingleModule = do
  eReplState0 <- runIO $ loadCode
    [text|
      (env-keys ["admin"])
      (env-data { "keyset": { "keys": ["admin"], "pred": "=" } })
      (begin-tx)

      (define-keyset 'ks (read-keyset "keyset"))
      (module mod1 'ks
        (defun f:integer ()
          @doc   "always returns 1"
          @model (property (= result 1))
          1))

      (commit-tx)
    |]

  it "loads locally" $ do
    Right replState0 <- pure eReplState0
    stateModuleData "mod1" replState0 `shouldSatisfy` isJust

  Right replState0 <- pure eReplState0
  Just (mod1, _refs) <- pure $ stateModuleData "mod1" replState0

  resp <- runIO $ serveAndRequest 3000 $ Remote.Request [mod1] "mod1"

  it "verifies over the network" $
    "Property proven valid" == resp ^. responseBody . Remote.responseLines . ix 0

testUnsortedModules :: Spec
testUnsortedModules = do
  eReplState0 <- runIO $ loadCode
    [text|
      (env-keys ["admin"])
      (env-data { "keyset": { "keys": ["admin"], "pred": "=" } })
      (begin-tx)
      (define-keyset 'ks (read-keyset "keyset"))
      (module mod1 'ks
        (defun f:integer ()
          @doc   "always returns 1"
          @model (property (= result 1))
          1))
      (commit-tx)
      (begin-tx)
      (define-keyset 'ks2 (read-keyset "keyset"))
      (module mod2 'ks2
        (use mod1)
        (defun g:integer ()
          @doc   "always returns 2"
          @model (property (= result 2))
          2))
      (commit-tx)
    |]

  it "loads when topologically sorted locally" $ do
    Right replState0 <- pure eReplState0
    stateModuleData "mod2" replState0 `shouldSatisfy` isJust

  Right replState0 <- pure eReplState0
  Just (mod1, _refs) <- pure $ stateModuleData "mod1" replState0
  Just (mod2, _refs) <- pure $ stateModuleData "mod2" replState0

  resp <- runIO $ serveAndRequest 3001 $ Remote.Request [mod2, mod1] "mod2"

  it "verifies over the network" $
    "Property proven valid" == resp ^. responseBody . Remote.responseLines . ix 0
