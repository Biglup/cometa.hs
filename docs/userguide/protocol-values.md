# Work with exact protocol values

Represent execution prices with `Cometa.Protocol.Rational`. Validate runtime
numerators and denominators once with `mkNonNegativeRational`, then assemble
`ExUnitPrices` and `ExUnits` directly. Memory prices are lovelace per memory unit;
step prices are lovelace per CPU step.

```{literalinclude} ../../examples/ProtocolValues.hs
:language: haskell
:start-at: module Main
```

Run the example with `cabal run cometa-protocol-values`.
The computed value is the execution fee component; transaction byte fees and
reference-script fees are separate.

Fractions use unsigned 64-bit numerators and positive unsigned 64-bit
denominators. They preserve the supplied pair, so `2/4` serializes as `2/4`.
Equality and ordering compare exact numeric values, so it equals `1/2`.
`toRational` supplies a standard reduced Haskell `Rational` for arithmetic.
Prices and other nonnegative protocol fractions may exceed one.

Use `Cometa.UnitInterval.mkUnitInterval` for proportions such as voting approval
thresholds. This additionally rejects numerators larger than denominators.
`PoolVotingThresholds` and `DRepVotingThresholds` assemble these validated
proportions into named records. A zero denominator is invalid.

`ProtocolVersion` stores an unsigned 64-bit major and unsigned 32-bit minor.
`ExUnits` stores unsigned 64-bit memory and step counts. Their `mk` functions
validate external `Integer` input; direct record construction uses already
bounded Haskell integer types.

`Cometa.Protocol.CostModels` retains raw language identifiers from 0 through 255
and ordered signed 64-bit parameter vectors, including future languages. Vectors contain at most 2048 parameters. Constructing a vector does not establish
that an evaluator accepts its length or values. `fromList` and `insert` replace
an existing language model; CBOR decoding rejects duplicate language keys.
Individual cost-model CBOR contains the cost array alone; provide its language
identifier when decoding. The collection codec supplies language keys in an
ascending map.

All these codecs are pure. They reject malformed schema, out-of-range values and
trailing data with `InvalidProtocolCbor`. Decoding retains fraction pairs and
accepts nonminimal integers and indefinite arrays. Encoding uses shortest
integers and definite arrays; whole-input byte identity is not retained.
