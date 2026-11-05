# Governance corpus provenance

The hexadecimal CBOR constants in Governance.hs are imported from cardano-c
`eadb95cd3ca7f711c203d7f2f4ee21c150d4d7f1`:

* `lib/tests/common/anchor.cpp`: ANCHOR_CBOR.
* `lib/tests/common/governance_action_id.cpp`: GOVERNANCE_ACTION_ID_CBOR.
* `lib/tests/common/drep.cpp`: DREP_KEY_HASH_CBOR, DREP_SCRIPT_HASH_CBOR,
  DREP_ABSTAIN_CBOR and DREP_NO_CONFIDENCE_CBOR.
* `lib/tests/voting_procedures/voting_procedure.cpp`: the six CBOR choice/anchor constants.
* `lib/tests/voting_procedures/voting_procedures.cpp`: CBOR.

Copyright 2024 Biglup Labs, Apache License 2.0 (repository LICENSE).
Tests independently assemble public Haskell credentials, anchors, choices,
action identifiers and nested maps to these bytes. The native oracle decodes
those bytes, obtains typed fields, constructs fresh anchors/actions/DReps/voters/
procedures/collections, and compares native serialization to Haskell encoding.
No corpus inputs require a network or signing key.

Hedgehog generators and boundary encodings in Governance.hs are original Cometa
2026 tests under Apache-2.0, not imported upstream generator implementations.
