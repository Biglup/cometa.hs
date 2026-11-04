# BIP39 test fixture provenance

All entropy and phrases are deterministic, public test-only secrets. Never use
these fixtures for a real wallet. Tests need no credentials or live network.

## Fixed vectors

`Fixtures.Bip39` contains all 24 entropy/English phrase pairs from cardano-c
`lib/tests/bip39.cpp`, revision
`8dc0c55f4132fcaa2e7961b6cfbfea96a6d93b5d`. The current build revision is
recorded separately in `native/cardano-c.ref`. That file is
Copyright 2024 Biglup Labs, licensed Apache-2.0; only vector data was transcribed.
Every pair was crosschecked byte-for-byte against the 24 English cases in
[Trezor python-mnemonic vectors.json](https://github.com/trezor/python-mnemonic/blob/b57a5ad77a981e743f4167ab2f7927a55c1e82a8/vectors.json),
revision `b57a5ad77a981e743f4167ab2f7927a55c1e82a8`. The Trezor seed and extended-key
columns are not imported or tested: the Cardano root KDF is distinct.

Trezor's MIT notice is retained in `BIP39-TREZOR-LICENSE.md`.

Two additional fixed cases cover 20 and 28 zero entropy bytes, absent from both
corpora. Expected phrases were generated independently with Python 3's
`hashlib.sha256` and the pinned native English wordlist. This checks bit/checksum
marshaling with an independent algorithm, not independent dictionary content:

```python
import hashlib

def phrase(entropy, words):
    bits = ''.join(f'{byte:08b}' for byte in entropy)
    bits += f'{hashlib.sha256(entropy).digest()[0]:08b}'[:len(entropy) // 4]
    return ' '.join(words[int(bits[i:i + 11], 2)]
                    for i in range(0, len(bits), 11))
```

## New tests

The Haskell generators, properties and lifecycle scenarios are original. Three
hundred Hedgehog cases cover all five entropy sizes, entropy/phrase roundtrips
and canonical text. Invalid tests cover length/count bounds, unknown dictionary
words, checksum, case, NUL, empty elements, whitespace inside words, non-ASCII
input and the Unicode replacement character (as seen after lossy UTF-8 decoding).
The public input is `Text`, so invalid UTF-8 bytes cannot enter this API directly.
Unicode whitespace between words is accepted and canonicalized to ASCII spaces.

Repeated success/failure, snapshots after GC, cancellation and scoped BIP32 root
integration exercise native buffer lifetime. Both native conversions allocate
no native owners: word pointers borrow static strings; entropy is caller-owned
scratch and is wiped on every exit, including checksum failure after native
output is written. Validation does not make a hidden Haskell entropy copy.
Native stack intermediates and host secret values are not comprehensively wiped.
No native allocation-failure or owner-retention test applies to these functions.
