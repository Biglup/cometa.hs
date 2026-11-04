-- | Expected validation and native failures. Applications can pattern-match on
-- errors without parsing diagnostic text.
--
-- @
-- case result of
--   Left err -> print err
--   Right value -> use value
-- @
module Cometa.Error
  ( Error (..),
  )
where

import Cometa.Error.Code (ErrorCode)
import Data.Text (Text)

-- | Errors returned by Cometa operations. Native codes and messages are copied
-- verbatim from cardano-c; no unknown native code is discarded.
data Error
  = -- | @NativeError operation code message@ preserves the operation name,
    -- exact numeric @cardano_error_t@ value, and native description. Operation
    -- names never contain user input.
    NativeError !Text !ErrorCode !Text
  | -- | BLAKE2b computation requires a digest length from 16 through 64 bytes.
    InvalidHashLength !Int
  | -- | A digest byte sequence must be nonempty.
    EmptyHash
  | -- | A hash's hexadecimal input must have a nonzero, even number of ASCII
    -- hexadecimal digits. Both uppercase and lowercase digits are accepted.
    InvalidHex
  | -- | The native library violated its success-result contract. This is kept
    -- separate from native error codes rather than inventing a native code.
    NativeContractViolation !Text
  deriving (Eq, Show)
