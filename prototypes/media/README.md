# Media and Home Stories Prototype

Tracking: [TSW-225](https://linear.app/stygian-tech/issue/TSW-225).

Run from the repository root:

```sh
python3 -m http.server 4317 --bind 127.0.0.1 --directory prototypes/media
```

Open http://localhost:4317. This is an isolated responsive web prototype with sample content, not a production route or authenticated integration. Existing application files are unchanged. No account actions or publishing occur.

Explore Home stories, Media → Short Videos, Media → Photos, source filters, photo lightboxes, and light/dark appearances. Podcasts remains a destination in the proposed Media group. Mobile widths demonstrate responsive web behavior, not a native iOS implementation.

See `lexicon-notes.md` and `lexicon-fixtures.json` for the researched record contracts and synthetic examples. UI source labels describe proposed adapters; they do not claim that sample assets were fetched from those services. Real integration still needs fetching/indexing, moderation, blocked/muted authors, expiration rules, pagination, and crosspost deduplication.

## Sample Media

- `assets/flower.mp4`: MDN's CC0 flower example, downloaded from https://interactive-examples.mdn.mozilla.net/media/cc0-videos/flower.mp4.
- Photography: sample Unsplash images; sample names and captions do not identify their actual photographers.

The prototype is deliberately outside the app build. Validate its flows in a browser; the application test suite does not exercise this standalone HTML.

## Native iOS and Video Editor

The standalone native SwiftUI app is in `ios/`; see its README for generation and build instructions. Both prototypes now include a Bluesky composer with video attachment, description, removal, and local preview. Web accepts a local MP4 or bundled sample; iOS offers a Files MP4 picker or bundled sample. Uploading and publishing remain disconnected.
