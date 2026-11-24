# Examples

Each file shows a complete runnable workflow: construct the plan, build, sign,
submit and confirm. Shared wallet/provider setup, compiled script programs and
address-index polling live in `Support/`. The C++ binding has the
same workflow set; `SignData.hs` corresponds to the Python/TypeScript CIP-8 example.

Local functions separate input validation, plan construction, building, signing,
submission and confirmation. They use standard `ExceptT` composition; the runner
reports errors at the outer boundary. These functions are repeated in each file
so the complete program can be read without following another example.

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

Transaction examples load an encrypted wallet, prompt for its password, build,
sign, submit and await confirmation when run without arguments. Use `--help` for
offline usage, or `--describe` to inspect public wallet/script identities.

```sh
cabal run cometa-secure-key-handler -- wallet.key
export COMETA_KEY_HANDLER_FILE="$PWD/wallet.key"
# Configure the provider, validity slot and workflow inputs as described below.
cabal run cometa-send-lovelace
```

`SecureKeyHandler` imports a recovery phrase into encrypted storage and reopens it.
`Bip39` and `SignData` are offline cryptography demonstrations using public material;
never fund their keys. `Provider --query` makes read-only chain queries. The
Dijkstra batch example uses three encrypted wallets and requires protocol 12+.

See [connected examples](../docs/userguide/connected-examples.md) for provider,
wallet and collateral configuration, and [governance examples](../docs/userguide/connected-governance.md)
for staking and proposal inputs. Multi-stage flows confirm each transaction before
continuing. Keep their printed transaction IDs if a later stage fails.
