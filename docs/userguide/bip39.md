# Recover a wallet from a BIP39 phrase

`Cometa.Crypto.Bip39` validates English recovery phrases and converts them to
and from entropy. It accepts 12, 15, 18, 21 or 24 words, corresponding to
16, 20, 24, 28 or 32 entropy bytes.

## Parse and derive a root

Use `fromText` to split words on Unicode whitespace. Leading/trailing whitespace
is ignored and `exportText` uses a single ASCII space between words. Words must
be exact lowercase entries in the English BIP39 dictionary. There is no spelling
correction, case folding or support for other language dictionaries.

```haskell
{-# LANGUAGE OverloadedStrings #-}

import qualified Cometa.Crypto.Bip39 as Bip39
import qualified Cometa.Crypto.Bip32.PrivateKey as PrivateKey
import qualified Cometa.Crypto.Bip32.PublicKey as PublicKey
import Control.Monad.Trans.Except (ExceptT (..), except, runExceptT)
import qualified Data.ByteString as ByteString
import Data.Text (Text)
import qualified Data.Text.IO as Text
import System.Exit (die)

-- Public deterministic test phrase; never use this wallet for funds.
testPhrase :: Text
testPhrase = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

main :: IO ()
main = do
  result <- runExceptT $ do
    mnemonic <- except (Bip39.fromText testPhrase)
    entropy <- except (Bip39.exportEntropy mnemonic)
    ExceptT (PrivateKey.withEntropy ByteString.empty entropy PrivateKey.publicKey)

  either (die . show) (Text.putStrLn . PublicKey.toHex) result
```

This example is also built as `cometa-bip39`; run `cabal run cometa-bip39`.
Mnemonic construction and entropy export return pure `Either Error a` values.
`ExceptT` optionally lifts those results with `except` to compose with the scoped
BIP32 key operation in `IO`; it is not required by the library. The example prints only a public key. Its
phrase is public test material and must never secure funds.

The entropy exported here feeds Cardano's Ed25519-BIP32 `withEntropy`, whose
password argument consists of raw bytes. This is distinct from the 64-byte BIP39
seed derived from a sentence and passphrase. See the [BIP32 guide](bip32.md) for
password semantics and derivation paths.

## Convert supplied entropy

`fromEntropy` requires an existing entropy byte sequence of a standard size.
Applications must obtain real-wallet entropy from a suitable secure source.
The library does not generate randomness. `fromWords` accepts individual `Text`
words; each element must contain exactly one lowercase ASCII word.

Invalid lengths/counts, non-lowercase characters, unknown dictionary words and
invalid checksums
produce structured errors: `InvalidBip39EntropyLength`, `InvalidBip39WordCount`,
`InvalidBip39Word` (one-based position), `UnknownBip39Word` and
`InvalidBip39Checksum`. These errors never echo supplied words. Other native
failures preserve their status through `NativeError`.

## Handle secret values explicitly

`Mnemonic` has neither a `Show` nor equality instance. `wordCount` is safe for
ordinary diagnostics. `exportText` and `exportEntropy` expose wallet secrets;
never log them. Input and exported text/bytes have ordinary Haskell lifetimes.
This API does not guarantee erasure of these values or every temporary copy.
A mnemonic remains usable while the application holds it; it has no close scope.
Pure evaluation may share secret values and retain them for longer; it does not
promise when or how often a conversion is evaluated.
