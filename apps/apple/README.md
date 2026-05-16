# The Social Wire iOS

Native SwiftUI client for The Social Wire.

## Development

Generate the Xcode project:

```sh
xcodegen generate
```

Run tests from `apps/apple` (use a concrete simulator id if `name=iPhone 16` is ambiguous):

```sh
xcodebuild test -scheme SocialWire -destination 'platform=iOS Simulator,id=<Simulator-UUID>'
```

## OAuth client metadata (production vs preview)

Production uses `client_id` **`https://thesocialwire.app/ios-client-metadata.json`**, served from [`apps/web/public/ios-client-metadata.json`](../web/public/ios-client-metadata.json).

Until that file is live on production, you can:

**A. Next.js / Vercel** — Deploy **`apps/web`** to a **Vercel preview** (or staging host) so `ios-client-metadata.json` is reachable over HTTPS, then follow the steps below using that URL.

**B. Swift API (local + tunnel)** — Run [`services/api`](../../services/api/README.md) (`APP_ENV=local swift run App`). Expose it with **ngrok** (or similar), set `OAUTH_PUBLIC_ORIGIN` to the tunnel URL if needed, then use `https://<tunnel>/ios-client-metadata.json` as `ATProtoOAuthClientID`.

Then:

1. Ensure **client metadata** matches that URL: for Vercel/Next, edit the deployed JSON; for Swift API, `GET /ios-client-metadata.json` already returns a consistent `client_id` + `redirect_uris` for the resolved public origin.
2. In the iOS target **Info** plist, add **`ATProtoOAuthClientID`** (string) with that same metadata URL.
3. Under **URL Types**, add the matching **URL Scheme** (reversed host labels, e.g. `app.vercel.my-app`) so the OAuth callback can open the app.

With no plist override, the app falls back to `https://thesocialwire.app/ios-client-metadata.json` and scheme `app.thesocialwire`.
