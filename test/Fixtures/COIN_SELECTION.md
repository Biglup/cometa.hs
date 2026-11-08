# Native coin selection property provenance

The generated properties in `test/NativeCoinSelection.hs` adapt contracts reviewed
at cardano-foundation/cardano-coin-selection revision
`57efda2eda720b9e793a6f907319cc84aa02058c` (retrieved 2026-11-08):

- [`test/spec/Cardano/CoinSelection/BalanceSpec.hs`](https://github.com/cardano-foundation/cardano-coin-selection/blob/57efda2eda720b9e793a6f907319cc84aa02058c/test/spec/Cardano/CoinSelection/BalanceSpec.hs):
  `prop_runSelection_UTxO_exactlyEnough`,
  `prop_runSelection_UTxO_moreThanEnough`,
  `prop_runSelection_UTxO_notEnough`, `genMakeChangeData`,
  `prop_splitBundlesWithExcessiveAssetCounts_sum`, and
  `prop_splitBundlesWithExcessiveTokenQuantities_length`/`_sum`.
- [`test/gens/Cardano/CoinSelection/Types/TokenBundle/Gen.hs`](https://github.com/cardano-foundation/cardano-coin-selection/blob/57efda2eda720b9e793a6f907319cc84aa02058c/test/gens/Cardano/CoinSelection/Types/TokenBundle/Gen.hs):
  `genTokenBundleSmallRangePositive` and its interleaved positive-coin shrinker.

These are Apache-2.0 sources. BalanceSpec records copyright 2018–2026 IOHK and
2024–2026 Cardano Foundation. The upstream LICENSE was retrieved at the same
revision and is the Apache License, Version 2.0, reproduced in this repository's
`LICENSE`. Its NOTICE is retained verbatim below. Test implementations here are
new Haskell adaptations of the contracts, with Hedgehog generators and integrated
shrinking in place of upstream QuickCheck generators; no upstream implementation
or generator source is vendored.

## Execution and independent expectations

Every generated case calls public `Cometa.CoinSelection.select` with actual native
largest-first, seeded random-improve Optimal, and seeded random-improve Minimal
selectors. The seeds are generated and retained in Hedgehog failure reports.
Selections need not agree between strategies. Shrinking preserves positive input
bundles, uniquely indexed input references, ample change Ada in solvable cases,
and a strict supply deficit in failure cases.

The new properties check exact/surplus supply, mandatory input preservation with
both disjoint and overlapping available sets, full input snapshot membership,
unique selected and remaining references, remaining-set equality, per-asset
conservation, change destination/nonnegativity, Babbage minimum Ada, serialized
bundle limits, and positive token quantities including CBOR width transitions
and the signed int64 endpoint. The independent accounting model sums raw
association lists into `Map AssetId Integer`; it does not use `Value` addition,
`validateSelection`, or a direct call to the same C selector as an oracle.
Minimum Ada is `(160 + outputBytesAtMinimumCoinWidth) * 4310`; the generated
plain enterprise outputs keep this amount in the five-byte CBOR coin range.
The width is asserted. Public Haskell output/value encoders supply lengths,
with no native minimum-Ada oracle. Size checks reserve the total Ada supply's
coin width to match the documented native size assessment.

These properties complement existing fixed native regression tests and the
Ada-only accounting property. They add generated multiasset membership/accounting,
mandatory overlap, coin-versus-token deficits and bundle splitting. The generated
known-solvable cases have bounded small asset universes and generous Ada; they do
not claim every mathematically feasible heuristic input succeeds. Native
insufficient supply must report status 1100 (`CARDANO_ERROR_BALANCE_INSUFFICIENT`),
not merely any error.

## Adaptation limits

Upstream `runSelection` returns a depleted partial selection for insufficient
supply; Cometa's complete selection operation must fail. Nonempty positive inputs
avoid the different empty/zero-target contracts already covered by fixed cases.
The native public selector splits bundles by maximum serialized value size; it
does not expose upstream's independently configurable maximum token quantity.
The adaptation therefore checks conservation and int64 quantity bounds across
size splitting, including endpoint quantities, without claiming configurable
quantity splitting. Upstream's mock constraints and collateral selector are not
imported. The target is already the net externally assessed payment/fee/deposit/
refund/mint/burn requirement; this first slice does not claim generated builder
fee assessment, mint/burn, deposit/refund, collateral, or ledger acceptance coverage.

## Upstream NOTICE

```text
cardano-coin-selection

Copyright 2018-2022 IOHK
Copyright 2023-2026 Cardano Foundation

This product includes software developed at IOHK
(https://iohk.io/) as part of the cardano-wallet project
(https://github.com/cardano-foundation/cardano-wallet).

Original authors and contributors
----------------------------------

The coin selection algorithm, data structures, and primitive types were
designed and implemented primarily by:

  Jonathan Knowles          — round-robin algorithm, change generation,
                              collateral selection, UTxO index/selection,
                              TokenMap, TokenBundle, Coin, numeric utilities
  Matthias Benkort (KtorZ)  — original coin selection design
  Pawel Jakubas             — original coin selection, UTxO index

With contributions from:

  Heinrich Apfelmus         — coin selection
  Johannes Lund (Anviking)  — early coin selection
  Yura (Unisay)             — coin selection, numeric utilities
  Rodney Lorrimar           — numeric utilities
  Erik de Castro Lopo       — coin selection
  Jean-Baptiste Giraudeau   — numeric utilities
  Piotr Stachyra            — coin selection

Forked and maintained by:

  Paolo Veronelli           — Cardano Foundation (High Assurance Lab)
```
