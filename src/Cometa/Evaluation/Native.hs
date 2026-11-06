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

-- | Execute compiled Plutus V1–V4 scripts in process with explicit protocol
-- context. Evaluation returns budgets without installing them or changing the
-- enclosing transaction. Script availability depends on the protocol version.
--
-- @
-- import qualified Cometa.Evaluation as Evaluation
-- import qualified Cometa.Evaluation.Native as Native
-- import qualified Cometa.Protocol.CostModels as Models
-- import qualified Cometa.SlotConfig as Slots
--
-- localEvaluator = Native.evaluator (Native.Config Slots.preview 12 Models.empty)
-- -- Evaluation.evaluate localEvaluator Evaluation.TopLevel transaction resolved
-- @
module Cometa.Evaluation.Native (Config (..), evaluator) where

-- IMPORTS --------------------------------------------------------------------

import Cometa.Internal.Evaluation.Native (Config (..), evaluator)
