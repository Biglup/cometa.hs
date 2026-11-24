# Examples

Each file is one runnable workflow. Shared wallet configuration, script programs
and transaction submission helpers live in `Support/`. The C++ binding has the
same workflow set; `SignData.hs` corresponds to the Python/TypeScript CIP-8 example.

| Source | Cabal target |
| --- | --- |
| [Bip39.hs](Bip39.hs) | `cometa-bip39` |
| [SecureKeyHandler.hs](SecureKeyHandler.hs) | `cometa-secure-key-handler` |
| [Provider.hs](Provider.hs) | `cometa-provider` |
| [SubTransactionBatch.hs](SubTransactionBatch.hs) | `cometa-sub-transaction-batch` |
| [SignData.hs](SignData.hs) | `cometa-sign-data` |
| [SendLovelace.hs](SendLovelace.hs) | `cometa-send-lovelace` |
| [MintBurnNativeScript.hs](MintBurnNativeScript.hs) | `cometa-mint-burn-native-script` |
| [MintBurnPlutusScript.hs](MintBurnPlutusScript.hs) | `cometa-mint-burn-plutus-script` |
| [SpendFromNativeScript.hs](SpendFromNativeScript.hs) | `cometa-spend-from-native-script` |
| [SpendFromValidator.hs](SpendFromValidator.hs) | `cometa-spend-from-validator` |
| [DeferredRedeemerSelfIndex.hs](DeferredRedeemerSelfIndex.hs) | `cometa-deferred-self-index` |
| [DeferredRedeemerBatch.hs](DeferredRedeemerBatch.hs) | `cometa-deferred-batch` |
| [RewardAccountPubkey.hs](RewardAccountPubkey.hs) | `cometa-reward-account-pubkey` |
| [RewardAccountScript.hs](RewardAccountScript.hs) | `cometa-reward-account-script` |
| [DRepPubkey.hs](DRepPubkey.hs) | `cometa-drep-pubkey` |
| [DRepScript.hs](DRepScript.hs) | `cometa-drep-script` |
| [VoteForProposalPubkey.hs](VoteForProposalPubkey.hs) | `cometa-vote-for-proposal-pubkey` |
| [VoteForProposalScript.hs](VoteForProposalScript.hs) | `cometa-vote-for-proposal-script` |
| [DonateToTreasury.hs](DonateToTreasury.hs) | `cometa-donate-to-treasury` |
| [ProposeTreasuryWithdrawal.hs](ProposeTreasuryWithdrawal.hs) | `cometa-propose-treasury-withdrawal` |
| [DeferredWithdrawZero.hs](DeferredWithdrawZero.hs) | `cometa-deferred-withdraw-zero` |
| [PlutusV4GuardedSubTransaction.hs](PlutusV4GuardedSubTransaction.hs) | `cometa-plutus-v4-guarded-subtransaction` |

`Bip39`, `SecureKeyHandler`, `SignData` and `SubTransactionBatch` run offline with
public demonstration material. Never fund their keys. The other examples print
usage without making network requests when run without arguments. `Provider`
uses `--query`; transaction examples use `--describe` or `--submit`.

See [connected examples](../docs/userguide/connected-examples.md) for provider,
wallet and collateral configuration, and [governance examples](../docs/userguide/connected-governance.md)
for staking and proposal inputs. Multi-stage flows confirm each transaction before
continuing. Keep their printed transaction IDs if a later stage fails.
