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

-- | Complete an existing transaction using explicit wallet and ledger snapshots.
-- Balancing returns an unsigned copy; it never changes the supplied transaction.
module Cometa.Transaction.Balancing (balance, balanceWithRedeemers) where

-- IMPORTS --------------------------------------------------------------------

import Cometa.Internal.TransactionBalancing (balance, balanceWithRedeemers)
