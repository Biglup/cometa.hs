# Derive BIP32 keys

Cardano Ed25519-BIP32 keys combine an expanded Ed25519 key with a chain code.
A private key contains 96 bytes; a public key contains 64 bytes. Use
`Cometa.Crypto.Bip32` for one-shot public-key derivation,
`Cometa.Crypto.Bip32.PrivateKey` for scoped secrets, and
`Cometa.Crypto.Bip32.PublicKey` for immutable public values.

## Derive a payment public key

`Bip32.derivePublicKey` takes raw password bytes, raw BIP39 entropy, and a typed
derivation path. Entropy must contain 16, 20, 24, 28, or 32 bytes. Passwords can be empty and can contain
NUL bytes. Supply already normalized bytes if your application uses a text
password: this function performs no text normalization. It does not accept a
mnemonic sentence or the 64-byte BIP39 seed produced from one. Use the
[BIP39 recovery guide](bip39.md) to validate a phrase and export its entropy.

The example derives the CIP-1852 path `1852'/1815'/0'/0/0`. The helper opens
and closes all intermediate secret keys automatically and returns an immutable
public key. `minBound :: Path.Index` denotes the first raw component, zero.

```haskell
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

-- IMPORTS --------------------------------------------------------------------

import qualified Cometa.Crypto.Bip32 as Bip32
import qualified Cometa.Crypto.Bip32.PublicKey as PublicKey
import qualified Cometa.Crypto.DerivationPath as Path
import qualified Data.ByteString as ByteString
import qualified Data.Text.IO as Text
import System.Exit (die)

-- DEFINITIONS ----------------------------------------------------------------

main :: IO ()
main = do
  -- Deterministic test entropy; never use this key for funds.
  let entropy = ByteString.replicate 16 0
      account = Path.standardAccountPath minBound
      payment = Path.derivationPath account Path.externalRole minBound

  result <- Bip32.derivePublicKey "" entropy payment

  case result of
    Left failure -> die (show failure)
    Right public -> Text.putStrLn (PublicKey.toHex public)
```

The complete example is built as `cometa-bip32`; run it with `cabal run cometa-bip32`.
Its deterministic entropy is test data and must never secure an application wallet.

For an account public key, call `Bip32.deriveAccountPublicKey password entropy
account`. Both helpers manage secret scopes and return `IO (Either Error
PublicKey)`. Their password is the BIP32 root-derivation password, not an
[encrypted-storage password](software-key-handlers.md).

The lower-level `PrivateKey.withEntropy` and `PrivateKey.withDerived` remain
available when an application needs several operations within one key scope.
Raw path elements are applied in order; `PrivateKey.harden` sets the high bit
idempotently, and an empty private path makes an independent key copy.

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

## Build wallet paths from validated components

`Cometa.Crypto.DerivationPath` keeps component validation and path construction
pure. `mkIndex` accepts an `Integer` from 0 through 2147483647 inclusive;
negative or larger inputs return `InvalidDerivationIndex` with the exact input.
Supply raw component numbers, without setting a hardening bit.

```haskell
import qualified Cometa.Crypto.DerivationPath as Path

firstPayment :: Path.DerivationPath
firstPayment =
  Path.derivationPath (Path.standardAccountPath minBound) Path.externalRole minBound
```

`Index` has lawful `Eq`, `Ord`, `Show`, and `Bounded` instances. Its bounds are raw
0 and 2147483647, without hardening bits. It has no `Num` or `Enum` instance:
arithmetic and unrestricted numeric literals must not bypass validation.

Validate runtime input once at the boundary. Standard `ExceptT` and `except` can
combine pure validation with effectful derivation, with one result for the caller:

```haskell
import qualified Cometa.Crypto.Bip32 as Bip32
import qualified Cometa.Crypto.Bip32.PublicKey as PublicKey
import qualified Cometa.Crypto.DerivationPath as Path
import Cometa.Error (Error)
import Control.Monad.Trans.Except (ExceptT (..), except, runExceptT)
import Data.ByteString (ByteString)

derivePayment :: ByteString -> ByteString -> Integer -> Integer -> IO (Either Error PublicKey.PublicKey)
derivePayment password entropy accountNumber keyNumber = runExceptT $ do
  account <- except (Path.mkIndex accountNumber)
  index <- except (Path.mkIndex keyNumber)

  let prefix = Path.standardAccountPath account
      payment = Path.derivationPath prefix Path.externalRole index

  ExceptT (Bip32.derivePublicKey password entropy payment)
```

No custom application monad is required. An ordinary `Either` composition or
explicit result match is equally suitable for a smaller flow.

For a root private key, pass `Path.toIndices payment` to `PrivateKey.withDerived`.
It encodes `1852'/1815'/0'/0/0`: the purpose, coin type and account are hardened;
the role and key index are soft. `accountIndices` returns just the three hardened
indices. From that account key, `relativeIndices` returns the soft role and index
for either private or public derivation. Applying a full root path to an account
key derives a different descendant; choose the conversion for your starting key.

`DerivationPath` names the standard purpose 1852, multisignature purpose 1854, Cardano
coin type 1815 and roles for external, internal, staking, DRep, committee cold
and committee hot keys. `Path.standardAccountPath` selects purpose 1852 and coin type
1815. For multisignature or custom paths, construct a prefix with
`Path.accountPath purpose coinType account`. Any valid component can be a
custom purpose, coin type or role; naming a role does not validate its use by a
particular wallet or protocol.

The compiled `cometa-derivation-paths` example prints encoded paths without secret
material. These values have component equality and lexicographic ordering in
path order. Their `Show` output is diagnostic, not a serialized path format.

`accountPrefix` inspects the account portion of a complete `DerivationPath`;
`accountPath` assembles a prefix from already validated components. Total path
assembly does not introduce another validation or failure branch.
