# Use encrypted software key storage

`Cometa.KeyHandler.Software` scopes an encrypted BIP32 or Ed25519 handler.
Use `withEntropy` for BIP39 entropy, or `withSigningKey` to encrypt an independent
copy of an existing scoped Ed25519 signing key. `Handler Bip32` supports
`accountPublicKey`; `Handler Ed25519` supports `publicKey`. Account paths use
unencoded components from `Cometa.Crypto.DerivationPath`.

An encryption password protects storage. BIP32 root derivation always uses an
empty BIP39 password; the storage password does not change the derived keys.
Supply passwords as raw bytes, including embedded NUL if required. Constructor
and callback passwords must each contain 1 through 128 bytes. Invalid lengths
return `InvalidKeyHandlerPasswordLength`; there is no normalization or password
policy. A wrong password returns a native authentication error.

For direct public-key derivation without encrypted storage, use the
[one-shot BIP32 helpers](bip32.md). The following program encrypts deterministic
public demonstration material, serializes the encrypted storage, closes the
original handler, and reloads the bytes in a fresh scope. The
password action supplies the application's password when a public key is
requested. An application can replace it with its own credential acquisition;
keep its results only as long as necessary.

```haskell
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Crypto.Bip32.PublicKey as Public
import qualified Cometa.Crypto.DerivationPath as Path
import qualified Cometa.Crypto.Ed25519.PublicKey as Ed25519
import Cometa.Error (Error)
import qualified Cometa.KeyHandler.Software as Software
import Control.Monad.Trans.Except (ExceptT (..), runExceptT)
import qualified Data.ByteString as ByteString
import Data.Text (Text)
import qualified Data.Text.IO as Text
import System.Exit (die)

-- DEFINITIONS ----------------------------------------------------------------

-- Public deterministic demonstration material only; never use it for a wallet.
main :: IO ()
main = do
  let entropy = ByteString.replicate 16 0
      password = "public demonstration password"
      requestPassword = pure password
      path = Path.standardAccountPath minBound

  result <- runExceptT $ do
    stored <- ExceptT (Software.withEntropy entropy password requestPassword Software.serialize)
    ExceptT (Software.withSerialized stored requestPassword (loadedPublicKeyHex path))

  case result of
    Left err -> die (show err)
    Right keyHex -> Text.putStrLn keyHex

-- The storage format identifies the public-key capability when reloaded.
loadedPublicKeyHex :: Path.AccountPath -> Software.LoadedHandler -> IO (Either Error Text)
loadedPublicKeyHex path loaded = case loaded of
  Software.Bip32Handler handler -> fmap Public.toHex <$> Software.accountPublicKey handler path
  Software.Ed25519Handler handler -> fmap Ed25519.toHex <$> Software.publicKey handler
```

Run the compiled example with `cabal run cometa-software-key-handler`. It prints
only a public key. The `ExceptT` sequence has one failure boundary; the total
helper handles both capabilities identified by serialized storage. In an
application, persist the returned bytes exactly and load those same bytes later.
`serialize` returns encrypted binary storage, and
`withSerialized` loads it into a `LoadedHandler` sum without requesting a password.
Loading checks framing, supported sizes and checksum. The next public-key
operation checks the password and encrypted payload. Preserve storage bytes
exactly: this format is not CBOR. Its inner key material is authenticated and
encrypted, but its version, key type and size metadata use only a CRC checksum.
Accept stored data only from a trusted source and protect it from unauthorized
modification and password guessing.

Scope exit closes a handler after ongoing work finishes. Escaped handles return
`KeyHandlerClosed`. Operations on different handlers can overlap; concurrent
operations or callback reentry on one handler return `KeyHandlerBusy`. Explicit
`close` returns busy while work is active; a later close or scope exit still
closes the handle. A password action must not wait for other operations on its
own handler. Its exceptions propagate after cleanup. Cancellation asks a running
password action to unwind and joins it and the native operation before releasing
storage; a callback that masks cancellation can delay that cleanup.

Closing controls access through the handle. It does not erase entropy, password
bytes, original signing-key input or callback results held in Haskell memory,
or application copies. The handler retains the supplied password action for its
scope, so any values captured by that action have the same lifetime. `serialize`
does not export plaintext private-key bytes.
