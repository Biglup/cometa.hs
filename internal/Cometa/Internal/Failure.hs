{-# OPTIONS_HADDOCK hide #-}

-- | Private snapshots of native failures. Public domain adapters translate these
-- into their own error types after native diagnostics have been copied.
module Cometa.Internal.Failure
  ( NativeFailure (..),
  )
where

import Data.Text (Text)

-- | Native status, copied context, and contract failures without a dependency on
-- a public domain API. Numeric codes remain exact, including unknown values.
data NativeFailure
  = -- | Operation label, exact native status, and copied diagnostic.
    NativeFailure !Text !Integer !Text
  | -- | Operation label for a successful status with an invalid native result.
    NativeContractFailure !Text
  deriving (Eq, Show)
