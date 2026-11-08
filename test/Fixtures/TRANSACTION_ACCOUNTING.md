# Generated transaction accounting property provenance

`test/TransactionAccountingProperties.hs` contains original Cometa Hedgehog
properties. They adapt reviewed conservation contracts, not upstream Haskell
implementations, test frameworks, generators, ledger fixtures or state transitions.
The following primary sources were read before choosing the equations and cases.

- cardano-foundation/cardano-coin-selection
  [`57efda2eda720b9e793a6f907319cc84aa02058c`,
  `test/spec/Cardano/CoinSelection/BalanceSpec.hs`](https://github.com/cardano-foundation/cardano-coin-selection/blob/57efda2eda720b9e793a6f907319cc84aa02058c/test/spec/Cardano/CoinSelection/BalanceSpec.hs),
  cached at `/tmp/cometa-pinned-balance-spec.hs`: in particular
  `prop_addMintValueToChangeMaps_value` and
  `prop_removeBurnValueFromChangeMaps_value` establish the positive mint and
  negative burn contribution to aggregate change. Copyright 2018–2026 IOHK,
  2024–2026 Cardano Foundation; Apache-2.0. Its complete upstream NOTICE is already
  retained in [COIN_SELECTION.md](COIN_SELECTION.md#upstream-notice).
- IntersectMBO/cardano-api
  [`c2212851b06b9c2acc5bb0bfe1b8a8e8cf2be03a`,
  `cardano-api/test/cardano-api-test/Test/Cardano/Api/Experimental/Fee.hs`](https://github.com/IntersectMBO/cardano-api/blob/c2212851b06b9c2acc5bb0bfe1b8a8e8cf2be03a/cardano-api/test/cardano-api-test/Test/Cardano/Api/Experimental/Fee.hs),
  reviewed from the complete checkout cached below
  `/tmp/p15-source-cardano-api/cardano-api-c2212851b06b9c2acc5bb0bfe1b8a8e8cf2be03a`:
  `genWithdrawalFundedTx` explains the independent coin equation
  `change = input + withdrawal - output - fee`; the
  `evaluateSignedTx` balanced/mempty test motivates checking zero balance as well
  as signed surpluses and deficits. The same checkout's LICENSE is Apache-2.0;
  its NOTICE is retained verbatim below.
- IntersectMBO/cardano-ledger
  [`7827506b7518284d7f9dbbe3502a20431e513fe9`,
  `libs/cardano-ledger-binary/src/Cardano/Ledger/Binary/Encoding/Encoder.hs`](https://github.com/IntersectMBO/cardano-ledger/blob/7827506b7518284d7f9dbbe3502a20431e513fe9/libs/cardano-ledger-binary/src/Cardano/Ledger/Binary/Encoding/Encoder.hs),
  cached at `/tmp/cometa-ledger-encoder-review.hs`, with this revision recorded in
  the implementation plan's serialization audit: `encodeSet` varies tag presence
  with protocol version. This informs the tag-invariance cases; no ledger
  round-trip or Dijkstra state-transition property is imported. Apache-2.0; the
  cached upstream LICENSE `/tmp/review-ledger-license.txt` was also reviewed.

Other cached Conway RoundTrip and Dijkstra SubUtxow source files were inspected,
but their cache files do not establish a verifiable source revision. They are not
claimed as pinned test provenance or used as imported fixtures/properties here.

## What executes in native code

Every generated case assembles typed public values and calls
`Cometa.Transaction.Building`. `implicitCoin`, `subTransactionImplicitCoin`,
`imbalance`, `subTransactionImbalance`, `batchImbalance`, and `isBalanced` execute
native CBOR parsing and accounting through the binding. Production Haskell
preflight also validates snapshots and signed intermediate bounds. No direct
call to the same C implementation supplies an expected result.

The audited native checkout is cardano-c
`a19dbc9185112ab2d7126c9c28058388a37bdccc`,
`lib/src/transaction_builder/balancing/implicit_coin.c` and
`lib/src/transaction_builder/balancing/transaction_balancing.c`
(`cardano_compute_transaction_imbalance`,
`cardano_compute_sub_transaction_imbalance`,
`cardano_compute_transaction_batch_imbalance`). Native source was reviewed
to bound the contract: legacy stake deposits/refunds use the supplied current
parameter, explicit Conway certificates and proposals carry their own amounts,
pool deposits are deduplicated by pool operator, and pool retirement has no
immediate refund. These native mechanics determine supported inputs, not the
independent numerical oracle. This native tree was previously documented as
matching merged dependency pin `b98afee9de25c09f29d1c5fe4af3e538d1830d44` for the
relevant construction implementation. Native source is Copyright Biglup Labs,
Apache-2.0; no native source is copied into these properties.

## Independent equations and shrinking

Implicit totals come from generated event descriptions, before construction of
certificates. An independent integer model sums paid amounts, refunded amounts,
and distinct reward-account withdrawals. It includes all explicit deposit
certificate forms, legacy stake registration/deregistration, governance proposal
deposits and pool retirements. It does not recover expected amounts by inspecting
decoded certificates, native output or serialized fields.

For conservation, the generator constructs ample nonnegative funding and output
amounts using:

```text
outputCoin = inputCoin + withdrawal + refund
             - deposit - fee - donation - directDeposit + perturbation
outputAsset = inputAsset + signedMint + perturbation
expectedImbalance[coin] = expectedImbalance[asset] = -perturbation
```

The fee is zero for a subtransaction. Both levels use the same token identity and
different spending references: opposing imbalances can cancel in a complete
Dijkstra batch. Each local result is checked separately, and the batch expectation
is independent `Map.unionWith (+)` on raw `Integer` quantities, with zero entries
removed. `Value` construction feeds the public binding, but `Value` addition,
subtraction and normalization are not used as the oracle. Extra resolved UTxOs,
reference inputs and collateral do not add spending supply. `isBalanced` must
agree exactly with the independent empty-map condition.

Pool-registration lists shrink as lists of a small set of integer identifiers.
Distinct-identifier cardinalities independently determine deposits per body and
across the complete batch, covering duplicates within and between bodies. Retirement
refunds are excluded from these counts.

Amounts include CBOR unsigned-width boundaries 23/24, 255/256 and 65535/65536,
zero and bounded random quantities. Funding keeps all outputs positive under
shrinking; signed mint stays within native bounds; maps use distinct validated
keys; generated lists and values remain far below unsigned/signed accumulator
limits. Perturbations are chosen from negative, zero and positive alternatives.
Hedgehog reports the replay seed and shrinks these constraints together.
Classifications identify minting, burning, complete balance, surplus, deficit,
legacy events, governance deposits, retirement and duplicate pools.

Top-level empty certificate/proposal collections remain explicitly present in
the generated cases; their subtransaction counterparts are absent when empty,
as required by the subtransaction grammar.

Both tagged and untagged body encodings are fed back through public decoding
before native accounting. The equation must hold for both, and accounting must
leave the exact transaction bytes unchanged. This exercises representation
handling through the native parser; it does not claim an independent reference
CBOR serializer or hash implementation.

## Limits

These properties test bounded accounting, not ledger admission. Repeated
certificate operations on the same credential are intentional accounting inputs
and are not claimed valid against any staking/governance state. Legacy refunds
use current supplied parameters rather than historical registration deposits;
already-registered pools cannot be identified without chain state. Fees are
explicit inputs, not minimum-fee estimates. Script execution, witnesses, actual
balances in reward accounts, withdrawal authorization, mint authorization,
collateral eligibility, era validity and live-network behavior are outside this
suite. Dijkstra coverage checks local/top-level/batch arithmetic and pool deposit
scope, not ledger conformance or successful submission. Native overflow and
invalid-resolution regressions remain in the existing fixed Building tests.

## cardano-api NOTICE

```text
Copyright 2021-2025 Input Output Global Inc (IOG).

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

		http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
```
