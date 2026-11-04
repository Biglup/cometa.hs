# Derive BIP32 keys

Cardano Ed25519-BIP32 keys combine an expanded Ed25519 key with a chain code.
A private key contains 96 bytes; a public key contains 64 bytes. Use
`Cometa.Crypto.Bip32.PrivateKey` for scoped secrets and
`Cometa.Crypto.Bip32.PublicKey` for immutable public values.

## Derive a payment public key

`withEntropy` takes raw password bytes followed by raw BIP39 entropy. Entropy
must contain 16, 20, 24, 28, or 32 bytes. Passwords can be empty and can contain
NUL bytes. Supply already normalized bytes if your application uses a text
password: this function performs no text normalization. It does not accept a
mnemonic sentence or the 64-byte BIP39 seed produced from one.

The example derives the CIP-1852 path `1852'/1815'/0'/0/0`. An apostrophe denotes
a hardened index. `harden` sets the high bit of the encoded 32-bit index and is
idempotent; ordinary indices below `2^31` select soft derivation. Path elements
are applied in order. An empty path makes an independent private-key copy.

```haskell
{-# LANGUAGE OverloadedStrings #-}

import qualified Cometa.Crypto.Bip32.PrivateKey as PrivateKey
import qualified Cometa.Crypto.Bip32.PublicKey as PublicKey
import qualified Data.ByteString as ByteString
import qualified Data.Text.IO as Text

main :: IO ()
main = do
  -- Deterministic test entropy; never use this key for funds.
  let entropy = ByteString.replicate 16 0
      accountPath = map PrivateKey.harden [1852, 1815, 0]

  result <- PrivateKey.withEntropy "" entropy $ \root ->
    PrivateKey.withDerived root accountPath $ \account ->
      PrivateKey.withDerived account [0, 0] PrivateKey.publicKey

  case result of
    Left failure -> print failure
    Right public -> Text.putStrLn (PublicKey.toHex public)
```

The complete example is built as `cometa-bip32`; run it with `cabal run cometa-bip32`.
Its deterministic entropy is test data and must never secure an application wallet.

`withKey` imports an existing 96-byte key; `withKeyHex` accepts 192 hexadecimal
digits. Imports validate length, not scalar validity. Callbacks return
`IO (Either Error a)`, combining acquisition and action failures in one result.
Exceptions and cancellation propagate after the current scope closes.

## Work with public keys

`PublicKey.fromBytes` accepts exactly 64 bytes. `fromHex` accepts 128 ASCII
hexadecimal digits in either case, without a prefix or whitespace. Both check
length; an invalid curve point can fail later derivation. `toBytes` preserves the
exact bytes and `toHex` produces lowercase text. Equality and ordering compare bytes.

`PublicKey.derive` accepts soft paths only. A hardened index returns
`HardenedPublicDerivation` before native work. An empty public path returns the
original value. Public soft derivation agrees with deriving the private key and
then obtaining its public key.

`PublicKey.toEd25519` discards the chain code. The BIP32 `hash` operation computes
BLAKE2b-224 over **all 64 bytes**, including the chain code. To obtain a Cardano
verification-key credential hash, convert with `toEd25519` and call
`Cometa.Crypto.Ed25519.PublicKey.hash` on the 32-byte result.

## Sign and manage secret lifetime

Use `PrivateKey.withSigningKey` to obtain a scoped extended Ed25519 signing key
from a BIP32 key. Its callback can use the operations in the [signing guide](signing.md).
The signing key is independent: closing the BIP32 source does not close it.
`withDerived` and `withClone` also create independent private scopes.

Every private handle closes on scope exit, including callback failures, exceptions,
and cancellation. `close` can end access earlier and waits for ongoing operations;
repeated closure is harmless. Later BIP32 operations return `Bip32PrivateKeyClosed`,
even if a handle escaped its callback. Public results remain usable after closure.

Private keys have no `Show` or equality instance. `exportBytes` and `exportHex`
explicitly create application-managed secret copies. Closing a key cannot erase
those copies, the entropy or password supplied by the application, or its imported
key bytes/text. Avoid exporting unless the application needs the secret itself.
