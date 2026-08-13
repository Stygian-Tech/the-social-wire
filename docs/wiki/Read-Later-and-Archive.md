# Read Later and Archive

The Social Wire uses [L@tr Link](https://latr.link) as its read-later system. There is no provider selector.

## Save an article

Use **Save** or **Save to Read Later** from an article row or reader toolbar. The item appears under **Read Later**. Saving a normal web URL creates interoperable `link.latr.saved.external` and `link.latr.saved.item` records; native ATProto subjects can be represented directly by the saved-item record.

The saved-item record lives on your PDS. Preview metadata such as the title, excerpt, image, site, or author can be supplied by L@tr enrichment and may also be retained on the wrapper for consistent display.

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

If a saved item points back to a Bluesky or other compatible ATProto subject, like, reply, repost, and quote actions target that original record. They never target the `link.latr.saved.item` queue record.

## Portability and privacy

L@tr records are ATProto repo records and are public by default. Other clients using the same lexicons and OAuth permissions can read or update the same queue. Do not place secrets in saved-item notes or tags.

Related: [[Getting-started]], [[Account-settings-and-privacy]], [[Lexicons]].
