# Finance Feed V1 Operations

Finance is an article-first discovery feed. OpenFIGI supplies securities identities,
CoinGecko supplies cryptocurrency identities, and reviewed definitions cover the
remaining indices and commodities. TradingView is optional display only: no prices
are extracted, persisted, or used for ranking. Macroeconomic `macroTopics` remain
separate from sectors and instrument associations.

## Runtime Gates

Set the same `FINANCE_FEED_MODE` on Gateway, App View, and the consolidated worker
roles. It defaults to `off`.

| Mode | Coordinator Catalog/Generation Work | Gateway/AppView Finance Feed/Search API | Navigation |
| --- | --- | --- | --- |
| `off` | Disabled | Disabled | Hidden |
| `shadow` | Enabled after catalog-rights gate | Disabled | Hidden |
| `api` | Enabled after catalog-rights gate | Enabled after catalog-rights gate | Hidden |
| `visible` | Enabled after catalog-rights gate | Enabled after catalog-rights gate | Enabled when a usable generation exists |

Capability catalogs remain readable to report disabled or unavailable states; they
do not activate article serving or establish provider entitlements.

Other controls:

- `FINANCE_CATALOG_RIGHTS_CONFIRMED=true` is an operator assertion that the required
  coverage, storage, display, and public-reference rights review has been completed.
  Leave unset while evidence is pending. This flag is not evidence by itself.
- `FINANCE_CURSOR_HMAC_SECRET` signs Finance continuation; it falls back to
  `WIRE_CURSOR_HMAC_SECRET`. Use an adequate secret under existing discovery-secret
  validation. Never put secrets in PDS records, client bundles, or review notes.
- `FINANCE_WIDGETS_ENABLED=true` enables the server's independent widget capability.
  Web additionally requires `NEXT_PUBLIC_FINANCE_WIDGETS_ENABLED=true` at build
  time. Either switch can suppress web market display while article serving stays
  available. The account's **Hide Performance Data** suppresses the entire widget.
- `OPENFIGI_API_KEY` is optional and server-only. Requests remain bounded without
  a key; obtaining a key or purchasing access is a separate operator action.
- `FINANCE_CRYPTO_CATALOG_ENABLED=true` independently enables CoinGecko import and
  presentation. It defaults to false, including when the overall catalog-rights flag
  is true. Leave it disabled until CoinGecko plan, attribution, storage, termination,
  and externally offered product terms have been reviewed. Disabled crypto is
  filtered from retained catalogs, remote imports, opaque-ID search, and public
  article associations; old database snapshots remain for investigation.
- `FINANCE_OPENFIGI_IDS` contains comma-separated, reviewed listing FIGIs to seed.
  It does not imply an entitlement to a complete securities universe.

Selections are public `app.thesocialwire.finance.selection` PDS records keyed by
hexadecimal SHA-256 of `kind + ":" + reference`. They express interests, not
holdings. Account preferences preserve `showFinance` and `hideFinancePerformance`.
Existing OAuth sessions need reauthorization to obtain the new selection write
scope before authenticated saving acceptance.
Removing a selection deletes the PDS record and app-owned derived selection state;
it cannot retract downstream copies.

## Catalog and Mapping Review

Successful catalog refreshes are due once per 86,400 seconds. Failed attempts
retain the last successful snapshot and have an in-process 3,600-second retry
backoff. Publication atomically replaces the active snapshot under Coordinator
lease fencing; an unconfirmed catalog-rights gate prevents publication.

Securities refresh prioritizes configured reviewed seed FIGIs, then a deterministic
bounded subset of prior and discovered identities, with no more than 150 provider
IDs refreshed per cycle. A large discovery set cannot starve reviewed coverage.
Unrefreshed identities retain prior metadata rather than being marked delisted.
Without an API key, mapping batches contain five IDs and are spaced by 3.1 seconds.
Missing configured seeds bypass the daily freshness shortcut. Projection merges
the reviewed snapshot with at most 150 latest search-discovered overrides.
Crypto reference refresh uses CoinGecko's identity list, not price endpoints.
Bounded requests and retries prevent search and refresh from becoming an unbounded
import mechanism.

Use version-controlled review rather than manually editing database JSON:

1. For index or commodity identity definitions, edit `FinanceReviewedCatalog`
   in `packages/swift/FinanceCore/Sources/FinanceCore` and update its version.
2. For existing instruments, add a `FinanceReviewedInstrumentMetadata` entry with
   the exact canonical instrument ID, expected provider ID, expected symbol,
   and evidence URL. Review exchange, listing/share class, currency and instrument
   type. Add a TradingView symbol only after independent display-coverage review;
   identity aliases and sectors do not require or activate a widget mapping.
3. Add supported sector IDs, aliases, and verified publisher domains/accounts
   only when their evidence supports that specific instrument. Ambiguous corporate
   actions require review. Do not infer a TradingView mapping by concatenating a
   MIC and ticker or substituting a different security.
4. Add fixtures proving the mapping applies to the intended ID/provider/symbol and
   stops applying after a symbol mismatch. Catalog refresh clears obsolete market
   mappings when symbols change; re-review before restoring them.
5. Record coverage and rights evidence in the Finance Linear issues before changing
   activation flags. Absent TradingView symbols
   mean market display remains unavailable for those instruments.

The restricted Development catalog uses reviewed aliases and broad sectors for
reviewed company FIGIs, including the established Apple, Toyota and HSBC identities. These entries guard provider ID and symbol;
they do not merge other exchange listings or activate market display. Generic
OpenFIGI identity results do not independently establish active/delisted status or
bond maturity; those remain coverage-review gates before broad activation.

Search discoveries retain canonical listing identity and participate in article
resolution and subsequent daily reference refresh. A symbol collision must never
merge exchange listings, share classes, funds, or distinct cryptocurrency assets.

## Projection Ownership and Warmup

Projection Pool's Wire drain role analyzes at most 25 admitted, unexpired canonical
articles per 15-second tick from Finance's independent quality-gated canonical
corpus. It does not require a public Wire edition or Wire social admission floor.
Every tick bounds expensive quality work to 1,000 recent and 1,000 background
candidates. An in-memory keyset cursor advances through empty background windows
and resets on wrap or restart; current headlines are checked every tick. The
recency index is installed concurrently by Database Migrator. Coordinator bounds
each quality evaluation pool to 3,000 cached analyses before expensive checks.
Current source, metadata, target, moderation and age gates remain in force; topic
analysis determines Finance eligibility. The private, rebuildable
`finance_article_analysis` cache records the article fingerprint, committed catalog
revision, and resolver version. Resolver v3.3 requires corroborated financial or
business meaning: ambiguous words such as stock, shares, market, bond and filing
never admit a story alone. Analysis uses the headline and up to two opening
summary sentences (600 characters), stopping before related-story/subscription
boilerplate. This favors precision; financial context buried later in a summary
may be omitted. Verified/structured identities and legitimate macro/sector news
remain supported. Bank/company names in ordinary sports coverage do not establish
financial eligibility; explicit financial reporting about sports remains eligible.
Narrow industries require reviewed company membership or prominent headline/lead
topic evidence, rather than an incidental product in a summary list. Pharma and
Biotech retain separate definitions. Serving revalidates older resolver revisions even in retained
personalized snapshots, so old positive classifications are not approval. Changed articles, discovered listings, catalog
revisions, and resolver versions invalidate cached evidence. Guarded writes reject
source or catalog changes that occur during analysis. Projection failures leave
Wire inbox processing and the last successful Finance generation intact.

Coordinator owns provider refresh and fenced immutable Finance generation commits.
It reads only exact cache matches and never resolves articles inline. Missing
analysis is skipped; if no eligible matches remain, the prior generation stays
active. Cold start and catalog changes therefore warm gradually. An immutable
generation created during partial warmup keeps its ordering; newly analyzed stories
enter the next Coordinator generation cycle (Development uses 600 seconds), rather than mutating
already issued cursors. Measure this bounded warmup and shared-service pressure
before enabling visibility. Daily catalog provider requests run on Coordinator;
App View's instrument search uses its separate bounded provider-search quota.

Finance requires Wire's internal canonical admission and enrichment, but commits
its own candidate generations. Strong-source macro and sector reporting can enter
without instrument matches or social signals; routine price chatter still needs
social evidence. The shared Wire score, freshness and diversity framework is reused
without changing public Wire thresholds. With confirmed catalog rights and Finance in `shadow`, `api`, or
`visible`, the worker enables that internal source pipeline and commits active
internal corpus processing even when public `WIRE_FEED_MODE=off` or `shadow`.
It still requires a valid `WIRE_ACTOR_HMAC_SECRET`. Gateway
and App View retain their public Wire flags, so this dependency does not expose
the Wire feed. With Finance off or rights unconfirmed, existing Wire behavior is
unchanged.

### Development Checkpoint Rotation

Adding `app.thesocialwire.finance.selection` changes the AppView filter fingerprint.
The 2026-10-01 Development cutover uses a new
`jetstream-v2-us-west-finance-v1-20261001` generation rather than changing the
identity of an existing checkpoint. Its bootstrap cursor is `26512357203` on
`jetstream.us-west.bsky.network`, observed at 03:00:53 UTC with staged and applied
cursors equal and no pending, retry, or leased rows in the old AppView inbox.

Development's old Wire lanes were paused after exhausting their incident replay
budgets, leaving every current high-intent signal count at zero. The new
`wire-global-v6-dev-publication-finance-live-20261001` publication lane starts at
the same current host cursor, retains the 4 GiB replay caps, and runs through to
live intake. The exhausted base Wire lane is disabled. Projection Pool and
Coordinator scope their Wire inbox work to the new generation; the old Wire inbox
had no nonterminal work at the cutover. Previous checkpoint identities and budget
evidence remain intact. No ranking, moderation, or source-quality thresholds change.

These pinned cursors document this cutover; they are not reusable defaults for a
future source rotation. Read the current host checkpoint and outstanding inbox
work before any later handoff, retain or drain old nonterminal work, and verify
new checkpoint progress and committed generations after deployment. This change
applies only to Development; Production source generations stay unchanged.

The Development database occupied 14,944,663,231 bytes at the cutover, exceeding
the old 13 GiB intake cap before any new Wire submissions. A read-only volume
check showed 98,098,229,248 bytes usable and 82,894,712,832 bytes free. Development's
publication lane therefore uses a bounded 16 GiB database cap (`17179869184`),
adding 3 GiB of headroom. The 50,000-row inbox limit and 4 GiB daily/incident replay
limits stay unchanged. Monitor database growth and intake pressure; this cap does
not change ranking or quality eligibility, and does not apply to Production.

## Validation and Release Evidence

Development Finance can use a separate corpus through the all-or-nothing
`FINANCE_CORPUS_EDGE_BASE_URL`, `FINANCE_CORPUS_EDGE_SERVICE_ID`, and
`FINANCE_CORPUS_EDGE_HMAC_SECRET` override. Without it, Finance inherits Wire's
corpus. The override also routes current-item moderation/deletion checks and
quality fallback to that corpus, preventing cross-environment story checks.
Hosted public origins require HTTPS; Development alone permits HTTP to Railway
private `.railway.internal` origins with the same dedicated HMAC authentication.
The Development edge uses a view-only database login with a two-connection ceiling
and read-only transactions. It has no public domain.

Public XRPC contracts live in `packages/lexicons` and `packages/spec`; matching
Gateway and App View requests live in their Bruno XRPC collections. Public
association confidence is integer `confidenceBps` from 0 to 10,000, avoiding an
unsupported Lexicon floating-point primitive. Internal resolver confidence remains
numeric; clients use at least 9,000 for display suggestions. Lower prominence
values indicate greater article prominence.

Run the FinanceCore, service, lexicon/spec, web, and native checks before activation.
Include exact-language serving, bounded personalization, cursor isolation/expiry,
moderation after caching, source deletions/retractions, generation fencing,
provider outages, PDS rollback/reconciliation, account switching, and widget hiding
and failure. Persisted web Finance payloads are bounded to three pages and 150
stories. Finance cursors expire after 48 hours and must restart from page one.

Database migrations are owned by the dedicated Database Migrator service. Other
database consumers wait through their Railway migrator reference variable. Never
add a Gateway pre-deploy schema migration command for Finance.

The following activation evidence remains pending until separately verified:

- Reviewed cross-market coverage and provider storage/display/public-reference rights.
- Reviewed identity-to-TradingView mappings and supported native embedding use.
- Authenticated web/iOS acceptance with real PDS records and moderation settings.
- Hosted migration, feed freshness, resolver precision, duplicate concentration,
  latency, fallback behavior, and shared-service pressure acceptance.

Implementation checks or mocked browser fixtures do not close these gates. This
runbook does not purchase provider access, contact providers, activate Finance,
or authorize deployment. Rollback starts by returning Finance mode to `off` or
independently disabling widgets; retain catalog/generation data for investigation
and leave existing Wire serving intact.

## Development Reference Review — 2026-10-01

The restricted Development validation catalog can use OpenFIGI listing metadata
and locally reviewed factual index/commodity identities, with crypto and widgets
disabled. This is a limited validation set, not a complete cross-market rollout.
OpenFIGI's [FAQ](https://www.openfigi.com/about/faq) states that FIGI symbology and
associated metadata are open under MIT and imposes no licensing or reuse
restrictions on access, use, or redistribution. Its [API documentation](https://www.openfigi.com/api/documentation)
permits public unauthenticated mapping subject to lower quotas. No prices, third-party
ISIN/CUSIP data, or market-feed entitlements are inferred from that permission.

A live public OpenFIGI v3 mapping request on 2026-10-01 verified these distinct
listing seeds (exchange codes are provider codes, not assumed MICs):

| FIGI | Security | Symbol | Exchange | Composite FIGI | Share-Class FIGI |
| --- | --- | --- | --- | --- | --- |
| BBG000B9Y5X2 | APPLE INC | AAPL | UW | BBG000B9XRY4 | BBG001S5N8V8 |
| BBG000BCM9N1 | TOYOTA MOTOR CORP | 7203 | JT | BBG000BCM915 | BBG001S6BGT4 |
| BBG000BS1N49 | HSBC HOLDINGS PLC | HSBA | LN | BBG000BS1MT4 | BBG001S696H2 |

The API returned additional HSBA listings despite a London MIC query. Pin the
reviewed listing FIGI above; do not select the first ticker result generically.
A Microsoft ticker/MIC query returned no identifier and is not a reviewed seed.
Use `FINANCE_OPENFIGI_IDS=BBG000B9Y5X2,BBG000BCM9N1,BBG000BS1N49` for this limited
Development reference set. Search can discover additional OpenFIGI identities,
which remain subject to resolver confidence and bounded daily refresh limits.
The reviewed S&P 500 and spot-gold definitions are names/interests only; no index
levels, gold quotes, constituent data, or branded data feeds are imported.

CoinGecko's [API terms](https://www.coingecko.com/en/api_terms), sections 4, 6, and 7,
require plan-scoped use, prominent attribution, daily cached-data refresh, deletion
on termination, and terms/privacy protections for products offered outside the
entity. Its [pricing page](https://www.coingecko.com/en/api/pricing) distinguishes
prototype/demo access and commercial licenses. Crypto identity metadata is within
the terms' broad Data definition; fetching only names/IDs does not establish an
exception. The current deployment review does not establish those requirements,
so crypto remains disabled without a purchase or provider contact.

TradingView's [widget documentation](https://www.tradingview.com/widget-docs/) and
[attribution FAQ](https://www.tradingview.com/widget-docs/faq/general/) support
attributed website embedding. The official
[Apple symbol page](https://www.tradingview.com/symbols/NASDAQ-AAPL/) establishes the
NASDAQ:AAPL display identity, but symbol-page existence alone does not establish
widget availability or supported third-party native embedding. Gold and crypto
also require care: a broker/exchange-specific quote is not interchangeable with
an underlying asset identity. No TradingView mappings are activated in this
restricted Development release; `FINANCE_WIDGETS_ENABLED=false` and
`NEXT_PUBLIC_FINANCE_WIDGETS_ENABLED=false` keep reader market display off on all clients.

The web feed ticker uses the independent, default-off build flag
`NEXT_PUBLIC_FINANCE_TICKER_ENABLED`. It embeds the official TradingView Ticker
Tape web component for seven reviewed NASDAQ presentation references. Its documented
background token follows the app theme, including the near-black dark strip. Named feeds use
only their matching reviewed instrument IDs; unsupported feeds omit the strip.
Hide Performance Data removes it entirely. Pause Ticker and reduced-motion mode
replace the embed with static stock-feed links, without prices or third-party
requests. Attribution remains visible, and embed failures leave reading available.
This switch does not enable reader widgets or native embedding. TradingView may
receive the embedding page URL and IP under its own widget privacy policy; the
configuration contains no viewer DID, OAuth credentials, or personal selections.

## Selectable Finance Feeds

The main `finance` feed retains its global baseline and interest boosts. Named
feeds contain matching stories only, with no unrelated global backfill:

- `instrument:<canonical ID>` selects a specific active supported stock or fund.
- `industry:<ID>` selects a broad sector or a narrower industry.
- `group:faang` and `group:mag7` use reviewed, versioned canonical membership.

`getFinanceCatalog` supplies the choices and their definitions. Clients do not
maintain their own membership lists. `getFinance?feed=<catalog ID>` returns
`feedId`; cursors bind that feed and the catalog/resolver revision as well as
viewer and language. An empty named feed means no matching permitted reporting
is currently available, not that unrelated stories should fill the page.

Named security choices require an explicit supported stock/fund classification.
Unknown types, bonds, derivatives, crypto, indices, and commodities do not become
company-feed choices merely because provider metadata defaults to active.
Reference search remains broader and preserves each instrument's distinct identity.
Reviewed Apple name evidence excludes known person and fruit phrases, including
Apple Martin; explicit company names, products, and contextual tickers remain usable.

Web choices are shareable via `/read?feed=finance&financeFeed=<catalog ID>`.
iOS uses a searchable sheet within Finance. Both preserve direct publisher-site
article opening and the existing Finance destination.

For the initial approximately 50-reader audience, named orderings share source
articles and generation snapshots across readers. Serving still rechecks each
reader's moderation and deletions; signed continuation remains viewer-bound.
No per-ticker services or crawlers are required. The starting universe is an
editorial coverage set, not a live ranking of the largest companies.

### Expanded Reference Evidence — 2026-10-02

Official OpenFIGI v3 mapping verified the identities in
`FinanceCuratedSecurities` and the expanded `FinanceReviewedInstrumentMetadata`.
Requests used explicit US exchange context and accepted a unique exact ticker
match whose FIGI equals its composite FIGI, with Common Stock, Depositary Receipt,
or REIT type as applicable. Existing JP Toyota and LN HSBC references remain
separate; their US ADR alternatives were not added to avoid introducing ambiguous
company-name resolution. Other international companies use the specifically
verified US-listed security or ADR. This coverage does not represent every local
listing or share class, and mapping results do not independently establish
exchange-verified delisting status. TradingView mappings remain unpopulated.

The same existing reference rights gate applies. Expanded listing definitions
include canonical identifiers, aliases, broad sectors, and reviewed industry
memberships; no prices, credentials, or viewer preferences are sent to providers.

The initial expanded set contains 107 reviewed securities across 10 broad sectors
and 21 narrower industries, with 141 named/global catalog choices. Names and
industry memberships live in versioned source metadata. Catalog revisions hash
per-feed membership boundaries, so membership changes invalidate continuations.
Oil and mining homonyms are excluded from the corresponding industries/sectors
when there is no validated company association.
Mining & Metals includes reviewed BHP, Rio Tinto, Freeport-McMoRan, and Newmont
memberships; the broader Materials sector also includes other materials businesses.
The projection write guard hashes the same latest 150 discovered security rows as
the catalog reader, preserving exact revision fencing as discovery coverage grows.

Imported AppView source generations are physically purged after expiry in bounded
100-row batches, at most once per minute; their dependent snapshots cascade.
Maintenance uses short timeouts and skips locked rows. A maintenance failure does
not prevent article serving. This complements the existing Worker retention and
keeps separate Development import storage bounded.

### Asset Classes And Hide Crypto — 2026-10-04

Named definitions carry optional `assetKind` (`stock`, `etf`, `crypto`, `index`,
`commodity`). `asset:etf`, `asset:crypto`, and `asset:index` group supported active
canonical instruments and return only validated matching stories; unrelated
finance stories never backfill sparse groups. Older definitions without this field
remain decodable. Individual instrument feeds expose the same classification.

The optional public preference `hideFinanceCrypto` defaults to false. Clients send
`hideCrypto=true|false` on `getFinance`; the server binds this setting into the
preference revision and immutable snapshot/cursor context. A cursor from the other
setting is rejected. Hidden stories include any current high-confidence validated
crypto association, including mixed stories, and substantive cryptocurrency,
Bitcoin, Ethereum, or stablecoin evidence in the headline/opening summary. This
also works during crypto-provider outages. Current articles are rechecked after
snapshot reads; headlines and images are never rewritten. A hidden Crypto feed
returns no matching stories. Clients hide crypto picker entries and reset a hidden
selected Crypto feed to Finance.

OpenFIGI v3 US TICKER mapping verified four additional ETF identities on this date:
SPY `BBG000BDTBL9`, QQQ `BBG000BSWKH7`, VOO `BBG0015VYNT4`, and IVV
`BBG000BVZ4F5`. Provider ETP/Mutual Fund wrappers receive identity-specific reviewed
ETF classification, rather than classifying every fund as an ETF. The default
reviewed FIGI seed now contains 111 securities. Environments with an explicit
`FINANCE_OPENFIGI_IDS` override must add these four verified FIGIs in a separately
reviewed rollout; code changes alone do not replace that override. The existing
OpenFIGI coverage/rights activation gate remains required.

Reviewed reference definitions add the [Nasdaq-100](https://www.nasdaq.com/market-activity/index/ndx)
and [Dow Jones Industrial Average](https://www.spglobal.com/spdji/en/indices/equity/dow-jones-industrial-average/),
alongside S&P 500. Bitcoin and Ethereum use CoinGecko canonical IDs `bitcoin` and
`ethereum`, with provider refresh taking precedence over equivalent bootstrap
identities. Crypto publication remains gated by `FINANCE_CRYPTO_CATALOG_ENABLED`
and the existing reviewed rights controls; this change does not enable that flag,
purchase access, or activate a provider. No price data or TradingView mappings were
added. Resolver version `finance-resolver-v3.4` rebuilds obsolete topic analysis
through the existing bounded projector.
