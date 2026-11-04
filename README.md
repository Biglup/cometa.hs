<div align="center">
  <a href="https://cometa.dev/" target="_blank">
    <img align="center" width="300" src="assets/cometa_hs.png" alt="Cometa.hs">
  </a>
</div>

<br>

<div align="center">

![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)
[![Twitter Follow](https://img.shields.io/twitter/follow/BiglupLabs?style=social)](https://x.com/BiglupLabs)

</div>

<hr>

Cometa.hs is a Haskell interface to [cardano-c](https://github.com/Biglup/cardano-c).
It is in initial development and is not yet published on Hackage. The current
foundation provides Blake2b hashes and native version information; transaction
building, signing, providers, and the remaining domains are not yet available.

- [Official website](https://cometa.dev/)
- [Installation and local builds](docs/userguide/installation.md)
- [User guide](docs/userguide/index.md)
- [API reference](docs/userguide/api-reference.md)
- [Contributing](docs/userguide/development.md)

## Hash a message

Build from source with GHC, Cabal, and the pinned cardano-c dependency; see
[installation](docs/userguide/installation.md). Compute a 32-byte digest:

```haskell
import qualified Cometa.Crypto.Blake2b as Blake2b
import qualified Data.ByteString.Char8 as ByteString
import qualified Data.Text.IO as Text
import System.Exit (die)

main :: IO ()
main = do
  result <- Blake2b.compute 32 (ByteString.pack "Hello, Cardano!")
  case result of
    Left failure -> die (show failure)
    Right digest -> Text.putStrLn (Blake2b.toHex digest)
```

## License

Cometa.hs is licensed under the Apache License 2.0. See [LICENSE](LICENSE).
