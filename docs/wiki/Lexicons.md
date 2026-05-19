# Lexicons

ATProto lexicon JSON under `packages/lexicons` — Social Wire prefs, read-later interoperability (`com.latr.*`), Skyreader subscriptions, etc.

**Reference**

- [packages/lexicons/README.md](https://github.com/Stygian-Tech/the-social-wire/blob/main/packages/lexicons/README.md)
- [CHANGELOG](https://github.com/Stygian-Tech/the-social-wire/blob/main/packages/lexicons/CHANGELOG.md)

Related architecture notes: [docs/architecture/lexicons.md](https://github.com/Stygian-Tech/the-social-wire/blob/main/docs/architecture/lexicons.md).

`com.thesocialwire.entryReadState` is canonical on the user's PDS; the optional [[Thin-AppView]] gateway may mirror it into derived `read_marks` for unread filtering.
