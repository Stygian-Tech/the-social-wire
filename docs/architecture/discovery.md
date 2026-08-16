# Publication Discovery

## Overview

> **Release status:** the XRPC method names below describe the current checkout.
> Testing and Production have not registered those aliases as of 2026-08-12, so
> the equivalent `/v1/publications/*` and `/v1/appview/*` routes remain the
> current hosted contract.

With **Thin AppView** enabled (the default production path), publication discovery and sidebar assembly happen **server-side** via AppView:

- **`GET /v1/appview/bootstrap-stream`** — progressive NDJSON for initial reader load
- **`app.thesocialwire.publication.getSidebar`** — full or phased sidebar JSON (`phase=full|priority|folderPublications`)
- **`app.thesocialwire.publication.refreshSidebar`** — force recompute after subscription changes

The last two are Lexicon-defined methods intended for `/xrpc/{NSID}` after the
pending migration ships. Their `/v1/publications/*` equivalents are the current
hosted routes and remain as compatibility routes in the new source.

The projection merges follow-graph discovery, graph subscriptions, Skyreader RSS rows, folder prefs, and per-publication AppView scope keys. Clients paint folder/publication headers immediately and fill rows as stream events arrive.

## Thin-client boundary

Web and iOS do not crawl the viewer's follow graph or merge a client-side discovery cache. AppView owns the canonical sequence:

1. Fetch follow subjects from the viewer PDS and the public Bluesky graph.
2. Resolve publication records on author PDSes.
3. Persist the rebuildable sidebar projection and stream it to clients.

The web client retains targeted public record reads for article URL recovery and publication-row hydration, not a follow-graph fallback.

## Concurrency

Web and iOS call
**`app.thesocialwire.appview.enrollSources`** with author DIDs after sidebar load
(best-effort backfill). Charybdis (`appview-worker`) also runs **proactive PDS
backfill** on a timer for subscribed authors.

## AppView layers

Social Wire uses **two** AppView concepts:

| Layer | Purpose | Status |
|-------|---------|--------|
| **Bluesky App View** (`public.api.bsky.app`) | `getFollows`, `getProfile`, handle resolution | In use — unchanged |
| **Thin AppView** (`/xrpc/app.thesocialwire.appview.*` plus `/v1/*` compatibility routes on **`services/appview`**) | Entry timelines/detail + sidebar projection + server-side unread | Current client read path; server feature-gated |

A **future cross-user indexer** (popular among follows, public folder indexes, federated discovery via firehose) is a separate scope — not the thin AppView. See [appview.md](appview.md).
