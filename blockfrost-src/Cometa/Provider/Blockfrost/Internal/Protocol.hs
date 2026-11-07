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
{-# OPTIONS_HADDOCK hide #-}

-- | Decode the documented Blockfrost protocol snapshot without rounding money
-- or execution prices. Absent era fields remain unavailable.
module Cometa.Provider.Blockfrost.Internal.Protocol (decodeProtocolParameters) where

-- IMPORTS --------------------------------------------------------------------

import Cometa.Error (Error (..))
import qualified Cometa.Protocol.CostModels as Models
import Cometa.Protocol.DRepVotingThresholds (DRepVotingThresholds (..))
import Cometa.Protocol.ExUnitPrices (ExUnitPrices (..))
import qualified Cometa.Protocol.ExUnits as Units
import qualified Cometa.Protocol.Parameters as P
import Cometa.Protocol.PoolVotingThresholds (PoolVotingThresholds (..))
import qualified Cometa.Protocol.Rational as Fraction
import qualified Cometa.Protocol.Version as Version
import qualified Cometa.UnitInterval as Interval
import Data.Aeson (Object, Value (..))
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KeyMap
import Data.Aeson.Types (Parser, parseEither, withArray, withObject)
import qualified Data.ByteString as ByteString
import Data.Char (digitToInt, isDigit, isHexDigit)
import Data.Foldable (toList)
import Data.Int (Int64)
import Data.Ratio (denominator, numerator)
import Data.Scientific (base10Exponent, floatingOrInteger)
import qualified Data.Text as Text
import Text.Read (readMaybe)

-- DEFINITIONS ----------------------------------------------------------------

-- | Reject incomplete grouped fields and invalid numeric domains. The failure
-- contains only the operation name, never response data.
decodeProtocolParameters :: Value -> Either Error P.Parameters
decodeProtocolParameters value = case parseEither (withObject "parameters" parameters) value of
  Left _ -> Left (InvalidProviderResponse "provider.protocolParameters")
  Right result -> Right result

parameters :: Object -> Parser P.Parameters
parameters object = do
  version <- Version.ProtocolVersion <$> required object "protocol_major_ver" bounded <*> required object "protocol_minor_ver" bounded
  byteCost <- optional object "coins_per_utxo_size" bounded
  -- Before Babbage this field has word units and cannot represent a byte cost.
  let utxoByteCost = if Version.major version >= 7 then byteCost else Nothing
  P.Parameters
    <$> required object "min_fee_a" bounded
    <*> required object "min_fee_b" bounded
    <*> required object "max_block_size" bounded
    <*> required object "max_tx_size" bounded
    <*> required object "max_block_header_size" bounded
    <*> required object "key_deposit" bounded
    <*> required object "pool_deposit" bounded
    <*> required object "e_max" bounded
    <*> required object "n_opt" bounded
    <*> required object "a0" fraction
    <*> required object "rho" interval
    <*> required object "tau" interval
    <*> optional object "decentralisation_param" interval
    <*> nonce object
    <*> pure version
    <*> required object "min_pool_cost" bounded
    <*> pure utxoByteCost
    <*> optional object "cost_models_raw" costModels
    <*> grouped object ["price_mem", "price_step"] (ExUnitPrices <$> required object "price_mem" fraction <*> required object "price_step" fraction)
    <*> exUnits object "max_tx_ex_mem" "max_tx_ex_steps"
    <*> exUnits object "max_block_ex_mem" "max_block_ex_steps"
    <*> optional object "max_val_size" bounded
    <*> optional object "collateral_percent" bounded
    <*> optional object "max_collateral_inputs" bounded
    <*> poolThresholds object
    <*> drepThresholds object
    <*> optional object "committee_min_size" bounded
    <*> optional object "committee_max_term_length" bounded
    <*> optional object "gov_action_lifetime" bounded
    <*> optional object "gov_action_deposit" bounded
    <*> optional object "drep_deposit" bounded
    <*> optional object "drep_activity" bounded
    <*> optional object "min_fee_ref_script_cost_per_byte" fraction
    <*> pure Nothing
    <*> pure Nothing
    <*> pure Nothing
    <*> pure Nothing
    <*> pure Nothing
    <*> pure Nothing
    <*> pure Nothing
    <*> pure Nothing
    <*> pure Nothing
    <*> pure Nothing
    <*> pure Nothing
    <*> pure Nothing
    <*> pure Nothing
    <*> pure Nothing
    <*> pure Nothing
    <*> pure Nothing
    <*> pure Nothing
    <*> pure Nothing
    <*> pure Nothing
    <*> pure Nothing
    <*> pure Nothing
    <*> pure Nothing
    <*> pure Nothing

required :: Object -> Key.Key -> (Value -> Parser a) -> Parser a
required object key parser = maybe (fail "missing field") parser (KeyMap.lookup key object)

optional :: Object -> Key.Key -> (Value -> Parser a) -> Parser (Maybe a)
optional object key parser = case KeyMap.lookup key object of
  Nothing -> pure Nothing
  Just Null -> pure Nothing
  Just value -> Just <$> parser value

grouped :: Object -> [Key.Key] -> Parser a -> Parser (Maybe a)
grouped object keys parser
  | all absent keys = pure Nothing
  | any absent keys = fail "incomplete group"
  | otherwise = Just <$> parser
  where
    absent key = maybe True (== Null) (KeyMap.lookup key object)

integer :: Value -> Parser Integer
integer (Number value)
  | base10Exponent value >= -100 && base10Exponent value <= 100 = either (const (fail "integer required")) pure (floatingOrInteger value :: Either Double Integer)
integer (String value)
  | Text.length value <= 21 && not (Text.null value) && Text.all (\c -> isDigit c || c == '-') value = maybe (fail "integer required") pure (readMaybe (Text.unpack value))
integer _ = fail "integer required"

bounded :: (Integral a, Bounded a) => Value -> Parser a
bounded value = do
  number <- integer value
  checkedBound number

checkedBound :: (Integral a, Bounded a) => Integer -> Parser a
checkedBound number = result
  where
    result
      | number >= toInteger (minBound `asTypeOf` value) && number <= toInteger (maxBound `asTypeOf` value) = pure value
      | otherwise = fail "integer outside bounds"
    value = fromInteger number

exact :: Value -> Parser Rational
exact (Number value)
  | base10Exponent value >= -100 && base10Exponent value <= 100 = pure (toRational value)
exact _ = fail "fraction required"

fraction :: Value -> Parser Fraction.NonNegativeRational
fraction value = do
  ratio <- exact value
  checked (Fraction.mkNonNegativeRational (numerator ratio) (denominator ratio))

interval :: Value -> Parser Interval.UnitInterval
interval value = do
  ratio <- exact value
  checked (Interval.mkUnitInterval (numerator ratio) (denominator ratio))

checked :: Either Error a -> Parser a
checked = either (const (fail "invalid domain value")) pure

nonce :: Object -> Parser (Maybe P.Nonce)
nonce object = case KeyMap.lookup "extra_entropy" object of
  Nothing -> pure Nothing
  Just Null -> pure (Just P.neutralNonce)
  Just (String value)
    | Text.length value == 64 && Text.all isHexDigit value -> Just <$> checked (P.mkNonce (ByteString.pack (pairs (Text.unpack value))))
  _ -> fail "invalid entropy"
  where
    pairs (a : b : rest) = fromIntegral (digitToInt a * 16 + digitToInt b) : pairs rest
    pairs _ = []

costModels :: Value -> Parser Models.CostModels
costModels = withObject "cost models" $ \object -> Models.fromList <$> traverse model (KeyMap.toList object)
  where
    model (key, value) = do
      language <- case Key.toText key of
        "PlutusV1" -> pure 0
        "PlutusV2" -> pure 1
        "PlutusV3" -> pure 2
        "PlutusV4" -> pure 3
        _ -> fail "unknown cost model language"
      costs <- withArray "cost vector" (traverse bounded . toList) value :: Parser [Int64]
      checked (Models.mkCostModel language costs)

exUnits :: Object -> Key.Key -> Key.Key -> Parser (Maybe Units.ExUnits)
exUnits object memory steps = grouped object [memory, steps] $ do
  memoryValue <- required object memory integer
  stepValue <- required object steps integer
  checked (Units.mkExUnits memoryValue stepValue)

poolThresholds :: Object -> Parser (Maybe PoolVotingThresholds)
poolThresholds object =
  grouped object keys $
    PoolVotingThresholds
      <$> get "pvt_motion_no_confidence"
      <*> get "pvt_committee_normal"
      <*> get "pvt_committee_no_confidence"
      <*> get "pvt_hard_fork_initiation"
      <*> get "pvt_p_p_security_group"
  where
    keys = ["pvt_motion_no_confidence", "pvt_committee_normal", "pvt_committee_no_confidence", "pvt_hard_fork_initiation", "pvt_p_p_security_group"]
    get key = required object key interval

drepThresholds :: Object -> Parser (Maybe DRepVotingThresholds)
drepThresholds object =
  grouped object keys $
    DRepVotingThresholds
      <$> get "dvt_motion_no_confidence"
      <*> get "dvt_committee_normal"
      <*> get "dvt_committee_no_confidence"
      <*> get "dvt_update_to_constitution"
      <*> get "dvt_hard_fork_initiation"
      <*> get "dvt_p_p_network_group"
      <*> get "dvt_p_p_economic_group"
      <*> get "dvt_p_p_technical_group"
      <*> get "dvt_p_p_gov_group"
      <*> get "dvt_treasury_withdrawal"
  where
    keys = ["dvt_motion_no_confidence", "dvt_committee_normal", "dvt_committee_no_confidence", "dvt_update_to_constitution", "dvt_hard_fork_initiation", "dvt_p_p_network_group", "dvt_p_p_economic_group", "dvt_p_p_technical_group", "dvt_p_p_gov_group", "dvt_treasury_withdrawal"]
    get key = required object key interval
