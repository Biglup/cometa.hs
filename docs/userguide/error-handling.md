# Validation and errors

Pure validation returns `Either Error a`. Combine related inputs in ordinary
`do` notation; once validated, reuse the resulting values.

```haskell
import qualified Cometa.AssetId as AssetId
import qualified Cometa.AssetName as AssetName
import Cometa.Error (Error)
import qualified Cometa.PolicyId as PolicyId
import Data.Text (Text)

assetFromText :: Text -> Text -> Either Error AssetId.AssetId
assetFromText policyText nameText = do
  policy <- PolicyId.fromHex policyText
  name <- AssetName.fromText nameText
  pure (AssetId.Native policy name)
```

Native and network operations return `IO (Either Error a)`. Use a `case` for a
single operation. For several dependent operations, `ExceptT` gives a straight
sequence that stops at the first error:

```haskell
import qualified Cometa.Signer as Signer
import qualified Cometa.Transaction as Tx
import qualified Cometa.TransactionId as TxId
import Control.Monad.Trans.Except (ExceptT (..), except, runExceptT)

signAndIdentify :: Signer.Signer -> Tx.Transaction
  -> IO (Either Error (Tx.Transaction, TxId.TransactionId))
signAndIdentify signer unsigned = runExceptT $ do
  witnesses <- ExceptT (Signer.signTransaction signer unsigned)
  signed <- except (Tx.addWitnesses witnesses unsigned)
  identifier <- ExceptT (Tx.transactionId signed)
  pure (signed, identifier)
```

`except` lifts a pure `Either` into the sequence; it does not throw an IO
exception. Keep pure validation in its own function when several fields need
checking. Handle the final `Either` once in the application, and leave cancellation
and unexpected IO exceptions to the usual IO exception machinery.

This follows the separation used by
[Aeson's pure and file decoders](https://hackage-content.haskell.org/package/aeson-2.2.3.0/docs/Data-Aeson.html)
and the standard
[transformers error transformer](https://hackage-content.haskell.org/package/transformers-0.6.1.2/docs/Control-Monad-Trans-Except.html).
There is no Cometa-specific error monad or requirement to use transformers.

[Cryptonite 0.30](https://hackage-content.haskell.org/package/cryptonite-0.30/docs/Crypto-Error.html)
also represents expected validation failures as values, using its `CryptoFailable`
type. Cometa uses standard `Either Error` so callers need no extra conversion.
