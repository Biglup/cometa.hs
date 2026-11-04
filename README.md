<div align="center">
  <a href="https://cometa.dev/" target="_blank">
    <img align="center" width="300" src="assets/cometa_hs.png" alt="Cometa.hs">
  </a>
</div>

<br>

<div align="center">

![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)
[![Documentation](https://readthedocs.org/projects/cometahs/badge/?version=latest)](https://cometahs.readthedocs.io/en/latest/)
[![Twitter Follow](https://img.shields.io/twitter/follow/BiglupLabs?style=social)](https://x.com/BiglupLabs)

</div>

<hr>

Cometa.hs is a Haskell interface to [cardano-c](https://github.com/Biglup/cardano-c).
It is in development and is not yet published on Hackage.

- [Official website](https://cometa.dev/)
- [Installation and local builds](docs/userguide/installation.md)
- [Documentation](https://cometahs.readthedocs.io/en/latest/)
- [Haddock API reference](https://cometahs.readthedocs.io/en/latest/api-reference.html) — CI downloads and local builds.
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
