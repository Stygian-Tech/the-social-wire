# Reading and organizing

## Subscribed and Following

**Subscribed** is your intentionally curated set of standard.site publications and RSS feeds. It supports folders. **Following** is discovered from the people you follow on ATProto and is presented separately so discovery does not silently become a subscription.

The **All** row opens the aggregate feed for the current list. Selecting a folder scopes the feed to that folder; selecting a publication scopes it to one source.

## Folders

Folders are available under Subscribed. You can:

- create a folder;
- move a subscribed publication into or out of a folder;
- expand or collapse folders; and
- delete a folder without unsubscribing from its publications.

Folder names and assignments are stored as `app.thesocialwire.folder` and `app.thesocialwire.publicationPrefs` records on your PDS. Expanded/collapsed presentation is only a device-local convenience setting.

## Read and unread state

Opening or explicitly marking an article updates local UI state and synchronizes the mark to the Social Wire AppView. The AppView supplies unread pagination and sidebar counts; the client reconciles those counts with cached rows and optimistic local changes.

**Mark All As Read** is scoped to where you invoke it: all feed lists, one top-level feed, one folder, one publication, or the open article. It records a server-side read boundary covering older entries in that scope and updates already cached rows.

**Mark All As Unread** is a client-side action for already loaded/cached articles; it is not a server-side reversal of every older article in a scope.

When the article filter is **Unread**, the currently open row stays visible until you move to another article so it does not disappear while you are reading it.

## Reading an article

The reader chooses the best available presentation in this order:

1. substantial HTML stored in the indexed record;
2. an oEmbed representation; or
3. a sandboxed publisher page for thin RSS summaries.

RSS articles can also open on the original publisher site. On the web, choose this behavior under **Your Account → Settings → RSS Articles**. In the Apple app, article links and **Open Original Article** leave the embedded reader through the system browser.

Publisher HTML is sanitized before display. Image formats are shown as the publisher stored them; Social Wire does not transcode them to another format.

## Article actions

Depending on the source record, the web and Apple clients can offer:

- Save to Read Later;
- Open or share the original article;
- Like, reply to, repost, or quote a linked Bluesky post;
- create a new Bluesky post linking to the article; and
- recommend a compatible standard.site article.

Like, reply, repost, and quote target the original linked social record, not a Social Wire index row or L@tr saved-item wrapper. Actions are unavailable when an article has no compatible linked subject.

## Refresh and cache behavior

Initial signed-in load streams sidebar sections, unread counts, and the first feed page from the Gateway. Repeat visits can paint a persisted local cache first and refresh it in the background. Pull-to-refresh or **Refresh** asks for current server projections; temporary cache staleness does not change the authoritative PDS records.

Related: [[Getting-started]], [[Read-Later-and-Archive]], [[Thin-AppView]].
