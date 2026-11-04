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

The following program uses deterministic public demonstration material. The
password action supplies the application's password when a public key is
requested. An application can replace it with its own credential acquisition;
keep its results only as long as necessary.

```haskell
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Crypto.Bip32.PublicKey as Public
import qualified Cometa.Crypto.DerivationPath as Path
import qualified Cometa.KeyHandler.Software as Software
import qualified Data.ByteString as ByteString
import qualified Data.Text.IO as Text
import System.Exit (die)

-- DEFINITIONS ----------------------------------------------------------------

-- Public deterministic demonstration material only; never use it for a wallet.
main :: IO ()
main = case Path.mkIndex 0 of
  Left err -> die (show err)
  Right account -> do
    let path = Path.mkStandardAccountPath account
        requestPassword = pure "public demonstration password"

    result <- Software.withEntropy (ByteString.replicate 16 0) "public demonstration password" requestPassword $ \handler ->
      Software.accountPublicKey handler path

    case result of
      Left err -> die (show err)
      Right key -> Text.putStrLn (Public.toHex key)
```

Run the compiled example with `cabal run cometa-software-key-handler`. It prints
only a public account key. `serialize` returns encrypted binary storage, and
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
