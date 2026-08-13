# The Social Wire

The Social Wire is a reader for publications on the [standard.site](https://standard.site) ecosystem and RSS/Atom feeds. It connects to your ATProto account, lets you follow and organize publications, keeps a reading queue through [L@tr Link](https://latr.link), and is available on the web plus native iOS and iPadOS clients.

- **Open the web app:** [thesocialwire.app](https://thesocialwire.app)
- **Source code:** [Stygian-Tech/the-social-wire](https://github.com/Stygian-Tech/the-social-wire)
- **Source-code license:** [MIT](https://github.com/Stygian-Tech/the-social-wire/blob/main/LICENSE)

## For readers

- [[Getting-started]] — sign in, understand the four main lists, and add a publication
- [[Reading-and-organizing]] — folders, filters, unread state, article actions, and RSS reading
- [[Read-Later-and-Archive]] — save, archive, restore, and delete links with L@tr Link
- [[Account-settings-and-privacy]] — display preferences, portable records, indexed data, and feedback
- [[Web-app]] and [[Apple-client]] — platform-specific behavior and setup

## For developers

- [[Architecture]] — system boundaries and data ownership
- [[Monorepo-map]] — where apps, services, packages, and documentation live
- [[Service-API]] — public Gateway contract and internal services
- [[Thin-AppView]] and [[ThinAppViewCore]] — indexed read path and shared Swift package
- [[Lexicons]] and [[Database]] — portable ATProto records and rebuildable server data
- [[Redis]] — optional disposable cache and coordination layer
- [[Testing]] and [[Contributing]] — verification and contribution workflow

## What lives where

The Social Wire keeps folders, publication preferences, RSS subscriptions, standard.site subscriptions, and L@tr saved-item records on your ATProto PDS. Those records are portable and public like other ATProto repository records, so they must not contain secrets.

For fast timelines and unread filtering, Social Wire keeps a time-limited, rebuildable index in its AppView. Individual read marks are also stored there. The clients retain local caches for quick startup and immediate UI updates. See [[Account-settings-and-privacy]] for the full boundary and available controls.

## Supported sources

- `site.standard.document` and backward-compatible `site.standard.entry` records from publisher PDSes
- `site.standard.graph.subscription` publication subscriptions
- RSS and Atom feeds stored as `app.skyreader.feed.subscription` records
- L@tr Link records in `link.latr.saved.*`

The Social Wire may display a publisher's public page before an equivalent ATProto record is available, but the AppView can only index records or feeds it can actually retrieve.
