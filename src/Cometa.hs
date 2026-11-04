-- | Version information and shared operation errors. Import domain modules
-- qualified, for example @Cometa.Crypto.Blake2b@ as @Blake2b@.
--
-- @
-- import qualified Cometa
--
-- main :: IO ()
-- main = Cometa.nativeVersion >>= print
-- @
module Cometa
  ( -- * Version information
    nativeVersion,

    -- * Errors
    Error (..),
  )
where

import Cometa.Error (Error (..))
import qualified Cometa.Internal.FFI.Native as Native
import Cometa.Internal.Ownership (copyStaticText)
import Data.Text (Text)

-- | Return the version of cardano-c used by the running application. This is
-- independent of the Cometa.hs package version.
nativeVersion :: IO Text
nativeVersion = Native.cVersion >>= copyStaticText
