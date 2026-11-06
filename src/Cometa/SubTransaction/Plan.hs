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

-- | Compose a sub-transaction intent with explicit resolved inputs. Building
-- preserves the specified inputs and outputs; it adds no fee, collateral or
-- change. Sign and attach the resulting sub-transaction separately.
--
-- @
-- import qualified Cometa.SubTransaction.Plan as Plan
--
-- payment input output = Plan.spend input <> Plan.payTo output
-- @
module Cometa.SubTransaction.Plan
  ( Plan,
    DeferredRedeemer,
    payTo,
    spend,
    spendWith,
    spendWithDeferredRedeemer,
    referenceInput,
    attachScript,
    mint,
    mintWithRedeemer,
    mintWithDeferredRedeemer,
    metadata,
    attachDatum,
    certificate,
    certificateWithRedeemer,
    certificateWithDeferredRedeemer,
    withdraw,
    withdrawWithRedeemer,
    withdrawWithDeferredRedeemer,
    requireSigner,
    validFrom,
    validUntil,
    requireTopLevelGuard,
    requireGuard,
    guardWithRedeemer,
    directDeposit,
    accountBalance,
    donate,
    propose,
    vote,
    voteWithRedeemer,
    voteWithDeferredRedeemer,
    resolvedInputs,
  )
where

-- IMPORTS --------------------------------------------------------------------

import Cometa.Internal.SubTransactionPlan
  ( DeferredRedeemer,
    Plan,
    accountBalance,
    attachDatum,
    attachScript,
    certificate,
    certificateWithDeferredRedeemer,
    certificateWithRedeemer,
    directDeposit,
    donate,
    guardWithRedeemer,
    metadata,
    mint,
    mintWithDeferredRedeemer,
    mintWithRedeemer,
    payTo,
    propose,
    referenceInput,
    requireGuard,
    requireSigner,
    requireTopLevelGuard,
    resolvedInputs,
    spend,
    spendWith,
    spendWithDeferredRedeemer,
    validFrom,
    validUntil,
    vote,
    voteWithDeferredRedeemer,
    voteWithRedeemer,
    withdraw,
    withdrawWithDeferredRedeemer,
    withdrawWithRedeemer,
  )
