# Changed-parameter Plutus data

The scalar/rational/execution-unit case in `test/Parameters.hs` adapts
`lib/tests/protocol_params/protocol_param_update.cpp`, test
`encodesTagsValuesAndReducesRationals`, from cardano-c commit
`eadb95cd3ca7f711c203d7f2f4ee21c150d4d7f1` (Apache-2.0).
The expected semantic data is assembled independently with Haskell constructors.
It verifies rational reduction and memory-before-steps ordering, rather than
comparing a native conversion with itself.

The nullable, unsigned-64-bit and complete-field tests are Cometa-authored.
They check explicit unbounded values, exact large integers, unchanged input
encoding, repeated conversions and all supported field identifiers. Legacy
parameter keys 12–14 are intentionally excluded from ChangedParameters; key15
is not a supported parameter. These tests make no claim about governance
acceptance of the constructed updates on a network.
