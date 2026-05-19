# Architecture

The Social Wire keeps **user organisation data on the user’s ATProto PDS** (folders, publication prefs, read state). Clients discover publications via follows and read standard.site–shaped records from authors’ repos. An optional **Thin AppView** on `services/api` accelerates entry timelines and server-side unread filtering without storing full bodies.

**Read in the repo**

- [Overview](https://github.com/Stygian-Tech/the-social-wire/blob/main/docs/architecture/overview.md)
- [Discovery chain](https://github.com/Stygian-Tech/the-social-wire/blob/main/docs/architecture/discovery.md)
- [Lexicons (architecture)](https://github.com/Stygian-Tech/the-social-wire/blob/main/docs/architecture/lexicons.md)
- [AppView architecture](https://github.com/Stygian-Tech/the-social-wire/blob/main/docs/architecture/appview.md) — Thin AppView vs Bluesky App View vs future cross-user index

**Wiki**

- [[Thin-AppView]] — rollout, flags, routes, deployment

Related: [[Lexicons]], [[Web-app]], [[Apple-client]], [[Service-API]].
