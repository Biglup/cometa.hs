# Ed25519 signing

An Ed25519 public key identifies a signer. A signature proves that the holder of
the corresponding signing key signed a particular sequence of bytes. Changing
even one message byte makes verification fail.

## Import public values

Use `Cometa.Crypto.Ed25519.PublicKey` and `Cometa.Crypto.Ed25519.Signature` for
public keys and signatures. Their `fromBytes` and `fromHex` functions validate the
encoded length and return `Either Error ...`. A public key is 32 bytes; a signature
is 64 bytes. Hexadecimal text accepts either case, without whitespace or a prefix.

`toBytes` and `toHex` return the encoded value; hexadecimal output is lowercase.
`PublicKey.hash` computes the 28-byte BLAKE2b hash used for Cardano key credentials.
Importing a key or signature validates its representation, not whether a signature
is valid for a message. Use `PublicKey.verify` for that check.

## Sign within a key scope

`withNormalKey` imports a 32-byte Ed25519 seed. `withExtendedKey` imports a
64-byte expanded Ed25519 key; this is not a BIP32 key with a chain code. Both also
have hexadecimal-input forms ending in `Hex`.

The callback returns `IO (Either Error a)`. Acquisition errors and callback errors
use the same result channel. Exceptions and asynchronous cancellation propagate
after cleanup. `ExceptT` is convenient when composing several operations; it is
optional and not required by the library.

```haskell
{-# LANGUAGE OverloadedStrings #-}

import qualified Cometa.Crypto.Ed25519.PublicKey as PublicKey
import qualified Cometa.Crypto.Ed25519.SigningKey as SigningKey
import Control.Monad.Trans.Except (ExceptT (..), runExceptT)

main :: IO ()
main = do
  -- Published RFC 8032 test seed; never use it for funds.
  let seed = "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60"
      message = "Hello, Cardano!"

  result <- SigningKey.withNormalKeyHex seed $ \key -> runExceptT $ do
    public <- ExceptT (SigningKey.publicKey key)
    signature <- ExceptT (SigningKey.sign key message)

    ExceptT (PublicKey.verify public message signature)

  print result
```

`sign` signs the supplied bytes exactly, including empty messages and embedded
NUL bytes. It does not hash or decode hexadecimal text for you. Cardano transaction
signatures use the transaction body hash, not the complete transaction encoding.

A successful `verify` call returns `Right True` only when verification succeeds.
`Right False` means it did not succeed; `Left` reports an operation error.

The runnable example prints only public values:

```sh
cabal run cometa-signing
```

## Key lifetime and export

A signing key is usable only while its scope is open. Keeping its Haskell handle
after the callback returns does not keep it usable: subsequent operations return
`SigningKeyClosed`. The scope closes on successful return, an error result, or
an exception. `close` supports early closure and can be called more than once.
It waits for ongoing operations before closing the key.

`withClone` creates an independent scoped key. Closing one key does not close its
clone. Keep operations inside their owning scopes, including work on other threads.

`exportBytes` and `exportHex` explicitly copy secret material into application
values. Those values, and the inputs you supplied, remain outside the key scope's
lifetime control. Closing the key does not erase them. Signing keys have no `Show`
instance; avoid printing exported secret material or placing it in diagnostics.
