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

-- | Private representation shared by scoped Ed25519 and BIP32 acquisition.
module Cometa.Internal.Ed25519SigningKey (SigningKey (..)) where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Internal.SigningKey as Internal

-- TYPES ----------------------------------------------------------------------

-- | An opaque scoped secret. Escaping a scope does not extend its usable lifetime.
-- Keys of both supported formats use the same operations.
newtype SigningKey = SigningKey Internal.Key
