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
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

-- | Owned protocol values and schema codecs. No native calls occur here.
module Cometa.Internal.ProtocolValues
  ( NonNegativeRational (..),
    UnitInterval (..),
    ExUnits (..),
    ProtocolVersion (..),
    ExUnitPrices (..),
    PoolVotingThresholds (..),
    DRepVotingThresholds (..),
    mkNonNegativeRational,
    mkUnitInterval,
    rationalNumerator,
    rationalDenominator,
    rationalValue,
    unitIntervalRational,
    mkExUnits,
    mkProtocolVersion,
    encodeBytes,
    decodeBytes,
    decodeTuple,
    encodeRational,
    decodeRational,
    encodeUnitInterval,
    decodeUnitInterval,
    encodeExUnits,
    decodeExUnits,
    encodeProtocolVersion,
    decodeProtocolVersion,
    encodeExUnitPrices,
    decodeExUnitPrices,
    encodePoolVotingThresholds,
    decodePoolVotingThresholds,
    encodeDRepVotingThresholds,
    decodeDRepVotingThresholds,
  )
where

-- IMPORTS --------------------------------------------------------------------

import qualified Codec.CBOR.Decoding as Decode
import qualified Codec.CBOR.Encoding as Encode
import qualified Codec.CBOR.Read as Read
import qualified Codec.CBOR.Write as Write
import Cometa.Error (Error (..))
import Control.Monad (when)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Lazy as Lazy
import Data.Ratio ((%))
import qualified Data.Text as Text
import Data.Word (Word32, Word64)

-- TYPES ----------------------------------------------------------------------

-- | Exact nonnegative fraction with an unsigned 64-bit numerator and positive
-- unsigned 64-bit denominator. The original pair is retained for encoding;
-- equality and ordering compare numeric values. Show is diagnostic.
data NonNegativeRational = NonNegativeRational !Word64 !Word64 deriving (Show)

instance Eq NonNegativeRational where
  a == b = compare a b == EQ

instance Ord NonNegativeRational where
  compare (NonNegativeRational n d) (NonNegativeRational m e) = compare (toInteger n * toInteger e) (toInteger m * toInteger d)

-- | Exact proportion between zero and one, inclusive. Equality and ordering
-- compare numeric values; the original pair is retained for encoding.
newtype UnitInterval = UnitInterval NonNegativeRational deriving (Eq, Ord, Show)

-- | Memory and CPU execution budget. Each unsigned component is bounded by 2^64-1.
data ExUnits
  = -- | Assemble validated components.
    ExUnits
    { -- | Memory execution units.
      memory :: !Word64,
      -- | CPU execution steps.
      steps :: !Word64
    }
  deriving (Eq, Show)

-- | Protocol major/minor version; ordering compares major then minor.
data ProtocolVersion
  = -- | Assemble validated components.
    ProtocolVersion
    { -- | Unsigned 64-bit major version.
      major :: !Word64,
      -- | Unsigned 32-bit minor version.
      minor :: !Word32
    }
  deriving (Eq, Ord, Show)

-- | Exact nonnegative lovelace costs per memory unit and CPU step.
data ExUnitPrices
  = -- | Assemble validated components.
    ExUnitPrices
    { -- | Lovelace per memory unit.
      memoryPrice :: !NonNegativeRational,
      -- | Lovelace per CPU step.
      stepPrice :: !NonNegativeRational
    }
  deriving (Eq, Show)

-- | Stake-pool approval thresholds, each from zero through one inclusive.
data PoolVotingThresholds
  = -- | Assemble validated components.
    PoolVotingThresholds
    { -- | Approval threshold for a motion of no confidence in the committee.
      poolMotionNoConfidence :: !UnitInterval,
      -- | Approval threshold for committee changes while the committee has confidence.
      poolCommitteeNormal :: !UnitInterval,
      -- | Approval threshold for committee changes after a loss of confidence.
      poolCommitteeNoConfidence :: !UnitInterval,
      -- | Approval threshold for initiating a protocol hard fork.
      poolHardForkInitiation :: !UnitInterval,
      -- | Approval threshold for security-relevant protocol parameter changes.
      poolSecurityRelevantParameter :: !UnitInterval
    }
  deriving (Eq, Show)

-- | DRep approval thresholds, each from zero through one inclusive.
data DRepVotingThresholds
  = -- | Assemble validated components.
    DRepVotingThresholds
    { -- | Approval threshold for a motion of no confidence in the committee.
      drepMotionNoConfidence :: !UnitInterval,
      -- | Approval threshold for committee changes while the committee has confidence.
      drepCommitteeNormal :: !UnitInterval,
      -- | Approval threshold for committee changes after a loss of confidence.
      drepCommitteeNoConfidence :: !UnitInterval,
      -- | Approval threshold for adopting a new constitution.
      drepUpdateConstitution :: !UnitInterval,
      -- | Approval threshold for initiating a protocol hard fork.
      drepHardForkInitiation :: !UnitInterval,
      -- | Approval threshold for network protocol parameter changes.
      drepNetworkParameterGroup :: !UnitInterval,
      -- | Approval threshold for economic protocol parameter changes.
      drepEconomicParameterGroup :: !UnitInterval,
      -- | Approval threshold for technical protocol parameter changes.
      drepTechnicalParameterGroup :: !UnitInterval,
      -- | Approval threshold for governance protocol parameter changes.
      drepGovernanceParameterGroup :: !UnitInterval,
      -- | Approval threshold for treasury withdrawal proposals.
      drepTreasuryWithdrawal :: !UnitInterval
    }
  deriving (Eq, Show)

-- DEFINITIONS ----------------------------------------------------------------

-- | Validate an unsigned 64-bit numerator and positive unsigned 64-bit
-- denominator. Retain the exact pair. Invalid values return
-- 'InvalidProtocolRational'.
mkNonNegativeRational :: Integer -> Integer -> Either Error NonNegativeRational
mkNonNegativeRational n d
  | n < 0 || n > toInteger (maxBound :: Word64) || d <= 0 || d > toInteger (maxBound :: Word64) = Left (InvalidProtocolRational n d)
  | otherwise = Right (NonNegativeRational (fromInteger n) (fromInteger d))

-- | Validate a proportion numerator and denominator. Invalid unsigned bounds
-- or a zero denominator return 'InvalidProtocolRational'; a numerator larger
-- than its denominator returns 'InvalidUnitInterval'.
mkUnitInterval :: Integer -> Integer -> Either Error UnitInterval
mkUnitInterval n d = do
  value <- mkNonNegativeRational n d
  if n > d then Left (InvalidUnitInterval n d) else Right (UnitInterval value)

rationalNumerator :: NonNegativeRational -> Word64
rationalNumerator (NonNegativeRational n _) = n

rationalDenominator :: NonNegativeRational -> Word64
rationalDenominator (NonNegativeRational _ d) = d

rationalValue :: NonNegativeRational -> Rational
rationalValue (NonNegativeRational n d) = toInteger n % toInteger d

unitIntervalRational :: UnitInterval -> NonNegativeRational
unitIntervalRational (UnitInterval r) = r

-- | Validate external memory and step counts in 0..2^64-1. Invalid input
-- returns 'InvalidExUnits'.
mkExUnits :: Integer -> Integer -> Either Error ExUnits
mkExUnits m s
  | m < 0 || m > toInteger (maxBound :: Word64) || s < 0 || s > toInteger (maxBound :: Word64) = Left (InvalidExUnits m s)
  | otherwise = Right (ExUnits (fromInteger m) (fromInteger s))

-- | Validate an external major in 0..2^64-1 and minor in 0..2^32-1.
-- Invalid input returns 'InvalidProtocolVersion'.
mkProtocolVersion :: Integer -> Integer -> Either Error ProtocolVersion
mkProtocolVersion a b
  | a < 0 || a > toInteger (maxBound :: Word64) || b < 0 || b > toInteger (maxBound :: Word32) = Left (InvalidProtocolVersion a b)
  | otherwise = Right (ProtocolVersion (fromInteger a) (fromInteger b))

encodeRational :: NonNegativeRational -> Encode.Encoding
encodeRational (NonNegativeRational n d) = Encode.encodeTag 30 <> Encode.encodeListLen 2 <> Encode.encodeWord64 n <> Encode.encodeWord64 d

decodeRational :: Decode.Decoder s NonNegativeRational
decodeRational = do
  tag <- Decode.decodeTag
  when (tag /= 30) (fail "expected rational tag 30")
  decodeTuple 2 $ do
    n <- Decode.decodeWord64
    d <- Decode.decodeWord64
    either (fail . show) pure (mkNonNegativeRational (toInteger n) (toInteger d))

encodeUnitInterval :: UnitInterval -> Encode.Encoding
encodeUnitInterval = encodeRational . unitIntervalRational

decodeUnitInterval :: Decode.Decoder s UnitInterval
decodeUnitInterval = do
  r@(NonNegativeRational n d) <- decodeRational
  if n > d then fail "unit interval exceeds one" else pure (UnitInterval r)

encodeExUnits :: ExUnits -> Encode.Encoding
encodeExUnits (ExUnits m s) = Encode.encodeListLen 2 <> Encode.encodeWord64 m <> Encode.encodeWord64 s

decodeExUnits :: Decode.Decoder s ExUnits
decodeExUnits = decodeTuple 2 (ExUnits <$> Decode.decodeWord64 <*> Decode.decodeWord64)

encodeProtocolVersion :: ProtocolVersion -> Encode.Encoding
encodeProtocolVersion (ProtocolVersion a b) = Encode.encodeListLen 2 <> Encode.encodeWord64 a <> Encode.encodeWord32 b

decodeProtocolVersion :: Decode.Decoder s ProtocolVersion
decodeProtocolVersion = decodeTuple 2 (ProtocolVersion <$> Decode.decodeWord64 <*> Decode.decodeWord32)

encodeExUnitPrices :: ExUnitPrices -> Encode.Encoding
encodeExUnitPrices (ExUnitPrices m s) = Encode.encodeListLen 2 <> encodeRational m <> encodeRational s

decodeExUnitPrices :: Decode.Decoder s ExUnitPrices
decodeExUnitPrices = decodeTuple 2 (ExUnitPrices <$> decodeRational <*> decodeRational)

-- | Fixed tuples accept definite and indefinite arrays and check exact arity.
decodeTuple :: Int -> Decode.Decoder s a -> Decode.Decoder s a
decodeTuple expected fields = do
  count <- Decode.decodeListLenOrIndef
  case count of
    Just actual | actual /= expected -> fail "wrong protocol tuple length"
    _ -> pure ()
  result <- fields
  case count of
    Nothing -> Decode.decodeBreakOr >>= \end -> if end then pure () else fail "extra protocol tuple field"
    Just _ -> pure ()
  pure result

encodeBytes :: (a -> Encode.Encoding) -> a -> ByteString
encodeBytes encode = Write.toStrictByteString . encode

decodeBytes :: (forall s. Decode.Decoder s a) -> ByteString -> Either Error a
decodeBytes decode bytes = case Read.deserialiseFromBytes decode (Lazy.fromStrict bytes) of
  Left failure -> Left (InvalidProtocolCbor (Text.pack (show failure)))
  Right (remaining, value)
    | Lazy.null remaining -> Right value
    | otherwise -> Left (InvalidProtocolCbor "trailing CBOR data")

encodePoolVotingThresholds :: PoolVotingThresholds -> Encode.Encoding
encodePoolVotingThresholds (PoolVotingThresholds noConfidence normalCommittee noConfidenceCommittee hardFork securityParameters) = Encode.encodeListLen 5 <> encodeUnitInterval noConfidence <> encodeUnitInterval normalCommittee <> encodeUnitInterval noConfidenceCommittee <> encodeUnitInterval hardFork <> encodeUnitInterval securityParameters

decodePoolVotingThresholds :: Decode.Decoder s PoolVotingThresholds
decodePoolVotingThresholds = decodeTuple 5 (PoolVotingThresholds <$> decodeUnitInterval <*> decodeUnitInterval <*> decodeUnitInterval <*> decodeUnitInterval <*> decodeUnitInterval)

encodeDRepVotingThresholds :: DRepVotingThresholds -> Encode.Encoding
encodeDRepVotingThresholds (DRepVotingThresholds noConfidence normalCommittee noConfidenceCommittee constitution hardFork networkParameters economicParameters technicalParameters governanceParameters treasury) = Encode.encodeListLen 10 <> encodeUnitInterval noConfidence <> encodeUnitInterval normalCommittee <> encodeUnitInterval noConfidenceCommittee <> encodeUnitInterval constitution <> encodeUnitInterval hardFork <> encodeUnitInterval networkParameters <> encodeUnitInterval economicParameters <> encodeUnitInterval technicalParameters <> encodeUnitInterval governanceParameters <> encodeUnitInterval treasury

decodeDRepVotingThresholds :: Decode.Decoder s DRepVotingThresholds
decodeDRepVotingThresholds = decodeTuple 10 (DRepVotingThresholds <$> decodeUnitInterval <*> decodeUnitInterval <*> decodeUnitInterval <*> decodeUnitInterval <*> decodeUnitInterval <*> decodeUnitInterval <*> decodeUnitInterval <*> decodeUnitInterval <*> decodeUnitInterval <*> decodeUnitInterval)
