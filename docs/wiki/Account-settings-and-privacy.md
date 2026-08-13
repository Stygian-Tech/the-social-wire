# Account settings and privacy

## Settings

Both clients let you choose which top-level lists are visible and which visible lists show counts. At least one list must remain visible. These preferences are saved to the `app.thesocialwire.preferences` record on your PDS so compatible clients can share them.

The web app additionally supports:

- System, Light, or Dark theme;
- Sans, Serif, or Mono reader font;
- optional Bold Text; and
- opening RSS articles inside The Social Wire or on the publisher's original page.

Appearance choices are browser-local. Feed-display and RSS-reader preferences are account records.

## Profile and account actions

The profile area links to **My Publications** and **Settings**. **Log Out** removes the local OAuth session from the current client; it does not delete your PDS records or Social Wire's derived index.

The Apple app also exposes **Purge Indexed Data**. Despite the broad label, the current endpoint deletes only explicit AppView `read_marks` and unread overrides. Bulk-read floors, materialized counters, publication scopes, viewer-feed membership, and indexed content remain. It does not delete folders, subscriptions, preferences, saved links, publisher content, or your ATProto account. The web client contains the same API capability but does not currently expose this control in its UI.

## Data boundary

| Data | Stored where | Notes |
|------|--------------|-------|
| Folders and publication organization | Your PDS | Public ATProto records |
| standard.site and RSS subscriptions | Your PDS | Public ATProto records |
| L@tr saved links and state | Your PDS | Public ATProto records |
| Immediate read UI and cached feed pages | Current device | Browser storage or SwiftData; rebuildable |
| Indexed article fields and RSS content | Social Wire AppView/Postgres | Derived and retention-limited |
| Read marks and bulk-read boundaries | Social Wire AppView/Postgres | Derived; the current purge removes explicit marks/overrides but leaves bulk-read boundaries |
| Sidebar/feed/PDS acceleration | Optional private Redis | Disposable; a miss falls back to durable sources |

ATProto repositories are public by default. Never store passwords, tokens, private notes, or other secrets in Social Wire, Skyreader, or L@tr records.

## Retention and authority

The AppView's content and read-mark retention windows are environment-configurable. Publisher PDS records and your own PDS records remain authoritative; AppView projections can be rebuilt. RSS feeds are different from standard.site records: the index may retain HTML that the feed itself supplied so it can render the article.

Social Wire production compute and Postgres are operated in the United States. The privacy model is based on data minimization, bounded retention, user/PDS authority, and rebuildable projections rather than a claim that derived data never leaves the PDS.

## Feedback

The web sidebar includes **Feedback**. Submissions appear on the public
[The Social Wire UserInput board](https://userinput.app/s/did:plc:qy5pluw2bsuq2x6albsgkvx3/3mrzw42so4j2h?lang=en)
as interoperable UserInput records and may include an optional screenshot.
Review the preview and remove sensitive information before sending an image.
The Apple client does not currently expose the same feedback form.

Related: [[Architecture]], [[Thin-AppView]], [[Lexicons]], [[Redis]].
