# Password crypto vector provenance

All inputs are deterministic public test data, never wallet material.

Native source: Biglup/cardano-c revision
`7811fe94dad90f30478ed4b61d96677f188abaa8`,
`lib/tests/crypto/pbkdf2.cpp` (password/salt, one iteration, 64 bytes) and
`lib/tests/crypto/emip3.cpp` (first two decrypt vectors, including empty password; plaintext bytes 00 through 09).
Copyright 2024 / 2023 Biglup Labs, Apache-2.0, same license as this repository.
Native PBKDF and EMIP format/ownership are audited from the matching headers,
implementations and vendored libsodium, not inferred only from fixtures.

Independent locally generated answers use Python hashlib.pbkdf2_hmac and
cryptography.hazmat.primitives.ciphers.aead.ChaCha20Poly1305. They do not call
cardano-c. Reproduce with the following recipe (hex strings are asserted by
`test/PasswordCrypto.hs`):

```python
import hashlib
from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305

print(hashlib.pbkdf2_hmac('sha512', b'pass\x00word', b'sa\x00lt', 2, 65).hex())
salt, nonce = bytes(range(32)), bytes(range(32, 44))
key = hashlib.pbkdf2_hmac('sha512', b'p\x00w', salt, 19162, 32)
aead = ChaCha20Poly1305(key).encrypt(nonce, b'hello\x00world', b'')
print((salt + nonce + aead[-16:] + aead[:-16]).hex())
empty = ChaCha20Poly1305(key).encrypt(nonce, b'', b'')
print((salt + nonce + empty[-16:] + empty[:-16]).hex())
```

The binary case explicitly checks length-aware NUL handling and multi-block
PBKDF output. The independent EMIP answers cover nonempty and empty plaintext and check tag placement, salt/nonce
lengths, iteration count, key length and empty AAD. Encryption tests roundtrip
randomly generated envelopes; they never assume deterministic encryption.
The prefix property is newly authored and checks a PBKDF law, not independent
algorithm correctness. No external text or independent implementation is copied.
