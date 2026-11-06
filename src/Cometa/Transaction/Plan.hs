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

-- | Compose transaction requirements as owned values, then pass the complete
-- plan to 'Cometa.Transaction.Builder.build'. Plans form an ordered monoid:
-- @payTo first <> payTo second@ preserves payment order, and @mempty@ adds no
-- requirements. Conflicts are reported when building.
--
-- @
-- payment output = payTo output <> validUntil 1000000
-- @
module Cometa.Transaction.Plan
  ( Plan,
    payTo,
    spend,
    spendWith,
    DeferredRedeemer,
    spendWithDeferredRedeemer,
    mintWithDeferredRedeemer,
    certificateWithDeferredRedeemer,
    withdrawWithDeferredRedeemer,
    referenceInput,
    attachScript,
    mint,
    mintWithRedeemer,
    metadata,
    attachDatum,
    certificate,
    certificateWithRedeemer,
    withdraw,
    withdrawWithRedeemer,
    requireSigner,
    validFrom,
    validUntil,
    requireGuard,
    guardWithRedeemer,
    directDeposit,
    accountBalance,
    startingAccountBalance,
    donate,
    propose,
    vote,
    voteWithRedeemer,
    voteWithDeferredRedeemer,
    attachSubTransaction,
  )
where

-- IMPORTS --------------------------------------------------------------------

import Cometa.Internal.TransactionPlan
  ( DeferredRedeemer,
    Plan,
    accountBalance,
    attachDatum,
    attachScript,
    attachSubTransaction,
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
    spend,
    spendWith,
    spendWithDeferredRedeemer,
    startingAccountBalance,
    validFrom,
    validUntil,
    vote,
    voteWithDeferredRedeemer,
    voteWithRedeemer,
    withdraw,
    withdrawWithDeferredRedeemer,
    withdrawWithRedeemer,
  )
