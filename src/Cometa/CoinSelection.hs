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

-- | Inject coin selection with an ordinary record of functions. Validate a
-- request once, then use 'select' to check full selection and change laws. This
-- boundary selects inputs and change; it does not balance or submit transactions.
--
-- @
-- selectWith = select
-- @
module Cometa.CoinSelection
  ( Selector (..),
    SelectionOptions (..),
    SelectionRequest,
    mkSelectionRequest,
    preselected,
    available,
    target,
    outputHints,
    changeAddress,
    parameters,
    Selection (..),
    validateSelection,
    select,
  )
where

-- IMPORTS --------------------------------------------------------------------

import Cometa.Internal.CoinSelection
  ( Selection (..),
    SelectionOptions (..),
    SelectionRequest,
    Selector (..),
    available,
    changeAddress,
    mkSelectionRequest,
    outputHints,
    parameters,
    preselected,
    select,
    target,
    validateSelection,
  )
