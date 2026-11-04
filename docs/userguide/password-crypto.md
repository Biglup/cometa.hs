# Derive and encrypt secret bytes

`Cometa.Crypto.Pbkdf2` derives explicitly exported bytes using
PBKDF2-HMAC-SHA512. Supply raw password and salt bytes, an iteration count and an
output byte count. Passwords may be empty or contain NUL. Salt must be nonempty;
iterations are 1 through 4294967295. Output is positive and bounded by both the
host Int range and PBKDF2's 274877906880-byte maximum. These limits describe
accepted representations; large requests require substantial resources.
Choose password cost and salt for your application's protocol. The library does
not choose a default or normalize text.

`Cometa.Crypto.Emip3` encrypts bytes for EMIP-003 storage. Its fixed format uses
PBKDF2-HMAC-SHA512 with 19162 iterations and a 32-byte key, then ChaCha20-Poly1305
with empty associated data. Encryption generates a fresh 32-byte salt and 12-byte
nonce. The envelope is salt, nonce, 16-byte authentication tag, then ciphertext.
Encryption and decryption return IO actions. A wrong password or modification
fails authentication and returns no plaintext.

```haskell
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import qualified Cometa.Crypto.Emip3 as Emip3
import qualified Cometa.Crypto.Pbkdf2 as Pbkdf2
import qualified Data.ByteString as ByteString
import System.Exit (die)

-- Public deterministic sample material only. Do not print secrets.
main :: IO ()
main = case Pbkdf2.deriveBytes "sample password" "application salt" 10000 32 of
  Left err -> die (show err)
  Right derived -> do
    encrypted <- Emip3.encrypt "storage password" derived
    case encrypted of
      Left err -> die (show err)
      Right envelope -> do
        decrypted <- Emip3.decryptBytes "storage password" envelope
        case decrypted of
          Left err -> die (show err)
          Right restored
            | restored == derived -> putStrLn ("Recovered " ++ show (ByteString.length restored) ++ " bytes")
            | otherwise -> die "Recovered data differs"
```

Build and run the compiled version with `cabal run cometa-password-crypto`.
Only public lengths are printed. Store the encrypted envelope as binary data or
encode it with an application-selected encoding; never confuse it with plaintext.

Empty plaintext is supported. Plaintext must fit
`min(maxBound :: Int - 60, 274877906880)` bytes, and envelopes must contain at
least 60 bytes and at most 274877906940 bytes. Truncated or oversized envelopes
return a structured length error before decryption. Authentication failures
preserve the native generic status in `NativeError` without password diagnostics.

The operations accept ordinary immutable ByteStrings. Passwords, plaintext
inputs, derived output and explicitly decrypted bytes have application-managed
lifetimes. Neither garbage collection nor this API promises to erase those
values or later copies. Avoid logging them. Cancellation waits for a running
native operation to finish before cleanup; large PBKDF requests can delay it.
The pure PBKDF function may be evaluated lazily, shared or recomputed, so callers
must not rely on a particular evaluation time or number of derivations.
