-- | Hash a UTF-8 command-line message, or a small default message.
module Main (main) where

import qualified Cometa
import qualified Cometa.Crypto.Blake2b as Blake2b
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import qualified Data.Text.IO as Text
import System.Environment (getArgs)
import System.Exit (die)

main :: IO ()
main = do
  arguments <- getArgs
  let message = case arguments of
        [] -> "Hello, Cardano!"
        _ -> unwords arguments
  version <- Cometa.nativeVersion
  Text.putStrLn (Text.pack "cardano-c " <> version)
  result <- Blake2b.compute 32 (Text.encodeUtf8 (Text.pack message))
  case result of
    Left failure -> die (show failure)
    Right digest -> Text.putStrLn (Blake2b.toHex digest)
