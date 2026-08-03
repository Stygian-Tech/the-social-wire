# Lexicons

ATProto lexicon JSON under `packages/lexicons` — Social Wire preferences, read-later interoperability (`link.latr.*`; legacy `com.latr.*` compatibility), Skyreader subscriptions, and related records.

**Reference**

- [packages/lexicons/README.md](https://github.com/Stygian-Tech/the-social-wire/blob/main/packages/lexicons/README.md)
- [CHANGELOG](https://github.com/Stygian-Tech/the-social-wire/blob/main/packages/lexicons/CHANGELOG.md)

Related architecture notes: [docs/architecture/lexicons.md](https://github.com/Stygian-Tech/the-social-wire/blob/main/docs/architecture/lexicons.md).

Feed read/unread state is not stored in ATProto repo records. Clients keep a local cache for immediate UI and write authenticated read marks to [[Thin-AppView]].
