# Inspect and change protocol parameters

Protocol parameters control transaction fees, size limits, execution budgets,
and governance thresholds. `Cometa.Protocol.Parameters` represents a snapshot
with typed fields. Fees and deposits are integer lovelace; sizes are bytes;
rational rates and execution prices are exact fractions.

A snapshot contains the common fields and the era-dependent fields actually
observed. `Nothing` in an optional snapshot field means unavailable. Do not fill
future fields with zero or invented network defaults. Historical decentralization
and extra entropy are optional too. A snapshot does not validate the complete rules of a particular ledger era.

To assemble a proposal changing only two fee parameters:

```haskell
import qualified Cometa.Protocol.Parameters.Update as Update

change :: Update.Update
change = Update.empty
  { Update.updateMinFeeA = Just 44
  , Update.updateMinFeeB = Just 155381
  }
```

`Update.apply change current` returns a new snapshot and preserves every field
absent from the change. The original snapshot remains available. Applying a
change to an unavailable optional parameter makes that parameter available in
the resulting value. This is data assembly; callers must choose changes valid
for the target ledger era. `Update.fromParameters current` includes every
available snapshot field and omits unavailable ones.

Maximum pledge leverage and the Peras bootstrap round have nullable values.
In a change, `Nothing` preserves the current value, `Just Nothing` explicitly
selects unbounded leverage or no bootstrap round, and `Just (Just value)` sets a
bound or round. In a snapshot, the additional outer availability layer preserves
the difference between an unavailable field and an available null value.

`Update.encodeCbor change` serializes a fresh update. For an imported proposal,
`Update.decodeCbor bytes` validates the entire input and returns an opaque
`EncodedUpdate`. Inspect with `Update.toUpdate`; retain exact bytes with
`Update.toCbor`. Encoding the inspected value again may normalize map order,
integer widths, and collection framing. Preserve exact imported bytes when they
contribute to transaction identity.

Unknown and duplicate parameter keys, malformed fields, invalid bounds and
trailing bytes return `InvalidProtocolParametersCbor`. Rational values and
proportions use their dedicated validated constructors; reference script cost
stride must be between 1 and 4294967295 bytes. A nonneutral entropy nonce is
exactly 32 bytes. These operations are pure.

Run the complete example with `cabal run cometa-protocol-parameters`:

```{literalinclude} ../../examples/ProtocolParameters.hs
:language: haskell
:start-at: module Main
```

## Inspect the data seen by governance scripts

`Update.toPlutusData change` returns the changed-parameter map used by Plutus
governance scripts. Its integer keys identify parameters; rational values become
reduced numerator/denominator lists. This differs from `Update.encodeCbor`, which
encodes the ledger update itself.

```haskell
inspectChange :: IO ()
inspectChange = do
  result <- Update.toPlutusData change
  case result of
    Left failure -> print failure
    Right value -> print value
```

Absent parameters are omitted. Historical decentralization, entropy and protocol
version changes are excluded from this script-data map. The conversion does not
check whether a proposed change is allowed in the target era.
