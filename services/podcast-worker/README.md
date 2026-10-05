# Podcast Media Worker

Processes shared RSS bridge, silence analysis, clip rendering, and asset cleanup jobs outside Gateway/AppView handlers. The feature defaults off. Derived assets use a private Railway S3-compatible bucket; AppView verifies ownership or published PDS records before proxying them.

## Development Deployment

1. Deploy the podcast migration through the existing Database Migrator and wait for success. The Development-only resources in `.railway/podcasts.ts`, imported by the existing infrastructure graph, own the Podcast Media private bucket in `sjc` and one Podcast Media Worker replica in `sfo`, co-located with Postgres. New services use this IaC graph, rather than legacy `railway/*.json` config paths. Seed `DATABASE_MIGRATOR_SERVICE_ID` with `${{Database Migrator.RAILWAY_SERVICE_ID}}` and `DATABASE_URL` with the Postgres reference before reviewing and applying the Development plan. The graph sets `APP_ENV=dev`; the shared schema-ready entrypoint verifies the migration manifest before startup. Variable references do not order GitHub push deployments.
2. Seed the shared media secret and dedicated bridge credentials from `.env.example`; IaC preserves these values and references the bucket's credentials. S3 credentials and the media secret are required even while the worker feature is disabled. Share `PODCAST_MEDIA_INTERNAL_SECRET` with AppView; set AppView `PODCAST_MEDIA_WORKER_URL` to the worker's private Railway HTTP endpoint. The graph sets `PODCAST_PUBLIC_GATEWAY_URL=https://api.testing.thesocialwire.app`. Keep the worker private.
3. Enable `PODCASTS_ENABLED=true` in AppView and the worker and `NEXT_PUBLIC_PODCASTS_ENABLED=true` in Web. Native visibility follows the authenticated server feature response; DEBUG or `SOCIALWIRE_TESTING_API` selects the Development host. Re-login after widening OAuth repo scopes.
4. Verify a subscribed public RSS feed, its attributed deterministic bridge records, protocol resolution, private progress, Range playback, silence analysis, authenticated exports, and an anonymous clip page/embed/oEmbed. Verify background/offline behavior on a physical iPhone before enabling Production.

Review the entire infrastructure plan before applying it. Existing indexing resources can have independent hosted drift; never apply unrelated variable deletions while promoting Podcasts. Apply only the reviewed podcast service/bucket settings when the broader partial is not clean.

Failed bridge metadata or media processing leaves ordinary listening available. Jobs retry automatically up to three attempts; explicit API retry is bounded. Public asset access requires a published clip, and deletion queues object cleanup. Public feeds only; no tokenized/private feed support.

## Checks

`bun --cwd services/podcast-worker typecheck` and `bun --cwd services/podcast-worker test` require FFmpeg/FFprobe. PostgreSQL integration tests use `PODCAST_TEST_DATABASE_URL` and refuse non-loopback databases; each run owns a random schema and removes it afterward. The Docker image supplies FFmpeg and rasterizes captions with Sharp, avoiding optional FFmpeg font filters.

Processing is limited to HTTPS public hosts, validated and pinned DNS addresses, bounded redirects/bytes, six-hour audio, ten-minute clips, and bounded caption transitions. Original source timestamps, speed, and pauses are retained in exports.
