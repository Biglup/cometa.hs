-- Copyright 2026 Biglup Labs
-- SPDX-License-Identifier: Apache-2.0
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     https://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.

-- | Verification-key signatures and Byron bootstrap witnesses. Construction
-- assembles previously validated keys and signatures; it does not verify them.
-- @verificationWitness key signature@ assembles a Shelley witness.
module Cometa.Transaction.Witness
  ( VerificationWitness,
    verificationWitness,
    publicKey,
    signature,
    BootstrapWitness,
    mkBootstrapWitness,
    bootstrapPublicKey,
    bootstrapSignature,
    chainCode,
    attributes,
    encodeCbor,
    decodeCbor,
    encodeBootstrapCbor,
    decodeBootstrapCbor,
  )
where

-- IMPORTS --------------------------------------------------------------------

import qualified Codec.CBOR.Decoding as D
import qualified Codec.CBOR.Encoding as E
import Cometa.Crypto.Ed25519.PublicKey (PublicKey)
import qualified Cometa.Crypto.Ed25519.PublicKey as Key
import Cometa.Crypto.Ed25519.Signature (Signature)
import qualified Cometa.Crypto.Ed25519.Signature as Sig
import Cometa.Error (Error (..))
import qualified Cometa.Internal.TransactionCbor as C
import Data.ByteString (ByteString)
import qualified Data.ByteString as B

-- TYPES ----------------------------------------------------------------------

-- | A verification key and its signature of a transaction body hash.
data VerificationWitness = VerificationWitness !PublicKey !Signature deriving (Eq, Ord, Show)

-- DEFINITIONS ----------------------------------------------------------------

-- | Assemble a key witness. Cryptographic verification is a separate effect.
verificationWitness :: PublicKey -> Signature -> VerificationWitness
verificationWitness = VerificationWitness

-- | The signing verification key.
publicKey :: VerificationWitness -> PublicKey
publicKey (VerificationWitness key _) = key

-- | Signature bytes validated for Ed25519 length.
signature :: VerificationWitness -> Signature
signature (VerificationWitness _ sig) = sig

-- | A Byron witness with a 32-byte derivation chain code and opaque serialized
-- address attributes. Equality compares all fields.
data BootstrapWitness = BootstrapWitness !PublicKey !Signature !ByteString !ByteString deriving (Eq, Ord, Show)

-- | Assemble a bootstrap witness; the chain code must contain exactly 32 bytes.
-- Attributes are the serialized Byron address attributes, retained verbatim.
mkBootstrapWitness :: PublicKey -> Signature -> ByteString -> ByteString -> Either Error BootstrapWitness
mkBootstrapWitness key sig chain attrs
  | B.length chain /= 32 = Left (InvalidBootstrapChainCodeLength (B.length chain))
  | otherwise = Right (BootstrapWitness key sig chain attrs)

-- | Bootstrap signing key.
bootstrapPublicKey :: BootstrapWitness -> PublicKey
bootstrapPublicKey (BootstrapWitness key _ _ _) = key

-- | Bootstrap signature.
bootstrapSignature :: BootstrapWitness -> Signature
bootstrapSignature (BootstrapWitness _ sig _ _) = sig

-- | Exactly 32 chain-code bytes.
chainCode :: BootstrapWitness -> ByteString
chainCode (BootstrapWitness _ _ chain _) = chain

-- | Opaque serialized Byron address attributes.
attributes :: BootstrapWitness -> ByteString
attributes (BootstrapWitness _ _ _ attrs) = attrs

-- | Encode the two-element key/signature array.
encodeCbor :: VerificationWitness -> ByteString
encodeCbor (VerificationWitness key sig) = C.encode (E.encodeListLen 2 <> E.encodeBytes (Key.toBytes key) <> E.encodeBytes (Sig.toBytes sig))

-- | Decode one key/signature array, validating lengths and rejecting trailing bytes.
decodeCbor :: ByteString -> Either Error VerificationWitness
decodeCbor = C.decodeAs InvalidWitnessCbor (C.array 2 (VerificationWitness <$> keyDecoder <*> signatureDecoder))

-- | Encode the four-element bootstrap array.
encodeBootstrapCbor :: BootstrapWitness -> ByteString
encodeBootstrapCbor (BootstrapWitness key sig chain attrs) = C.encode (E.encodeListLen 4 <> E.encodeBytes (Key.toBytes key) <> E.encodeBytes (Sig.toBytes sig) <> E.encodeBytes chain <> E.encodeBytes attrs)

-- | Decode a bootstrap array, validating lengths and rejecting trailing bytes.
decodeBootstrapCbor :: ByteString -> Either Error BootstrapWitness
decodeBootstrapCbor = C.decodeAs InvalidWitnessCbor $ C.array 4 $ do
  key <- keyDecoder
  sig <- signatureDecoder
  chain <- D.decodeBytes
  attrs <- D.decodeBytes
  either (fail . show) pure (mkBootstrapWitness key sig chain attrs)

keyDecoder :: D.Decoder s PublicKey
keyDecoder = D.decodeBytes >>= either (fail . show) pure . Key.fromBytes

signatureDecoder :: D.Decoder s Signature
signatureDecoder = D.decodeBytes >>= either (fail . show) pure . Sig.fromBytes
