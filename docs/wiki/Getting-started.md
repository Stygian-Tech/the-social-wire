# Getting started

The Social Wire uses your existing ATProto identity. You can sign in with a Bluesky handle or a handle hosted by another compatible PDS; there is no separate Social Wire password.

## Sign in

1. Open [thesocialwire.app](https://thesocialwire.app) or the Apple app.
2. Enter your handle, such as `alice.bsky.social`.
3. Approve the requested permissions on your account's authorization server.
4. Return to The Social Wire while it loads your lists and first articles.

The app uses ATProto OAuth with PKCE and DPoP. It never asks for an app password. If you joined before a new feature added permissions, the app may ask you to sign in again so your authorization includes the new record collections.

## Your four lists

| List | What appears there |
|------|--------------------|
| **Read Later** | Active links saved through L@tr Link |
| **Archive** | Saved links you moved out of the active queue |
| **Subscribed** | Publications and RSS feeds you explicitly subscribed to, organized into folders |
| **Following** | Publications discovered from people you follow on ATProto |

You can hide any of these lists except the final visible one and choose which lists show unread counts in **Profile → Settings**. Web settings also include appearance and RSS-reader preferences.

## Add a publication

Use **Add Publication** under **Subscribed**. The exact placement differs by screen size, but it is not shown under Following.

The web app accepts:

- a publication or article URL;
- an RSS or Atom feed URL;
- a Bluesky/ATProto handle or DID; or
- a publication AT-URI.

The Apple app accepts a URL, handle, DID, or AT-URI. For a web URL it first checks for RSS/Atom; handles and DIDs are resolved as standard.site publications. An optional custom title is most useful for RSS feeds.

Adding a source creates a subscription record on your PDS. It does not follow the author on Bluesky. Likewise, a source shown under **Following** is not automatically a **Subscribed** source until you subscribe to it.

## First navigation

- Choose a top-level list.
- For Subscribed or Following, select a publication and then an article.
- Use **All / Unread** on feed lists to filter the article list.
- For Read Later or Archive, select a saved link directly; there is no separate article-list pane or read filter.

On iPhone, these steps appear as horizontally swipeable panes. On iPad and desktop web, the same hierarchy is shown in columns.

## If a source or article is missing

1. Pull to refresh or use **Refresh**.
2. For a subscribed source, confirm that it still appears under Subscribed.
3. If you added a public web page, confirm that it exposes an RSS/Atom feed or that the author actually published the matching `site.standard.document`/`site.standard.entry` record to their PDS.
4. Sign out and back in if the app reports missing OAuth permissions.
5. Use **Feedback** in the web sidebar if the problem continues.

A page being visible on a publisher's website does not guarantee that an indexable ATProto record exists yet.

## Next steps

- [[Reading-and-organizing]]
- [[Read-Later-and-Archive]]
- [[Account-settings-and-privacy]]
