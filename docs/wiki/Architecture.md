# Architecture

The Social Wire keeps **user-authored organisation data on the user’s ATProto PDS** (folders, publication preferences, subscriptions, and L@tr records). Feed read state is local-first and synchronized to AppView. Current clients discover and read through the gateway/AppView projection; direct PDS probes remain for compatibility and narrow enrichment. **Thin AppView** on **`services/appview`** (proxied by **`services/gateway`**) serves timelines, indexed detail, sidebar badges, and server-side unread filtering. Standard.site records remain authoritative on author PDSes; RSS rows may retain feed-provided HTML.

**Read in the repo**

- [Overview](https://github.com/Stygian-Tech/the-social-wire/blob/main/docs/architecture/overview.md)
- [Discovery chain](https://github.com/Stygian-Tech/the-social-wire/blob/main/docs/architecture/discovery.md)
- [Lexicons (architecture)](https://github.com/Stygian-Tech/the-social-wire/blob/main/docs/architecture/lexicons.md)
- [AppView architecture](https://github.com/Stygian-Tech/the-social-wire/blob/main/docs/architecture/appview.md) — Thin AppView vs Bluesky App View vs future cross-user index

**Wiki**

- [[Thin-AppView]] — rollout, flags, routes, deployment
- [[Service-API]] — gateway + appview + worker split

Related: [[Lexicons]], [[Web-app]], [[Apple-client]], [[Service-API]].
