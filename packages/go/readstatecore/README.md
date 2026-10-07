# readstatecore

Repository-local import: `github.com/stygian-tech/the-social-wire/packages/go/readstatecore`. See the [module guide](../README.md) for toolchains and shared verification.

## Responsibilities

Use json.Decoder.UseNumber for untrusted canonical values; float64 is deliberately unsupported. MaximumSequence is 2^53−1, portable JSON records are at most 65,536 bytes, canonical construction/output at most 16 MiB, and nesting at most 32. These separate limits serve different operations. Nil selector slices preserve absence; an empty slice is not interchangeable with omitted selectors. Projection owns clones and returns clones. Receipt acknowledgements prove contiguous pending intents, not transport delivery or identity authentication.

## Source map

| File | Responsibility |
| --- | --- |
| [models.go](models.go) | Defines portable v1/v2 manifest, operation, boundary, and resolution fields with canonical JSON names. Pointers and nil slices preserve absent-field distinctions. Sequences are bounded to the interoperable JavaScript safe-integer maximum. |
| [validation.go](validation.go) | Checks timestamps, viewer-owned chunk references, selector exclusivity, record sizes, and version-specific manifest invariants. These checks cover the implemented models; they are not a strict closed-shape v2 loader and do not verify remote CID contents. |
| [projection.go](projection.go) | Builds an immutable indexed snapshot from validated operations. Resolution selects the greatest applicable sequence across exact subjects and author/site boundaries; timestamp equality uses the boundary entry ID as an inclusive tie-break. |
| [canonical_buffer.go](canonical_buffer.go) | Stops encoded DAG-CBOR growth at 16 MiB even when the upstream codec writes incrementally. This hashing bound is separate from the 64 KiB portable-record JSON bound. |
| [canonical_hash.go](canonical_hash.go) | Assembles the restricted receipt value model into IPLD nodes and delegates canonical DAG-CBOR ordering/encoding to go-ipld-prime. Construction and output are bounded; floats, bytes, links, unsupported types, unsafe integers, and invalid UTF-8 are rejected. |
| [intent_hash.go](intent_hash.go) | Hashes a logical action independently of assigned sequence. Split parts must agree on action metadata; exact subjects and boundary selectors are deduplicated and sorted before a v2 domain-separated canonical hash is computed. |
| [device_receipt.go](device_receipt.go) | Chains contiguous device counters and original-intent hashes with domain separation. A remote acknowledgement is accepted only if recomputing the proposed prefix from locally pending intents yields the same counter and hash. |

## Verification

From the repository root: `GOWORK=off go -C packages/go test -race ./readstatecore`.

[projection_test.go](projection_test.go) covers:

- `TestSharedProtocolFixture`
- `TestBoundaryMicrosecondsAndUTF8Tie`
- `TestCanonicalRejectsLossyValues`
- `TestDAGCBORRetainsProtocolBounds`
- `TestFixtureCanonicalReceiptHashes`

## Migration boundary

Status: **partial**. `migration/status.json` is the machine-readable completion record.

Remaining work:

- strict v2 closed-shape loading
- v1 extension retention
- v2 merge/compaction and manifest publication
- sync/store/transport/GC implementations
