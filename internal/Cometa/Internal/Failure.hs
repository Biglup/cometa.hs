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

-- | Private snapshots of native failures. Public domain adapters translate these
-- into their own error types after native diagnostics have been copied.
module Cometa.Internal.Failure
  ( NativeFailure (..),
  )
where

-- IMPORTS --------------------------------------------------------------------

import Data.Text (Text)

-- TYPES ----------------------------------------------------------------------

-- | Native status, copied context, and contract failures without a dependency on
-- a public domain API. Numeric codes remain exact, including unknown values.
data NativeFailure
  = -- | Operation label, exact native status, and copied diagnostic.
    NativeFailure !Text !Integer !Text
  | -- | Operation label for a successful status with an invalid native result.
    NativeContractFailure !Text
  deriving (Eq, Show)
