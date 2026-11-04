-- | The experimental Cometa foundation. Domain operations are intended to be
-- imported qualified, for example @Cometa.Crypto.Blake2b@ as @Blake2b@.
--
-- @
-- version <- nativeVersion
-- print version
-- @
module Cometa
  ( nativeVersion,
    Error (..),
  )
where

import Cometa.Error (Error (..))
import qualified Cometa.Internal.FFI.Native as Native
import Cometa.Internal.Ownership (copyStaticText)
import Data.Text (Text)

-- | Version reported by the linked cardano-c library. This is independent of
-- the Haskell package version and does not establish ABI compatibility by itself.
nativeVersion :: IO Text
nativeVersion = Native.cVersion >>= copyStaticText
