# Work with slots and times

Transaction validity intervals use slot numbers. Script contexts can also need
Unix timestamps. `Cometa.SlotConfig` relates the two using a reference slot, its
start time and a constant slot duration. All times and durations are integer
**milliseconds**, not seconds.

```haskell
import qualified Cometa.SlotConfig as Slots

startTime = Slots.slotToTime Slots.preview 100
slotNumber = startTime >>= Slots.timeToSlot Slots.preview
```

`slotToTime` returns the first millisecond of a slot. `timeToSlot` returns the
slot containing a timestamp: the start instant belongs to that slot, while the
next slot's start belongs to the next slot.

Use `mainnet`, `preprod` or `preview` for their one-second schedules. Mainnet's
schedule begins at slot 4,492,800; Preprod's begins at slot 86,400; Preview's
begins at slot zero. These are constant-duration schedules, not complete era
histories. They reject earlier slots and timestamps. Historical queries across a
slot-duration change need the configuration for that period.

For an emulator or a custom schedule, `mkSlotConfig referenceTime referenceSlot
duration` constructs a configuration. It rejects zero duration. Both conversions
reject results beyond the unsigned 64-bit range rather than wrapping them.
Neither conversion queries a network or reads the current time.
