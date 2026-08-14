# Read Later and Archive

The Social Wire uses [L@tr Link](https://latr.link) as its read-later system. There is no provider selector.

## Save an article

Use **Save** or **Save to Read Later** from an article row or reader toolbar. The item appears under **Read Later**. The encountered HTTPS article URL is saved as the `community.lexicon.bookmarks.bookmark` subject whenever available; an AT URI is used only when no web URL exists.

The bookmark and its `link.latr.bookmarks.metadata` record live on your PDS. Preview metadata such as title, excerpt, image, site, or author is derived by L@tr and returned directly by the bookmark XRPC response.

## Read Later versus Archive

- **Read Later** shows active saved items.
- **Archive** shows items whose state is `archived`.
- **Archive** moves an item out of the active queue without deleting it.
- **Unarchive** returns it to Read Later.
- **Delete** removes the saved item after confirmation.

Both lists use the same article reader as publication feeds. They do not use feed read/unread state, the **All / Unread** filter, or **Mark All As Read**.

## Publication chips

When a saved URL matches a publication already known to your sidebar, The Social Wire displays that publication's name and favicon with the saved link. External saves can also match by a compatible publication site URL.

## Social actions

If a bookmark subject is a compatible AT URI, like, reply, repost, and quote actions target that original record. They never target the bookmark record itself.

## Portability and privacy

Bookmark records are public by default. Other clients using the same lexicons and OAuth permissions can read or update the same queue. Do not place secrets in notes or tags.

Related: [[Getting-started]], [[Account-settings-and-privacy]], [[Lexicons]].
