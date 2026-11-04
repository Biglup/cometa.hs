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
{-# OPTIONS_HADDOCK hide #-}

-- | Translate private native failures into the public error vocabulary.
module Cometa.Internal.Error (fromNativeFailure) where

-- IMPORTS --------------------------------------------------------------------

import Cometa.Error (Error (..))
import qualified Cometa.Error.Code as Code
import Cometa.Internal.Failure (NativeFailure (..))

-- DEFINITIONS ----------------------------------------------------------------

-- | Preserve the operation, exact status and copied diagnostic. Contract
-- failures remain distinct from statuses reported by the native library.
fromNativeFailure :: NativeFailure -> Error
fromNativeFailure failure = case failure of
  NativeFailure operation code message -> NativeError operation (Code.fromNumber code) message
  NativeContractFailure operation -> NativeContractViolation operation
