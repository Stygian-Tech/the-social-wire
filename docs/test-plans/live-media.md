# Live Media Development acceptance (TSW-225)

The actual web routes `/media/photos` and `/media/short-videos` use the viewer's live Bluesky Following timeline. The sidebar's Media section retains Podcasts and its playback preview. Mobile More includes Photos and Short Videos. Visibility follows the existing Social display preference; Podcasts keeps its own preference/capability.

## Source contract

The client obtains candidates through the existing authenticated PDS → Bluesky AppView Agent proxy. Gateway/AppView `POST /v1/media/project` classifies at most 30 candidates / 512 KiB without fetching URLs, retaining data, or accepting upstream OAuth credentials. Clients keep the original upstream cursor, including pages with zero selected posts. Media deduplicates original/repost overlap by post URI and preserves upstream ordering. Existing viewer, moderation, labeler, cancellation, and playback paths remain in use.

- Photos accepts Bluesky image views, current image galleries and `recordWithMedia` media.
- Short Videos accepts portrait video views (positive integral dimensions, height greater than width), excluding GIF presentation. Duration is unavailable in the official view schema and is not verified. UI discloses this selection rule.
- Spark and Grain schemas are distinct and verified, but their discovery, viewer authorization and moderation services are not integrated. Ordinary Bluesky posts cannot establish Flashes attribution. No stories, composer uploads, fixtures, global discovery or cross-source attribution are included.

Primary source schemas rechecked 2026-10-26:

- [Bluesky timeline](https://github.com/bluesky-social/atproto/blob/main/packages/bsky/lexicons/app/bsky/feed/getTimeline.json)
- [Video views](https://github.com/bluesky-social/atproto/blob/main/packages/bsky/lexicons/app/bsky/embed/video.json)
- [Image galleries](https://github.com/bluesky-social/atproto/blob/main/packages/bsky/lexicons/app/bsky/embed/gallery.json)
- [Spark posts](https://github.com/sprksocial/server/blob/main/lexicons/so/sprk/feed/post.json)
- [Grain photos](https://github.com/grainsocial/grain/blob/main/lexicons/social/grain/photo/photo.json)

## Native boundary

Native includes typed request/response models and authenticated `SocialWireGatewayClient.projectMedia`, with request bounds, response validation and account fencing. There is no native Media screen in this release. Existing native Social author DTOs omit viewer mute/block state and its renderer does not implement the web moderation decisions; safely exposing these feeds requires that work first. The native shell currently disables Podcasts navigation. Do not infer native acceptance from contract tests.

## Authenticated Development checklist

1. Confirm Web, Gateway and App View Development deployment `SUCCESS` for the exact merged commit; probe public readiness separately.
2. Sign in on Development. Open Media → Photos and Short Videos on desktop and mobile More. Confirm source disclosure, actual network data, media descriptions, image viewer and video playback.
3. Verify blocked, muted and hidden posts and configured labels stay withheld. Change accounts while a request is pending and confirm no old-account posts appear.
4. Refresh each mode, continue through empty pages, and load overlapping pages. Confirm stable order, no duplicate posts and preserved continuation. Disconnect network, retry, and verify cached posts remain visible with an error.
5. Exercise portrait, landscape, missing dimensions, GIF presentation, image galleries and quote-with-media. Confirm only the documented selections appear.
6. Verify Podcasts navigation, hover/hold mini-player and ongoing playback. Check narrow widths and light/dark themes.

Automated tests do not prove authenticated live acceptance or hosted deployment health. Production is outside this release.
