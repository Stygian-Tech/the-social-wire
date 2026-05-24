# Architecture

The Social Wire keeps **user organisation data on the user’s ATProto PDS** (folders, publication prefs, read state). Clients discover publications via the gateway/AppView sidebar projection (Thin AppView path) or direct PDS probes (legacy). An optional **Thin AppView** on **`services/appview`** (proxied by **`services/gateway`**) accelerates entry timelines, sidebar badges, and server-side unread filtering without storing full bodies.

**Read in the repo**

- [Overview](https://github.com/Stygian-Tech/the-social-wire/blob/main/docs/architecture/overview.md)
- [Discovery chain](https://github.com/Stygian-Tech/the-social-wire/blob/main/docs/architecture/discovery.md)
- [Lexicons (architecture)](https://github.com/Stygian-Tech/the-social-wire/blob/main/docs/architecture/lexicons.md)
- [AppView architecture](https://github.com/Stygian-Tech/the-social-wire/blob/main/docs/architecture/appview.md) — Thin AppView vs Bluesky App View vs future cross-user index

**Wiki**

- [[Thin-AppView]] — rollout, flags, routes, deployment
- [[Service-API]] — gateway + appview + worker split

Related: [[Lexicons]], [[Web-app]], [[Apple-client]], [[Service-API]].
