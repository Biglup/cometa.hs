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
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import qualified Cometa.Address as Address
import Cometa.Error (Error)
import qualified Cometa.Transaction as Tx
import qualified Support.Transaction as Workflow
import Support.Wallet (WalletContext (..), required, unsigned)
import qualified Support.Wallet as Support

main :: IO ()
main = Support.entrypoint "SendLovelace" payment

payment :: WalletContext -> IO (Either Error [Tx.Transaction])
payment wallet = do
  recipient <- required "COMETA_RECIPIENT"
  lovelace <- required "COMETA_LOVELACE"
  let settings = (,) <$> (recipient >>= Address.fromText) <*> (lovelace >>= unsigned)
  case settings of
    Left failure -> pure (Left failure)
    Right (destination, amount) ->
      fmap (fmap pure) (Workflow.runPayment (context wallet) destination amount)
