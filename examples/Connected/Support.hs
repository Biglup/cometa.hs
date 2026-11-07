-- Copyright 2026 Biglup Labs
-- SPDX-License-Identifier: Apache-2.0
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     https://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Scoped configuration for the explicitly submitted connected examples.
module Connected.Support (WalletContext (..), entrypoint, entrypointWithDescription, required, unsigned, resolveReference) where

-- IMPORTS --------------------------------------------------------------------

import qualified Blockfrost.Common as Common
import qualified Cometa.Address as Address
import qualified Cometa.Address.Reward as Reward
import qualified Cometa.Address.Shelley as Shelley
import Cometa.Credential (Credential, DRep, Payment, Stake)
import qualified Cometa.Credential as Credential
import qualified Cometa.Crypto.Bip32.PublicKey as Public
import qualified Cometa.Crypto.DerivationPath as Path
import Cometa.Error (Error (..))
import qualified Cometa.KeyHandler.Software as Software
import qualified Cometa.Provider as Provider
import qualified Cometa.Provider.Blockfrost as Blockfrost
import qualified Cometa.Signer as Signer
import qualified Cometa.SubTransaction as Sub
import qualified Cometa.Transaction as Tx
import qualified Cometa.Transaction.Input as Input
import Cometa.Transaction.Utxo (Utxo)
import qualified Cometa.Transaction.Utxo as Utxo
import qualified Cometa.TransactionId as Id
import Control.Monad (void)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Except (ExceptT (..), except, runExceptT)
import qualified Data.ByteString as Bytes
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import qualified Data.Text.IO as Text
import Data.Word (Word64)
import Numeric (showHex)
import System.Environment (getArgs, lookupEnv)
import System.Exit (die)
import System.IO (hFlush, stdout)
import Text.Read (readMaybe)
import qualified Workflows.Native as Native

-- TYPES ----------------------------------------------------------------------

data WalletContext = WalletContext
  { context :: Native.Context,
    paymentCredential :: Credential Payment,
    stakeCredential :: Credential Stake,
    drepCredential :: Credential DRep,
    signSubTransaction :: Sub.SubTransaction -> IO (Either Error Sub.SubTransaction)
  }

-- DEFINITIONS ----------------------------------------------------------------

required :: String -> IO (Either Error Text)
required = Common.required

unsigned :: Text -> Either Error Word64
unsigned text = case readMaybe (Text.unpack text) :: Maybe Integer of
  Just value | value >= 0 && value <= toInteger (maxBound :: Word64) -> Right (fromInteger value)
  _ -> Left (InvalidProviderConfiguration "Expected an unsigned 64-bit decimal value")

reference :: Text -> Either Error Input.Input
reference text = case Text.splitOn "#" text of
  [hash, index] -> Input.input <$> Id.fromHex hash <*> unsigned index
  _ -> Left (InvalidProviderConfiguration "Expected a transaction output reference TXID#INDEX")

resolveReference :: Native.Context -> String -> IO (Either Error Utxo)
resolveReference ctx variable = runExceptT $ do
  ref <- ExceptT (required variable) >>= except . reference
  values <- ExceptT (Provider.resolveInputs (Native.provider ctx) [ref])
  except $ case values of
    [value] -> Right value
    _ -> Left (InvalidBuildingRequest "Configured reference output is absent or spent")

entrypoint :: String -> (WalletContext -> IO (Either Error [Tx.Transaction])) -> IO ()
entrypoint name = entrypointWithDescription name (const (pure (Right [])))

entrypointWithDescription :: String -> (WalletContext -> IO (Either Error [(Text, Text)])) -> (WalletContext -> IO (Either Error [Tx.Transaction])) -> IO ()
entrypointWithDescription name describe run = do
  arguments <- getArgs
  case arguments of
    ["--describe"] -> execute $ \wallet -> runExceptT $ do
      liftIO (printWallet wallet)
      extra <- ExceptT (describe wallet)
      liftIO (mapM_ (\(label, value) -> Text.putStrLn (label <> ": " <> value)) extra)
    ["--submit"] -> execute $ \wallet -> fmap void (run wallet)
    _ -> putStrLn (name <> ": use --describe for public identifiers or --submit to run the complete confirmed workflow; see the connected examples guide.")
  where
    execute action = do
      configured <- Common.configuration
      result <- case configured of
        Left failure -> pure (Left failure)
        Right config -> Blockfrost.withProvider config $ \backend -> withWallet config (journal backend) action
      either (die . show) pure result

printWallet :: WalletContext -> IO ()
printWallet wallet = do
  Text.putStrLn ("Wallet: " <> Address.toText (Native.wallet (context wallet)))
  Text.putStrLn ("Stake account: " <> Reward.toText (Reward.fromCredential (Native.network (context wallet)) (stakeCredential wallet)))
  let bytes = case drepCredential wallet of
        Credential.KeyCredential hash -> Credential.keyHashBytes hash
        Credential.ScriptCredential hash -> Credential.scriptHashBytes hash
      hexByte value = let digits = showHex value "" in if length digits == 1 then '0' : digits else digits
  Text.putStrLn ("DRep credential hash: " <> Text.pack (concatMap hexByte (Bytes.unpack bytes)))

journal :: Provider.Provider -> Provider.Provider
journal backend =
  backend
    { Provider.submitTransaction = \tx -> do
        result <- Provider.submitTransaction backend tx
        case result of
          Right identifier -> Text.putStrLn ("Accepted: " <> Id.toHex identifier) >> hFlush stdout
          Left _ -> pure ()
        pure result,
      Provider.awaitTransaction = \identifier timeout -> do
        result <- Provider.awaitTransaction backend identifier timeout
        case result of
          Right True -> Text.putStrLn ("Confirmed: " <> Id.toHex identifier) >> hFlush stdout
          _ -> pure ()
        pure result
    }

withWallet :: Blockfrost.Config -> Provider.Provider -> (WalletContext -> IO (Either Error a)) -> IO (Either Error a)
withWallet config backend action = do
  settings <- runExceptT $ do
    file <- ExceptT (required "COMETA_KEY_HANDLER_FILE")
    password <- ExceptT (required "COMETA_KEY_PASSWORD")
    expiry <- ExceptT (required "COMETA_INVALID_AFTER_SLOT") >>= except . unsigned
    collateralText <- liftIO (lookupEnv "COMETA_COLLATERAL")
    reserved <- except (traverse reference (maybe [] (Text.splitOn "," . Text.pack) collateralText))
    protectedText <- liftIO (lookupEnv "COMETA_RESERVED_INPUTS")
    protected <- except (traverse reference (maybe [] (Text.splitOn "," . Text.pack) protectedText))
    stakeIndex <- indexSetting "COMETA_STAKE_INDEX"
    drepIndex <- indexSetting "COMETA_DREP_INDEX"
    pure (file, password, expiry, reserved, protected, stakeIndex, drepIndex)
  case settings of
    Left failure -> pure (Left failure)
    Right (file, password, expiry, reserved, protected, stakeIndex, drepIndex) -> do
      stored <- Bytes.readFile (Text.unpack file)
      let network = Common.addressNetwork (Blockfrost.network config)
          selectionBackend = backend {Provider.utxosAt = fmap (fmap (filter ((`notElem` protected) . Utxo.input))) . Provider.utxosAt backend}
          makeContext address signer count = Native.Context selectionBackend address signer network (Common.networkSlots (Blockfrost.network config)) expiry reserved count 300000
          finish payment stake drep address signer count signLocal = action (WalletContext (makeContext address signer count) payment stake drep signLocal)
      Software.withSerialized stored (pure (Text.encodeUtf8 password)) $ \case
        Software.Ed25519Handler handler -> runExceptT $ do
          public <- ExceptT (Software.publicKey handler)
          payment <- ExceptT (Credential.fromPublicKey public)
          stake <- ExceptT (Credential.fromPublicKey public)
          drep <- ExceptT (Credential.fromPublicKey public)
          let address = Address.ShelleyAddress (Shelley.enterprise network payment)
              signLocal sub = fmap (>>= (`Sub.addWitnesses` sub)) (Software.signSubTransaction handler sub)
          ExceptT (finish payment stake drep address (Signer.software handler) 0 signLocal)
        Software.Bip32Handler handler -> runExceptT $ do
          let account = Path.standardAccountPath minBound
              paymentPath = Path.derivationPath account Path.externalRole minBound
              addressStakePath = Path.derivationPath account Path.stakingRole minBound
              stakePath = Path.derivationPath account Path.stakingRole stakeIndex
              drepPath = Path.derivationPath account Path.drepRole drepIndex
              paths = paymentPath :| [stakePath, drepPath]
          accountKey <- ExceptT (Software.accountPublicKey handler account)
          let credential path = ExceptT (Public.derive accountKey (Path.relativeIndices path)) >>= ExceptT . Credential.fromPublicKey . Public.toEd25519
          payment <- credential paymentPath
          addressStake <- credential addressStakePath
          stake <- credential stakePath
          drep <- credential drepPath
          let address = Address.ShelleyAddress (Shelley.base network payment addressStake)
              signLocal sub = fmap (>>= (`Sub.addWitnesses` sub)) (Software.signSubTransactionAt handler paths sub)
          ExceptT (finish payment stake drep address (Signer.bip32 handler paths) 2 signLocal)
  where
    indexSetting name = do
      value <- liftIO (lookupEnv name)
      case value of
        Nothing -> except (Path.mkIndex 701)
        Just text -> case readMaybe text of
          Nothing -> except (Left (InvalidProviderConfiguration "Invalid authority derivation index"))
          Just index -> except (Path.mkIndex index)
