# thinappviewcore

Repository-local import: `github.com/stygian-tech/the-social-wire/packages/go/thinappviewcore`. See the [module guide](../README.md) for toolchains and shared verification.

## Responsibilities



## Source map

| File | Responsibility |
| --- | --- |
| [projection_event.go](projection_event.go) | Validates a stored event against its independent cursor/kind/DID metadata before decoding with the official Jetstream SDK. Numeric strings remain backward-compatible, record integers stay exact, and event-specific payload rules reject malformed commits or lifecycle events. |
| [rss_parser.go](rss_parser.go) | Translates publisher RSS, Atom, and JSON Feed bytes through gofeed into shared item fields. Published/updated timestamps fall back to the supplied clock, are rendered in UTC, and are sorted by actual instant. Network fetching and durable ingestion remain caller responsibilities. |
| [rss_thumbnail.go](rss_thumbnail.go) | Normalizes feed/image URLs and discovers thumbnails from explicit media, article HTML, and summary HTML. The HTML tokenizer ignores comment/script text and decodes attributes. URL normalization is not a DNS, redirect, or fetch authorization check. |

## Verification

From the repository root: `GOWORK=off go -C packages/go test -race ./thinappviewcore`.

[projection_event_test.go](projection_event_test.go) covers:

- `TestProjectionEnvelopeMetadataAndMicroseconds`
- `TestSDKProjectionPreservesRecordIntegersAndRejectsNonRecords`
- `TestProjectionDeleteDoesNotRequireRecord`
- `TestAccountEventUsesProviderCursor`

[rss_parser_test.go](rss_parser_test.go) covers:

- `TestRSSCDATAAndRelativeImage`
- `TestFeedParsingPreservesFractionalDatesAndOrdersInstants`
- `TestFeedParsingSupportsJSONFeed`
- `TestThumbnailIgnoresCommentsAndScriptsAndDecodesEntities`
- `TestRSSMixedTitleDoesNotLosePrefix`
- `TestAtomEnclosureAndFallbackClock`
- `TestRSSRejectsAudioThumbnail`

## Migration boundary

Status: **partial**. `migration/status.json` is the machine-readable completion record.

Remaining work:

- transactional event application, claims and acknowledgements
- repository repairs and lifecycle cleanup
- RSS identities/polling and PDS backfill
- stores, projections, caches and remaining models
- podcast parsing, listener protocol, and store surfaces added on Development
