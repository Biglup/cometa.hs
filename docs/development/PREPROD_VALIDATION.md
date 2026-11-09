# Preprod validation — 2026-11-09

All 16 supported connected example flows completed on preprod. All 36 submitted
transactions were confirmed and returned `valid_contract: true` in independent
Blockfrost transaction queries. No binding or native-library fix was required.

## Tested configuration

- Cometa.hs: `7b272b6f98781f9d5307dd0e7cf306518cb58f82` (merged PR31).
- cardano-c: `c5edc7c8f16b3980b6e97ef7fda80fef94adf980`.
- Native static archive SHA-256: `3a13dbc4b3963e311ae1b08a1b1dea2d957420731ed26eee2d2a71b54b6559cc`.
- Linux x86-64, GHC 9.6.7; `cabal build all` completed before the run.
- Preprod epoch 324, protocol 11, checked before and after execution.
- Existing example wallet, with fresh stake/DRep authority index 702.
- Native evaluation and the official Blockfrost preprod provider.

Credentials and wallet storage were supplied outside the repository. Wallet
identity, funds, collateral, reference outputs, registration state, pool status,
proposal eligibility and the current constitution were checked before submission.
Each dependent stage waited for confirmation and wallet indexing.

## Results

| Flow | Confirmed transactions | Fees (ADA) | Net deposit (ADA) |
| --- | ---: | ---: | ---: |
| Self-payment | 1 | 0.177513 | 0 |
| Native mint and burn | 2 | 0.379578 | 0 |
| Plutus mint and burn | 2 | 0.571601 | 0 |
| Native-script funding and spend | 2 | 0.356214 | 0 |
| V3 validator/reference funding and spend | 2 | 0.625511 | 0 |
| Deferred self-index | 2 | 0.376389 | 0 |
| Deferred two-order settlement | 3 | 0.584630 | 0 |
| Key staking cycle | 2 | 0.369370 | 0 |
| V2 script staking cycle | 2 | 0.548924 | 0 |
| V3 deferred zero-withdrawal cycle | 2 | 0.420036 | 0 |
| Key DRep registration/delegation cycle | 4 | 0.734164 | 0 |
| V3 DRep registration/delegation cycle | 4 | 1.113496 | 0 |
| Key DRep voting cycle | 3 | 0.603929 | 0 |
| V3 DRep voting cycle | 3 | 1.141893 | 0 |
| Treasury donation | 1 | 0.174829 | 0 |
| Treasury withdrawal proposal | 1 | 0.258278 | 1000 |

## Funds and cleanup

- Stake/DRep deposits paid and returned: **2,010 ADA**. All three test stake
  accounts are unregistered with zero withdrawable rewards; both key and script
  DReps are inactive and retired.
- The treasury proposal retains its **1,000 ADA** governance deposit until the
  proposal reaches its outcome. Submission does not execute the proposed withdrawal.
- Transaction fees: **8.436355 ADA**. Treasury donation: **2 ADA**.
- Wallet balance changed from **110,609.530639 ADA** to **109,599.094284 ADA**:
  exactly fees + donation + the outstanding proposal deposit.
- Both mint/burn examples retained one Raspberry token, as designed. All other
  wallet asset quantities are unchanged, including the net Onyx quantities.
- Every script output funded by the spending/deferred examples was consumed by
  its intended spending or settlement transaction. The two deferred orders were
  funded separately and consumed together.
- The 30-ADA key-controlled validator reference output was subsequently spent
  by the key-voting flow. Its value remains accounted for in the wallet balance.
- Reserved collateral and the pre-existing wallet, governance and constitution
  reference outputs remain unspent.
- Independent vote receipts confirm both **Yes** votes targeted
  `8751ca96591ae84d16c35d0d232c1b24f1c846bc31a602c6f9eb492567fb99a8#0`.

The first key-stake cleanup query briefly returned the previous registered state
although its cleanup transaction was confirmed. A read-only recheck returned the
unregistered state. Later cleanup checks used bounded read polling; no accepted
transaction was resubmitted.

## Dijkstra

Preprod remained at protocol 11. No Dijkstra transaction was submitted.

All 25 offline Dijkstra/subtransaction builder tests passed, together with the
buyer/seller/batcher signed-swap example. The actual connected runner's protocol
gate was exercised with an offline provider reporting protocol 11: it returned
`InvalidBuildingRequest` with zero submissions to the fixture provider. Live
Dijkstra acceptance remains untested until a compatible network is available.

## Transaction journal

IDs below are ordered by stage within each flow. The corresponding preprod
transaction records provide block inclusion, fees, deposits, redeemers and
ledger validity; their UTxO records establish output consumption and asset deltas.

### Self-payment

- `56c64693a022a0e61303e67555e5cb9fcf797029ecf2d5679df5568216d5a2ab`

### Native mint and burn

- `5105e541c3b09a0e62668d9e9f4e92e8e8680cbc6b6e232fba3c45efcc70efc3`
- `c0deb78bae8af9009fef4e040d5a1a6ff3dc74ffdc2f9b6d9f13d34ef331bd6d`

### Plutus mint and burn

- `ca9a46e4f6e0befcafd49596893a5409255abcb86157a8da37293a2420ff2418`
- `185812d6d649bc0921a511a1f84ff7d08c8e88db31f98dcc7fdd358043156542`

### Native-script funding and spend

- `1fb2546182b10c4e35f77ffff27db3d427a3557558baca6f4c3f4a714c99318c`
- `c8f98960be661df86d576b8180003d93244f795b55fc1459734f46b4620fffa9`

### V3 validator/reference funding and spend

- `c168b67384d46388b3f549a125960c97769d2f2e9c3fb22ed0dafabfb04c156e`
- `b87f5802cbb57779858f0394532a11696cbc5d5539b61b27f58624ae3a3e8632`

### Deferred self-index

- `0b0e57388bc24bf4588918845cafe47f2e06dee34ab529e68d89d298d7ffd3fd`
- `6908fceb8799077be16cf2713c6e18381011c65906e414a92bc0e4fa069cf5a3`

### Deferred two-order settlement

- `f0ea96944c301d7d0d65967f77db2a84b61d12fe71c74ddc79b2613136c4201c`
- `41dd9ca1b72272150a63e0dd66ee49ee5d171bd13449297cb9e36bd3c650ac7c`
- `973499fb0c37134460e4f9f7e9c16c31c76062f7ef865ac9846e1455beed730c`

### Key staking cycle

- `d46c7204181ae7651ed61fb91c84167d8da5fea4a6ad7867d16a75bfc6c64a62`
- `14407b8c0e8b182f15904afdd1e9beda782dd625824497db316e205b2dbd7758`

### V2 script staking cycle

- `8c8b147d61d7d15b9f8388f3e7512fc0f6bbd75d924615d3cdbca0201d935e93`
- `b5792b41709daa683dc9588bee870ae67c559f7e3978c888fce701c24fb3a8fb`

### V3 deferred zero-withdrawal cycle

- `70c084ecc3798ef98e5949bb723001d5b4643bcd3e5fb6aef998ceea1e5632f4`
- `2abc6fb9d2cbd9f6ab6f305326222accfffa76e3fe35956d0bbddd355edd693d`

### Key DRep registration/delegation cycle

- `e2228af9478b380ffcda942e15756e69303a5289545c725cf0b718434bef908b`
- `42345152e8b0bb0b6af52597d9975f221d440ad4bb2ebd539cde840c18ddc7bb`
- `6ca653e10f914c7c2baf1c6696e62d742ecbd3dd9af0f22f2f400bb8ba053353`
- `fe6184ad465f6febc4f3b1166e2fa28549b9215f6f391ab5c1c65cc5ebbee7b4`

### V3 DRep registration/delegation cycle

- `80365e6112dfb3a98272dfef94d6230d592fd20778cb58ef1178a29961359ff9`
- `0c0468055506af13d67537befaa877d8eb81d8a430992d09989c6b0ccdff32ad`
- `55fd30d709d35644da1caee0a3da3ccf747ac971781fa36421ba681b9ee28201`
- `47134a5e64e995b1bca3e4c2ced4cfb8c53b8a19015d8a1a46437f3ab9b4f5e0`

### Key DRep voting cycle

- `95b2fc4463da50ba4f2ccaa03bdeefd25ee07767030b83447a45f44f5100bc74`
- `fca0dc71664d6ff6852e4f30cc44b02abb9cbf93c37a976903bed0a02320c7d6`
- `f45c78aae458c0eda17df5c1690942b0156e45b1ef7c8b4853d9800f17a402cf`

### V3 DRep voting cycle

- `d4d68a4434e7f06a9fdcfcddd93410514b56b73a281fd9787f932f901cb80314`
- `524b0a9ab18881d76152bcabcd4847dcc65bff470eac945c9514953e2a7923a8`
- `b102be7b08ad7a89eba5e60ef6017649ad05518aadee83b6c44459b98452ab64`

### Treasury donation

- `903de41179052de9cd6fb6420433e2d3eebe981270965e069611f3c714f3c5ef`

### Treasury withdrawal proposal

- `863ddcc4db561be3463e52dddcf91d7bec85edc22754b0b86863cd4306c35af5`

