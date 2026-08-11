# [Format name]

**Extensions:** `[extensions]`
**Chip:** [target chip or playback device]
**Module:** `src/formats/[module].zig`

[Use **Paths:** instead of **Extensions:** when matching depends on a basename
or a set of companion files. Add another concise format fact only when it
belongs in every reader's first screen.]

[State what the format stores and where it came from. Keep this to one short
paragraph.]

External reference:
[Specification name](https://example.com/specification).

## Identification

[Describe path matching, magic values, minimum sizes, detection order, and the
conditions under which the decoder claims or rejects the input.]

## File layout

[List byte order, headers, offsets, field sizes, stream boundaries, side files,
compression, and metadata containers. Use offset tables where useful.]

## Decoding

[Give an ordered parsing algorithm. Define every record, command, state
transition, validation rule, and malformed-input behavior needed for an
independent parser.]

### [Format-specific subsection]

[Add focused subsections for command streams, instruments, patterns, archives,
or other structures. Remove this subsection when it is not needed.]

## Timing

[Define the file's timing unit, default rate, rate conversion, fractional
carry, duration calculation, and loop timing. State when timing is inherited
from another format.]

## Playback

[Describe initialization, register or sample output, end-of-stream behavior,
loops, and any deliberate compatibility behavior.]

## Metadata

[Describe embedded fields, text encoding, fallback values, and what sehnsucht
exposes. Write "The format contains no metadata" when appropriate.]

## Errors

[List rejection conditions and recoverable malformed-input behavior. Name
sehnsucht errors when that helps callers distinguish failures.]

## Compatibility notes

[State unsupported variants, ambiguous detection rules, lossy mappings,
historical quirks, and differences from other common decoders. Omit product UI
details that do not affect parsing or playback.]
