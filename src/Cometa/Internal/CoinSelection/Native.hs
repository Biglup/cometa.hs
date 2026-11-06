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
{-# OPTIONS_HADDOCK hide #-}

-- | Private adapter scopes used by native builder integration and dispatch tests.
-- Public direct selection does not acquire a callback registration. Factories and
-- native invokes run inside the shared operation gate, which contains callback
-- exceptions and joins cancellation before releasing native or Haskell owners.
module Cometa.Internal.CoinSelection.Native (withSelector, invoke, invokeWith, dispatch) where

-- IMPORTS --------------------------------------------------------------------

import Cometa.Error (Error (..))
import Cometa.Internal.CoinSelection (Selection, SelectionRequest, Selector)
import qualified Cometa.Internal.CoinSelection as Selection
import qualified Cometa.Internal.FFI.CoinSelection as Native
import Cometa.Internal.Runtime (Dispatch, Runtime)
import qualified Cometa.Internal.Runtime as Runtime

-- DEFINITIONS ----------------------------------------------------------------

withSelector :: Selector -> (Runtime -> IO (Either Error a)) -> IO (Either Error a)
withSelector selector = Runtime.withRuntime (dispatch selector)

dispatch :: Selector -> Dispatch
dispatch selector operation bytes
  | operation /= 200 = pure (Left (InvalidSelectionRequest "Unknown selector operation"))
  | otherwise = case Selection.decodeRequest bytes of
      Left failure -> pure (Left failure)
      Right request -> fmap Selection.encodeSelection <$> Selection.select selector request

invoke :: Selector -> SelectionRequest -> IO (Either Error Selection)
invoke selector request = withSelector selector (`invokeWith` request)

invokeWith :: Runtime -> SelectionRequest -> IO (Either Error Selection)
invokeWith runtime request = do
  response <- Runtime.withOperation runtime $ \context ->
    Runtime.withBytes (Selection.encodeRequest request) $ \bytes size ->
      Runtime.withOwnedBuffer "coinSelection.nativeDispatch" (Native.cSelect context bytes size)
  pure (response >>= Selection.decodeSelection >>= checked)
  where
    checked value = Selection.validateSelection request value >> pure value
