# Media Prototype: Source Contracts

Verified against public upstream schemas on 2026-10-21. This is a fixture-backed UI prototype, not a live feed, ingestion service, publication flow, or interoperability certification. `lexicon-fixtures.json` contains synthetic illustrative record shapes; identities, timestamps, AT-URIs, blob references, and sizes are not real or fetchable. Visual assets are independent of those blob references. These fixtures have not been run through the upstream schema validators.

## Verified Sources

| Source | Record NSIDs | Media Representation |
| --- | --- | --- |
| Bluesky | `app.bsky.feed.post` | `app.bsky.embed.images`, `app.bsky.embed.video`, `app.bsky.embed.gallery`; media can also be nested in `app.bsky.embed.recordWithMedia` |
| Spark | `so.sprk.feed.post`, `so.sprk.story.post` | Posts contain `so.sprk.media.images` or `so.sprk.media.video`; stories contain a single `so.sprk.media.image` or video |
| Grain | `social.grain.photo`, `social.grain.gallery`, `social.grain.gallery.item`, `social.grain.story` | Separate photo records linked into ordered galleries; story records carry a media blob |
| Flashes | Ordinary posts are Bluesky compatible | No dedicated Flashes story NSID verified; do not invent one |

Spark's official domain is **sprk.so**. The requested `spark.so` currently resolves to a parked domain. The official client identifies `so.sprk.*` as its namespace; the actual schema IDs resolve the README's inconsistent later spelling.

### Bluesky

- [Post](https://github.com/bluesky-social/atproto/blob/main/packages/bsky/lexicons/app/bsky/feed/post.json)
- [Images](https://github.com/bluesky-social/atproto/blob/main/packages/bsky/lexicons/app/bsky/embed/images.json)
- [Video](https://github.com/bluesky-social/atproto/blob/main/packages/bsky/lexicons/app/bsky/embed/video.json)
- [Gallery](https://github.com/bluesky-social/atproto/blob/main/packages/bsky/lexicons/app/bsky/embed/gallery.json)
- [Record With Media](https://github.com/bluesky-social/atproto/blob/main/packages/bsky/lexicons/app/bsky/embed/recordWithMedia.json)

The video view provides `playlist`, optional `thumbnail`, `alt`, and `aspectRatio`. Image views use `thumb`; gallery image views use `thumbnail`. The current gallery schema allows 20 items but recommends a 10-item soft limit for authoring UIs. A normal Bluesky post is not inherently a story, and video embeds do not inherently mean vertical shortform content.

### Spark

- [Official client and project description](https://github.com/sprksocial/client)
- [Feed post](https://github.com/sprksocial/server/blob/main/lexicons/so/sprk/feed/post.json)
- [Story post](https://github.com/sprksocial/server/blob/main/lexicons/so/sprk/story/post.json)
- [Images](https://github.com/sprksocial/server/blob/main/lexicons/so/sprk/media/images.json)
- [Single image](https://github.com/sprksocial/server/blob/main/lexicons/so/sprk/media/image.json)
- [Video](https://github.com/sprksocial/server/blob/main/lexicons/so/sprk/media/video.json)

Posts require `createdAt` and `media`; caption is an optional object. Crossposts are strong references and can inform future deduplication. Stories have a separate collection. The story record itself does not provide an expiration field; production retention and visibility behavior needs service-level verification.

### Grain

- [Photo](https://github.com/grainsocial/grain/blob/main/lexicons/social/grain/photo/photo.json)
- [Gallery](https://github.com/grainsocial/grain/blob/main/lexicons/social/grain/gallery/gallery.json)
- [Gallery item](https://github.com/grainsocial/grain/blob/main/lexicons/social/grain/gallery/item.json)
- [Story](https://github.com/grainsocial/grain/blob/main/lexicons/social/grain/story/story.json)

Gallery items connect gallery and photo AT-URIs with `position`; the photo is not embedded in the gallery record. Stories require `media`, `aspectRatio`, and `createdAt`. Preserve moderation labels and source identity in a future adapter.

### Flashes

- [Official site: compatible Bluesky photo/video posts](https://www.flashes.blue/)
- [Official account: 24-hour story announcement](https://bsky.app/profile/flashes.blue/post/3mbywrjaeugbv)
- [Official support repository](https://github.com/birdsongapps/Flashes)

The support repository did not expose application source or story schemas. Flashes photo fixtures may use Bluesky post shapes, but the fixture's Flashes attribution is illustrative; a plain Bluesky post does not prove which client authored it. Dedicated Flashes story ingestion remains unverified.

## Prototype Boundary

Use the fixture source map for illustrative source badges and tabs. Keep story fixtures from Spark and Grain distinct from ordinary photo/video posts. The prototype may demonstrate story progress, next/previous navigation, local seen state, and video controls with local assets. Such interactions do not imply persisted state or writes to any account.

Production integration still requires service discovery and endpoint verification, authorization, ingestion/projection ownership, moderation and blocking, source-aware interactions, crosspost deduplication, accessible media playback, and explicit story expiration semantics. Do not label the prototype as connected or display fixture activity as live network activity.
