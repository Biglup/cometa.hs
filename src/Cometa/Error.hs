-- | Validation and operation failures. Match constructors and status codes to
-- handle errors; diagnostic messages are intended for people.
--
-- @
-- import qualified Cometa.Crypto.Blake2b as Blake2b
-- import qualified Data.ByteString as ByteString
--
-- main :: IO ()
-- main = case Blake2b.fromBytes ByteString.empty of
--   Left err -> print err
--   Right digest -> print digest
-- @
module Cometa.Error
  ( Error (..),
  )
where

import Cometa.Error.Code (ErrorCode)
import Data.Text (Text)

-- | Expected failures returned by Cometa operations. Equality compares every
-- payload, including diagnostic text. 'Show' is diagnostic output.
data Error
  = -- | An operation failed with a cardano-c status code. Unknown numeric codes
    -- remain available through @toNumber@ in "Cometa.Error.Code".
    NativeError
      -- | Operation name, such as @blake2b.compute@; excludes user input.
      !Text
      -- | Exact status code, with a name when recognized.
      !ErrorCode
      -- | Diagnostic message; do not parse it to determine the failure.
      !Text
  | -- | The requested BLAKE2b digest length is outside 16 through 64 bytes.
    InvalidHashLength
      -- | Requested digest length in bytes.
      !Int
  | -- | The digest byte sequence is empty.
    EmptyHash
  | -- | Hexadecimal input is empty, has an odd number of digits, or contains
    -- characters other than ASCII hexadecimal digits. Both cases are accepted.
    InvalidHex
  | -- | An operation reported success but did not produce a valid result.
    NativeContractViolation
      -- | Operation name; excludes user input.
      !Text
  deriving (Eq, Show)
